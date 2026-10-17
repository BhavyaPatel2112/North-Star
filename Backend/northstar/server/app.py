"""The North Star route server (FastAPI).

The iPhone app sends a start point, a distance and a run type; the server
plans running routes on the street network with the latest pollution
forecast and returns the best options, each with its line on the map, street
by street directions, pollution along the way and the cleanest time to start.

Production flow for each request:
1. Plan up to 6 candidate routes with our own route finder (fast, free).
2. Check each, cleanest first, against Google's walking directions, so we
   never show a route through a gate or along a road without a way through.
3. Return the best 3 that Google confirms. If Google cannot be asked (no key,
   daily or monthly limit reached), routes are returned marked "not checked".

Run locally from the Backend folder:
    .venv/bin/uvicorn northstar.server.app:app --reload
Then open http://127.0.0.1:8000/docs to try it in the browser.
"""

import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Literal

import numpy as np
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from northstar import config
from northstar.db.connection import connect
from northstar.routing import elevation, food, parks, stations, walk_check
from northstar.routing.network import StreetNetwork
from northstar.routing.planner import Planner, google_maps_link, road_mix, steps
from northstar.server.forecast import INDIA, ForecastCache, best_start, best_window

CANDIDATES = 6      # routes planned per request
SHOWN = 3           # routes returned

# Optional shared key between the app and the server. It is not a real secret
# (it ships inside the app) but stops casual use of the server by others.
APP_KEY = os.getenv("NORTHSTAR_APP_KEY")

state: dict = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Load the street network once when the server starts (about a second).
    planner = Planner(StreetNetwork.load())
    state["planner"] = planner
    state["forecast"] = ForecastCache(planner)
    state["stations"] = stations.load()
    state["parks"] = parks.load()
    yield


app = FastAPI(title="North Star", version="1.0", lifespan=lifespan)


def require_app_key(x_app_key: str | None = Header(default=None)) -> None:
    if APP_KEY and x_app_key != APP_KEY:
        raise HTTPException(status_code=401, detail="Unknown app.")


# ---------- request and response shapes ----------

class Place(BaseModel):
    name: str = Field(max_length=120)
    lat: float
    lon: float


class RouteRequest(BaseModel):
    lat: float = Field(description="Start latitude")
    lon: float = Field(description="Start longitude")
    distance_km: float = Field(ge=1, le=30, description="Target distance in kilometres")
    kind: Literal["loop", "one_way"] = "loop"
    start_time: datetime | None = Field(default=None, description="When the run starts (default: now)")
    finish_places: list[Place] = Field(default=[], max_length=20,
                                       description="Optional finishes, such as cafes (one way only)")
    end_near_food: bool = Field(default=False, description="End at a popular, well-rated restaurant or cafe "
                                "(Google Places; finish_places are used if Google is unavailable)")
    end_near_station: bool = Field(default=False, description="End at a local train or metro station, "
                                   "to ride home (one way only)")
    allow_busy_roads: bool = Field(default=False, description="Allow highway crossings and mostly-main-road routes")
    laps: Literal["none", "half", "all", "count"] = Field(
        default="none", description="Laps of a nearby park: none, about half the run, as much as fits, or lap_count laps")
    lap_count: int | None = Field(default=None, ge=1, le=10, description="Number of laps when laps is 'count'")


# ---------- endpoints ----------

@app.get("/health")
def health() -> dict:
    """Quick check that the server is up (also used by the host's health check)."""
    forecast: ForecastCache = state["forecast"]
    return {"ok": True, "streets": int(len(state["planner"].net.edge_from)),
            "forecast_run": forecast.run_at.isoformat() if forecast.run_at else None}


@app.get("/v1/parks", dependencies=[Depends(require_app_key)])
def nearby_parks(lat: float, lon: float) -> dict:
    """Parks with a runnable loop near a start, nearest first, so the app can offer laps:
    [{name, loop_km, distance_km}] (distance_km is a straight line to the park's middle)."""
    found = parks.nearby(state["parks"], lat, lon)[:3]
    from math import cos, radians, sqrt
    kx = cos(radians(lat)) * 111_320
    return {"parks": [{
        "name": p["name"], "loop_km": round(p["length_m"] / 1000, 2),
        "distance_km": round(max(0.0, sqrt(((p["lon"] - lon) * kx) ** 2 + ((p["lat"] - lat) * 111_320) ** 2)
                                 - p["length_m"] / 6) / 1000, 2),
    } for p in found]}


@app.post("/v1/routes", dependencies=[Depends(require_app_key)])
def plan_routes(request: RouteRequest) -> dict:
    south, west, north, east = config.MUMBAI_BBOX
    if not (south <= request.lat <= north and west <= request.lon <= east):
        raise HTTPException(status_code=422, detail="Start is outside the area North Star covers.")
    if (request.finish_places or request.end_near_food or request.end_near_station) and request.kind != "one_way":
        raise HTTPException(status_code=422, detail="Finishing places only work with one-way runs.")
    if request.end_near_food and request.end_near_station:
        raise HTTPException(status_code=422, detail="Choose either food or a station as the finish, not both.")

    planner: Planner = state["planner"]
    forecast: ForecastCache = state["forecast"]
    try:
        forecast.refresh()
        hour = forecast.hour_index(request.start_time or datetime.now(timezone.utc))
    except LookupError:
        raise HTTPException(status_code=503, detail="Forecast not available yet; try again shortly.")
    exposure = forecast.exposure[hour]

    distance_m = request.distance_km * 1000
    places = [p.model_dump() for p in request.finish_places]
    food_source = None
    if request.end_near_station:
        near = stations.within_reach(state["stations"], request.lat, request.lon, distance_m)
        street_m = planner.street_distances(request.lat, request.lon, distance_m * 1.05, near)
        places = stations.candidates(near, street_m, distance_m)
    elif request.end_near_food:
        with connect() as conn:
            found = food.search(conn, request.lat, request.lon, distance_m * 0.9)
        if found.places:
            places, food_source = [{**p, "kind": "food"} for p in found.places], "google"
        else:
            food_source = f"apple ({found.source})" if places else None

    avoid = not request.allow_busy_roads

    def plan(avoid_busy: bool) -> list:
        if places:
            return planner.to_places(request.lat, request.lon, distance_m, exposure, places, CANDIDATES, avoid_busy)
        if request.kind == "one_way":
            return planner.one_way(request.lat, request.lon, distance_m, exposure, CANDIDATES, avoid_busy)
        return planner.round_trips(request.lat, request.lon, distance_m, exposure, CANDIDATES, avoid_busy)

    candidates = plan(avoid)

    # Park laps (only when the app asks): put up to 2 lap routes first.
    if request.laps != "none" and not places:
        near = parks.nearby(state["parks"], request.lat, request.lon)
        laps = planner.park_laps(request.lat, request.lon, distance_m, exposure, near, request.laps,
                                 request.lap_count, request.kind, avoid)
        candidates = laps + candidates

    # Cleanest first; ask Google about each until SHOWN routes are confirmed.
    shown, rejected = [], 0
    with connect() as conn:
        for option in candidates:
            shape = planner.shape(option)
            # Lap routes are checked on their unique path (there, one lap, back).
            checked = option.extra.get("check", option)
            check = walk_check.check(conn, planner.shape(checked), checked.distance_m,
                                     lenient=option.kind == "park_laps")
            if check.checked and not check.walkable:
                rejected += 1
                continue
            shown.append(describe(planner, forecast, option, shape, exposure, check))
            if len(shown) == SHOWN:
                break

    message = None
    if not shown:
        if request.end_near_station and not places:
            message = "No train or metro station within reach of that distance. Try a longer distance."
        elif request.end_near_food and not places:
            message = "No popular, well-rated places to eat found within reach. Try a longer distance."
        elif avoid and not candidates and plan(False):
            # Routes exist, but all of them cross a highway or follow main roads (planning is fast, no Google).
            message = ("Every route of that distance from here crosses a highway or runs mostly on main roads. "
                       "Turn on \"OK with highways\" to see them, or try another distance.")
        elif request.end_near_station:
            message = "No walkable route of that distance ends at a station here. Try a slightly different distance."
        else:
            message = "No walkable route of that distance found here. Try a slightly different start or distance."

    return {
        "forecast_hour": forecast.hours[hour].astimezone(INDIA).isoformat(),
        "forecast_run": forecast.run_at.isoformat() if forecast.run_at else None,
        "options": shown,
        "planned": len(candidates),
        "rejected_by_walk_check": rejected,
        "food_source": food_source,
        "message": message,
    }


def describe(planner: Planner, forecast: ForecastCache, option, shape: list, exposure: np.ndarray,
             check: walk_check.WalkCheck) -> dict:
    """Everything the app needs to show one route option."""
    lengths = planner.net.edge_length[option.edges].astype(np.float64)
    by_hour = forecast.route_by_hour(option.edges, lengths, near=shape[0] if shape else None)
    return {
        "kind": option.kind,
        "label": option.label,
        "distance_km": round(option.distance_m / 1000, 2),
        "pm25": round(option.mean_pm25, 1),
        "cleaner_than_direct_pct": round(option.cleaner_than_direct * 100) if option.cleaner_than_direct else None,
        "quiet_share": round(option.quiet_share, 2),
        "green_share": round(option.green_share, 2),
        "main_road_share": round(option.main_road_share, 2),
        "repeated_share": round(option.repeated_share, 2),
        "highway_crossings": option.highway_crossings,
        "finish_crossings": option.extra.get("finish_crossings", 0),
        "busy_km": round(option.busy_km, 2),
        "road_km": road_mix(planner, option),
        "finish": {"lat": option.finish[0], "lon": option.finish[1]},
        "finish_place": option.extra.get("place"),
        "park": option.extra.get("park"),
        "line": [[round(lat, 6), round(lon, 6)] for lat, lon in shape],
        "steps": [{**s, "km_from": round(s["km_from"], 3), "km": round(s["km"], 3), "pm25": round(s["pm25"], 1)}
                  for s in steps(planner, option, exposure)],
        "by_hour": by_hour,
        "elevation": elevation.profile(planner.net, option.nodes, option.edges),
        "best_start": best_start(by_hour),
        "best_window": best_window(by_hour),
        "walk_check": {"checked": check.checked, "walkable": check.walkable,
                       "google_distance_ratio": check.ratio, "overlap": check.overlap, "note": check.note},
        "google_maps_link": google_maps_link(planner, option),
    }
