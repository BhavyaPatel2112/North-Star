"""Stations a one-way run can end at ("End near a station").

A runner can finish at a local train, metro or monorail station and ride home,
which makes one-way runs practical in Mumbai. The station list is built once
from OpenStreetMap by scripts.build_stations and saved in
data/processed/stations.json; it is free and needs no key.

For each request, the server measures the street distance to every station
within reach, keeps those the run can get to, and the planner then finds the
cleanest route to each, adding a detour when a station is closer than the
chosen distance.
"""

import json
from math import cos, radians, sqrt

from northstar import config
from northstar.routing.planner import TOLERANCE

STATIONS_FILE = config.PROCESSED_DIR / "stations.json"
MODE_NAMES = {"train": "station", "metro": "metro station", "monorail": "monorail station"}
MAX_CANDIDATES = 24         # stations tried per request (each one costs a route search, about 0.1 s)
EARTH_M_PER_DEG = 111_320.0


def load() -> list[dict]:
    """All stations: [{name, mode, lat, lon}]. Empty if the file has not been built."""
    if not STATIONS_FILE.exists():
        return []
    return json.loads(STATIONS_FILE.read_text())


def label(station: dict) -> str:
    """How the app names a station: "Bandra station", "Andheri metro station"."""
    name = station["name"]
    kind = MODE_NAMES.get(station["mode"], "station")
    # Names in OpenStreetMap sometimes already end in "station" or "metro station".
    return name if name.lower().endswith("station") else f"{name} {kind}"


def within_reach(stations: list[dict], lat: float, lon: float, distance_m: float) -> list[dict]:
    """Stations no further than the run's distance in a straight line (and not at the start)."""
    kx = cos(radians(lat)) * EARTH_M_PER_DEG
    near = []
    for station in stations:
        straight = sqrt(((station["lon"] - lon) * kx) ** 2 + ((station["lat"] - lat) * EARTH_M_PER_DEG) ** 2)
        if 300 <= straight <= distance_m:
            near.append(station)
    return near


def candidates(near: list[dict], street_m: list[float], distance_m: float) -> list[dict]:
    """Stations worth planning a run to, given each one's shortest street distance.

    Straight lines mislead in Mumbai (a station across Mahim Creek can be close as
    the crow flies and far by road), so stations are chosen by street distance:
    those the run reaches without a detour come first, then the ones needing the
    shortest detour. Stations further than the run by street are dropped."""
    reachable = [(street, s) for street, s in zip(street_m, near) if street <= distance_m * (1 + TOLERANCE)]
    # 0 for "no detour needed", otherwise the extra distance the detour adds.
    reachable.sort(key=lambda item: max(0.0, distance_m * (1 - TOLERANCE) - item[0]))
    return [{"name": label(s), "lat": s["lat"], "lon": s["lon"], "kind": "station", "mode": s["mode"],
             "street_km": round(street / 1000, 2)}
            for street, s in reachable[:MAX_CANDIDATES]]
