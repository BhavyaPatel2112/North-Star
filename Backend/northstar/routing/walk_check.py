"""Check a planned route against Google's walking directions.

We ask Google's Routes API for a walking route through the same points as our
route (start, 10 evenly spaced points along it, and the finish), then compare:
- distance ratio: Google's walking distance divided by ours
- overlap: the share of our route that lies within 25 m of Google's line

If Google needs a much longer way round, or follows little of our line, our
route probably uses something that cannot really be walked (a gated lane, a
highway without a footpath, a crossing that does not exist).

Every request is counted in the api_usage table. Checks stop (and routes are
returned marked "not checked") when the daily or monthly limit is reached, so
the bill can never run away.
"""

import os
from dataclasses import dataclass
from datetime import date, datetime, timezone

import numpy as np
import requests

from northstar import config

URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
API_NAME = "google_routes"
# Basic walking routes with at most 10 intermediate points are billed as Routes
# "Essentials": 70,000 free a month with an Indian billing account. The Google
# Cloud console also caps compute routes at 1,000 a day.
MONTHLY_LIMIT = int(os.getenv("GOOGLE_ROUTES_MONTHLY_LIMIT", "60000"))
DAILY_LIMIT = int(os.getenv("GOOGLE_ROUTES_DAILY_LIMIT", "900"))

MAX_RATIO = 1.15     # Google may need at most 15% more distance than us
MIN_OVERLAP = 0.80   # and must follow at least 80% of our line


@dataclass
class WalkCheck:
    checked: bool             # False when Google was not asked (no key, limit reached, error)
    walkable: bool | None     # None when not checked
    ratio: float | None = None
    overlap: float | None = None
    note: str = ""


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


def _metres(points: np.ndarray, lat0: float) -> np.ndarray:
    return np.column_stack([points[:, 1] * np.cos(np.radians(lat0)) * 111_320, points[:, 0] * 111_320])


def overlap(ours: list, google: list, within_m: float = 25) -> float:
    """Share of our route's points that lie within `within_m` of Google's line."""
    if len(google) < 2:
        return 0.0
    a, b = np.array(ours), np.array(google)
    lat0 = float(a[:, 0].mean())
    a, b = _metres(a, lat0), _metres(b, lat0)
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


def _usage(conn, month: date) -> int:
    row = conn.execute("select coalesce(sum(requests), 0) from api_usage where api = %s and month = %s",
                       (API_NAME, month)).fetchone()
    return int(row[0])


def _count(conn, month: date) -> None:
    conn.execute(
        "insert into api_usage (api, month, requests) values (%s, %s, 1) "
        "on conflict (api, month) do update set requests = api_usage.requests + 1",
        (API_NAME, month))
    conn.commit()  # counted at once, so a later failure cannot lose the count


def budget_left(conn) -> bool:
    """True while this month's and today's requests are under their limits.

    The daily count uses a row with the month set to today's date (api_usage is
    keyed by api and date, so a day is stored as a separate "month" row under
    the name google_routes_day).
    """
    today = datetime.now(timezone.utc).date()
    month_used = _usage(conn, today.replace(day=1))
    day_used = int(conn.execute("select coalesce(sum(requests), 0) from api_usage where api = %s and month = %s",
                                (API_NAME + "_day", today)).fetchone()[0])
    return month_used < MONTHLY_LIMIT and day_used < DAILY_LIMIT


def google_walk(conn, shape: list) -> tuple[float, list]:
    """Google's walking distance (metres) and line through our route's points.
    Returns (nan, []) when Google finds no walking route. Raises on HTTP errors."""
    today = datetime.now(timezone.utc).date()
    picks = [shape[round(i * (len(shape) - 1) / 11)] for i in range(1, 11)]
    location = lambda p: {"location": {"latLng": {"latitude": p[0], "longitude": p[1]}}}
    response = requests.post(URL, timeout=30, headers={
        "X-Goog-Api-Key": config.GOOGLE_AIR_QUALITY_KEY,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.polyline.encodedPolyline",
    }, json={"origin": location(shape[0]), "destination": location(shape[-1]),
             "intermediates": [{**location(p), "via": True} for p in picks], "travelMode": "WALK"})
    _count(conn, today.replace(day=1))
    conn.execute(
        "insert into api_usage (api, month, requests) values (%s, %s, 1) "
        "on conflict (api, month) do update set requests = api_usage.requests + 1",
        (API_NAME + "_day", today))
    conn.commit()
    if response.status_code != 200:
        # Only the status code: the response body could echo request details.
        raise RuntimeError(f"Google Routes: HTTP {response.status_code}")
    routes = response.json().get("routes")
    if not routes:
        return float("nan"), []  # Google found no walking route through these points
    route = routes[0]
    return float(route["distanceMeters"]), decode_polyline(route["polyline"]["encodedPolyline"])


def check(conn, shape: list, distance_m: float) -> WalkCheck:
    """Ask Google whether a route can really be walked as drawn."""
    if not config.GOOGLE_AIR_QUALITY_KEY:
        return WalkCheck(checked=False, walkable=None, note="no Google key")
    if not budget_left(conn):
        return WalkCheck(checked=False, walkable=None, note="Google limit reached")
    try:
        google_m, line = google_walk(conn, shape)
    except (requests.RequestException, RuntimeError) as error:
        return WalkCheck(checked=False, walkable=None, note=str(error))
    if not line:
        return WalkCheck(checked=True, walkable=False, note="Google found no walking route")
    ratio = google_m / max(distance_m, 1.0)
    share = overlap(shape, line)
    return WalkCheck(checked=True, walkable=ratio <= MAX_RATIO and share >= MIN_OVERLAP,
                     ratio=round(ratio, 3), overlap=round(share, 3))
