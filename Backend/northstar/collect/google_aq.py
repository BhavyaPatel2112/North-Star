"""Google Air Quality API: hourly readings at comparison points, with a spending guard.

Google's Air Quality service estimates pollution at 500 m detail by blending
sensors, models and traffic data. We fetch its current reading at 20 points
every hour and save it next to our own model's prediction for the same
hexagon and hour, so after a few days we can compare the two (and both with
real station readings whenever those are available).

Spending guard: every request is counted per month. When the monthly limit
is reached, fetching stops and the job reports an error (so GitHub emails
the owner); it only continues after the limit is raised on purpose, through
the GOOGLE_MONTHLY_LIMIT setting. Google's own daily caps (2,000 a day in
total) are a second, independent stop.
"""

import os
from datetime import date

import h3
import pandas as pd
import psycopg
import requests

from northstar import config
from northstar.db.upsert import upsert_frame

API_URL = "https://airquality.googleapis.com/v1/currentConditions:lookup"
API_NAME = "google_air_quality"

# Requests allowed per calendar month (Indian free tier: 70,000). Raising
# this is the "approval" to continue after the guard stops.
MONTHLY_LIMIT = int(os.getenv("GOOGLE_MONTHLY_LIMIT", "55000"))

# 19 working stations spread across the area, plus extra spots of interest.
STATION_POINTS = [31, 33, 14, 30, 32, 15, 18, 7, 9, 16, 5, 34, 4, 21, 11, 25, 36, 2, 23]
EXTRA_POINTS = {"Thakur Village, Kandivali East": (19.2105, 72.8740)}

# Google reports gases in parts per billion; µg/m³ at 25 °C = ppb x these factors.
PPB_TO_UG = {"no2": 1.88, "o3": 1.96}


def comparison_points(conn: psycopg.Connection) -> list[dict]:
    rows = conn.execute(
        "select station_id, name, ST_Y(location::geometry), ST_X(location::geometry) "
        "from stations where station_id = any(%s)", (STATION_POINTS,)
    ).fetchall()
    points = [{"name": name, "station_id": sid, "latitude": lat, "longitude": lon} for sid, name, lat, lon in rows]
    points += [{"name": name, "station_id": None, "latitude": lat, "longitude": lon}
               for name, (lat, lon) in EXTRA_POINTS.items()]
    return points


def requests_this_month(conn: psycopg.Connection) -> int:
    row = conn.execute(
        "select requests from api_usage where api = %s and month = %s", (API_NAME, date.today().replace(day=1))
    ).fetchone()
    return row[0] if row else 0


def _count(conn: psycopg.Connection, n: int) -> None:
    conn.execute(
        "insert into api_usage (api, month, requests) values (%s, %s, %s) "
        "on conflict (api, month) do update set requests = api_usage.requests + excluded.requests",
        (API_NAME, date.today().replace(day=1), n),
    )


def fetch_point(latitude: float, longitude: float) -> dict:
    """One current-conditions request. Never puts the key in error messages."""
    response = requests.post(API_URL, params={"key": config.GOOGLE_AIR_QUALITY_KEY}, timeout=30, json={
        "location": {"latitude": latitude, "longitude": longitude},
        "extraComputations": ["LOCAL_AQI", "POLLUTANT_CONCENTRATION"],
        "customLocalAqis": [{"regionCode": "in", "aqi": "ind_cpcb"}],
        "languageCode": "en",
    })
    if response.status_code != 200:
        raise RuntimeError(f"Google Air Quality: HTTP {response.status_code}")
    data = response.json()
    values = {p["code"]: p["concentration"]["value"] for p in data.get("pollutants", [])}
    india = next((i for i in data.get("indexes", []) if i.get("code") == "ind_cpcb"), {})
    return {
        "ts": pd.Timestamp(data["dateTime"]).floor("h"),
        "pm25": values.get("pm25"),
        "pm10": values.get("pm10"),
        "no2": values["no2"] * PPB_TO_UG["no2"] if "no2" in values else None,
        "o3": values["o3"] * PPB_TO_UG["o3"] if "o3" in values else None,
        "aqi_india": india.get("aqi"),
        "category_india": india.get("category"),
    }


def update_google(conn: psycopg.Connection) -> str:
    """Collector job: fetch Google at every comparison point and save it with our prediction."""
    if not config.GOOGLE_AIR_QUALITY_KEY:
        return "Google: no key"
    points = comparison_points(conn)
    used = requests_this_month(conn)
    if used + len(points) > MONTHLY_LIMIT:
        raise RuntimeError(
            f"Google: monthly limit reached ({used:,} of {MONTHLY_LIMIT:,} requests). Paused; our own model "
            "is still used. Raise GOOGLE_MONTHLY_LIMIT to continue."
        )

    rows, sent = [], 0
    try:
        for point in points:
            sent += 1
            reading = fetch_point(point["latitude"], point["longitude"])
            cell = h3.latlng_to_cell(point["latitude"], point["longitude"], 9)
            ours = conn.execute(
                "select pm25, pm10, no2, o3 from grid_predictions where h3 = %s and ts = %s",
                (h3.str_to_int(cell), reading["ts"]),
            ).fetchone() or (None, None, None, None)
            rows.append({
                "point_name": point["name"], "station_id": point["station_id"], **reading,
                "model_pm25": ours[0], "model_pm10": ours[1], "model_no2": ours[2], "model_o3": ours[3],
            })
    finally:
        # Count every request sent, even if a later step fails, and save the
        # count at once so a failure can never hide usage from the guard.
        _count(conn, sent)
        conn.commit()

    frame = pd.DataFrame(rows)
    frame["station_id"] = frame.station_id.astype("Int16")  # whole numbers, empty for extra spots
    upsert_frame(conn, "google_readings", frame, ["point_name", "ts"])
    return (f"Google: {len(rows)} points at {rows[0]['ts']:%Y-%m-%d %H:%M} UTC "
            f"({used + sent:,} of {MONTHLY_LIMIT:,} requests this month)")
