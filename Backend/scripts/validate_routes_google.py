"""Check planned routes against Google's walking directions.

For each planned route we ask Google's Routes API for a walking route through
the same points (start, up to 10 evenly spaced points along our route, and the
finish), then compare:
- distance: Google's walking distance against ours
- overlap: the share of our route that lies within 25 m of Google's line

If Google needs a much longer way round, or follows little of our line, our
route probably uses something that cannot really be walked through (a gated
lane, a highway without a footpath, a railway crossing that does not exist).

Uses basic walking routes with at most 10 intermediate points, billed as
Routes "Essentials" (70,000 free a month with an Indian billing account),
counted by the spending guard in api_usage.

Run from the Backend folder:
    .venv/bin/python -m scripts.validate_routes_google
"""

import json
from datetime import date

import numpy as np
import pandas as pd
import requests

from northstar import config
from northstar.db.connection import connect
from northstar.routing.network import StreetNetwork
from northstar.routing.planner import Planner

URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
MONTHLY_LIMIT = 60_000   # under the 70,000 free Essentials requests
API_NAME = "google_routes"
STARTS = {
    "Thakur Village, Kandivali East": (19.2105, 72.8740),
    "Dadar West": (19.0178, 72.8420),
    "Powai": (19.1197, 72.9050),
    "Chembur": (19.0622, 72.9005),
    "Vashi": (19.0771, 72.9986),
    "Malad West": (19.1868, 72.8484),
}


def decode_polyline(text: str) -> list[tuple[float, float]]:
    """Google's encoded polyline format to (latitude, longitude) points."""
    points, index, lat, lon = [], 0, 0, 0
    while index < len(text):
        for is_lat in (True, False):
            shift = result = 0
            while True:
                byte = ord(text[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if is_lat:
                lat += delta
            else:
                lon += delta
        points.append((lat / 1e5, lon / 1e5))
    return points


def metres(points: np.ndarray, lat0: float) -> np.ndarray:
    return np.column_stack([points[:, 1] * np.cos(np.radians(lat0)) * 111_320, points[:, 0] * 111_320])


def overlap(ours: list, google: list, within_m: float = 25) -> float:
    """Share of our route's points that lie within `within_m` of Google's line."""
    a, b = np.array(ours), np.array(google)
    lat0 = float(a[:, 0].mean())
    a, b = metres(a, lat0), metres(b, lat0)
    # Distance from each of our points to the nearest Google segment.
    starts, ends = b[:-1], b[1:]
    seg = ends - starts
    length2 = np.maximum((seg ** 2).sum(1), 1e-9)
    best = np.full(len(a), np.inf)
    for i in range(0, len(a), 200):  # in chunks, to keep memory small
        p = a[i:i + 200, None, :]
        t = np.clip(((p - starts) * seg).sum(2) / length2, 0, 1)
        nearest = starts + t[..., None] * seg
        best[i:i + 200] = np.sqrt(((p - nearest) ** 2).sum(2)).min(1)
    return float((best <= within_m).mean())


def google_walk(conn, shape: list) -> tuple[float, list]:
    used = conn.execute("select coalesce(sum(requests), 0) from api_usage where api = %s and month = %s",
                        (API_NAME, date.today().replace(day=1))).fetchone()[0]
    if used >= MONTHLY_LIMIT:
        raise RuntimeError("Monthly Google Routes limit reached; stopping.")
    picks = [shape[round(i * (len(shape) - 1) / 11)] for i in range(1, 11)]
    location = lambda p: {"location": {"latLng": {"latitude": p[0], "longitude": p[1]}}}
    response = requests.post(URL, timeout=60, headers={
        "X-Goog-Api-Key": config.GOOGLE_AIR_QUALITY_KEY,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.polyline.encodedPolyline",
    }, json={"origin": location(shape[0]), "destination": location(shape[-1]),
             "intermediates": [{**location(p), "via": True} for p in picks], "travelMode": "WALK"})
    conn.execute(
        "insert into api_usage (api, month, requests) values (%s, %s, 1) "
        "on conflict (api, month) do update set requests = api_usage.requests + 1",
        (API_NAME, date.today().replace(day=1)))
    conn.commit()
    if response.status_code != 200:
        raise RuntimeError(f"Google Routes: HTTP {response.status_code}: {response.text[:150]}")
    routes = response.json().get("routes")
    if not routes:
        return float("nan"), []  # Google found no walking route through these points
    route = routes[0]
    return float(route["distanceMeters"]), decode_polyline(route["polyline"]["encodedPolyline"])


def main() -> None:
    planner = Planner(StreetNetwork.load())
    with connect() as conn:
        now = pd.Timestamp.now(tz="UTC").floor("h")
        cells = {int(h): float(v) for h, v in conn.execute(
            "select h3, pm25 from grid_predictions where ts = %s", (now,)).fetchall()}
        exposure = planner.edge_exposure(cells, float(np.median(list(cells.values()))))
        rows = []
        for name, (lat, lon) in STARTS.items():
            for kind, plan in (("loop", planner.round_trips), ("one way", planner.one_way)):
                for i, option in enumerate(plan(lat, lon, 5000, exposure)):
                    shape = planner.shape(option)
                    distance, google_line = google_walk(conn, shape)
                    walkable = bool(google_line)
                    rows.append({
                        "start": name, "kind": option.kind, "option": i + 1,
                        "ours_km": round(option.distance_m / 1000, 2), "google_km": round(distance / 1000, 2),
                        "ratio": round(distance / option.distance_m, 2),
                        "overlap": round(overlap(shape, google_line), 2) if walkable else 0.0,
                        "google_found_route": walkable,
                    })
    table = pd.DataFrame(rows)
    table["flag"] = np.where(~table.google_found_route, "NO WALK ROUTE",
                             np.where((table.ratio > 1.15) | (table.overlap < 0.8), "CHECK", "ok"))
    print(table.to_string(index=False))
    print(f"\n{(table.flag == 'ok').mean():.0%} of routes pass "
          f"(median Google/ours distance {table.ratio.median():.2f}, median overlap {table.overlap.median():.0%})")
    (config.PROCESSED_DIR / "route_validation.json").write_text(table.to_json(orient="records", indent=1))


if __name__ == "__main__":
    main()
