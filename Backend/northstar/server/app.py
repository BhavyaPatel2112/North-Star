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
from northstar.routing import walk_check
from northstar.routing.network import StreetNetwork
from northstar.routing.planner import Planner, google_maps_link, road_mix, steps
from northstar.server.forecast import INDIA, ForecastCache, best_start

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


# ---------- endpoints ----------

@app.get("/health")
def health() -> dict:
    """Quick check that the server is up (also used by the host's health check)."""
    forecast: ForecastCache = state["forecast"]
    return {"ok": True, "streets": int(len(state["planner"].net.edge_from)),
            "forecast_run": forecast.run_at.isoformat() if forecast.run_at else None}


@app.post("/v1/routes", dependencies=[Depends(require_app_key)])
def plan_routes(request: RouteRequest) -> dict:
    south, west, north, east = config.MUMBAI_BBOX
    if not (south <= request.lat <= north and west <= request.lon <= east):
        raise HTTPException(status_code=422, detail="Start is outside the area North Star covers.")
    if request.finish_places and request.kind != "one_way":
        raise HTTPException(status_code=422, detail="Finishing places only work with one-way runs.")

    planner: Planner = state["planner"]
    forecast: ForecastCache = state["forecast"]
    try:
        forecast.refresh()
        hour = forecast.hour_index(request.start_time or datetime.now(timezone.utc))
    except LookupError:
        raise HTTPException(status_code=503, detail="Forecast not available yet; try again shortly.")
    exposure = forecast.exposure[hour]

    distance_m = request.distance_km * 1000
    if request.finish_places:
        places = [p.model_dump() for p in request.finish_places]
        candidates = planner.to_places(request.lat, request.lon, distance_m, exposure, places, CANDIDATES)
    elif request.kind == "one_way":
        candidates = planner.one_way(request.lat, request.lon, distance_m, exposure, CANDIDATES)
    else:
        candidates = planner.round_trips(request.lat, request.lon, distance_m, exposure, CANDIDATES)

    # Cleanest first; ask Google about each until SHOWN routes are confirmed.
    shown, rejected = [], 0
    with connect() as conn:
        for option in candidates:
            shape = planner.shape(option)
            check = walk_check.check(conn, shape, option.distance_m)
            if check.checked and not check.walkable:
                rejected += 1
                continue
            shown.append(describe(planner, forecast, option, shape, exposure, check))
            if len(shown) == SHOWN:
                break

    return {
        "forecast_hour": forecast.hours[hour].astimezone(INDIA).isoformat(),
        "forecast_run": forecast.run_at.isoformat() if forecast.run_at else None,
        "options": shown,
        "planned": len(candidates),
        "rejected_by_walk_check": rejected,
        "message": None if shown else "No walkable route of that distance found here. "
                                      "Try a slightly different start or distance.",
    }


def describe(planner: Planner, forecast: ForecastCache, option, shape: list, exposure: np.ndarray,
             check: walk_check.WalkCheck) -> dict:
    """Everything the app needs to show one route option."""
    lengths = planner.net.edge_length[option.edges].astype(np.float64)
    by_hour = forecast.route_by_hour(option.edges, lengths)
    return {
        "kind": option.kind,
        "label": option.label,
        "distance_km": round(option.distance_m / 1000, 2),
        "pm25": round(option.mean_pm25, 1),
        "cleaner_than_direct_pct": round(option.cleaner_than_direct * 100) if option.cleaner_than_direct else None,
        "quiet_share": round(option.quiet_share, 2),
        "main_road_share": round(option.main_road_share, 2),
        "repeated_share": round(option.repeated_share, 2),
        "road_km": road_mix(planner, option),
        "finish": {"lat": option.finish[0], "lon": option.finish[1]},
        "finish_place": option.extra.get("place"),
        "line": [[round(lat, 6), round(lon, 6)] for lat, lon in shape],
        "steps": [{**s, "km_from": round(s["km_from"], 3), "km": round(s["km"], 3), "pm25": round(s["pm25"], 1)}
                  for s in steps(planner, option, exposure)],
        "by_hour": by_hour,
        "best_start": best_start(by_hour),
        "walk_check": {"checked": check.checked, "walkable": check.walkable,
                       "google_distance_ratio": check.ratio, "overlap": check.overlap, "note": check.note},
        "google_maps_link": google_maps_link(planner, option),
    }
