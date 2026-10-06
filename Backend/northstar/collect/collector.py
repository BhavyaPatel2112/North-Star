"""The hourly collector: keeps the database up to date.

Each run does four independent jobs. One failing never stops the others.
1. CAMS air quality model: recent hours plus a 3-day forecast (required by the model)
2. Weather: recent hours plus a 3-day forecast (required by the model)
3. OpenAQ station readings: re-fetch the last 7 days, clean, upsert
   (late uploads and corrections replace older values)
4. Health check of every station source, saved to source_checks, so we
   know when a broken feed comes back

The data.gov.in and World Air Quality Index readings are only checked and
logged for now. They will be written to air_readings_recent once a live
sample shows their format and units can be trusted.
"""

import json
import traceback
from datetime import datetime, timedelta, timezone

import pandas as pd
import psycopg
import requests

from northstar import config
from northstar.clean import openaq as clean
from northstar.collect import cams, open_meteo
from northstar.collect.openaq_archive import download_recent
from northstar.collect.stations import location_priority, openaq_location_ids
from northstar.db.air_readings import refresh_station_dates, upsert_air_readings
from northstar.db.upsert import upsert_frame

OPENAQ, DATAGOVIN, WAQI = 1, 2, 3
DATAGOVIN_URL = "https://api.data.gov.in/resource/3b01bcb8-0b14-4abf-b6f2-c1bfd384ba69"
DATAGOVIN_RAW_DIR = config.RAW_DIR / "datagovin"
MUMBAI_REGION = ["Mumbai", "Navi Mumbai", "Thane", "Kalyan", "Bhiwandi", "Mira-Bhayandar", "Vasai-Virar"]
IST = timezone(timedelta(hours=5, minutes=30))


def _cells(conn: psycopg.Connection, table: str) -> dict[int, tuple[float, float]]:
    rows = conn.execute(
        f"select cell_id, ST_Y(location::geometry), ST_X(location::geometry) from {table} order by cell_id"
    ).fetchall()
    return {cell_id: (lat, lon) for cell_id, lat, lon in rows}


def _attach_cell_ids(frame: pd.DataFrame, cells: dict[int, tuple[float, float]]) -> pd.DataFrame:
    by_location = {location: cell_id for cell_id, location in cells.items()}
    frame = frame.copy()
    frame["cell_id"] = [by_location[(lat, lon)] for lat, lon in zip(frame.latitude, frame.longitude)]
    return frame


def _log_check(conn, source_id, ok, newest=None, stations=None, message=None) -> None:
    conn.execute(
        "insert into source_checks (source_id, ok, newest_reading, stations_reporting, message) "
        "values (%s, %s, %s, %s, %s)",
        (source_id, ok, newest, stations, message),
    )


# --- 1 and 2: model inputs -----------------------------------------------------

def update_cams(conn: psycopg.Connection) -> str:
    cells = _cells(conn, "cams_cells")
    frame = _attach_cell_ids(cams.fetch_recent(list(cells.values())), cells)
    columns = ["cell_id", "ts", *cams.VARIABLES.values()]
    upsert_frame(conn, "cams_hourly", frame[columns], ["cell_id", "ts"])
    return f"CAMS: {len(frame):,} cell-hours up to {frame.ts.max():%Y-%m-%d %H:%M} UTC"


def update_weather(conn: psycopg.Connection) -> str:
    cells = _cells(conn, "weather_cells")
    frame = _attach_cell_ids(open_meteo.fetch_recent(list(cells.values())), cells)
    columns = ["cell_id", "ts", *open_meteo.VARIABLES.values()]
    upsert_frame(conn, "weather_hourly", frame[columns], ["cell_id", "ts"])
    return f"Weather: {len(frame):,} cell-hours up to {frame.ts.max():%Y-%m-%d %H:%M} UTC"


# --- 3: OpenAQ station readings ----------------------------------------------

def update_openaq(conn: psycopg.Connection) -> str:
    paths = [p for p in download_recent(openaq_location_ids()) if p.exists()]
    if not paths:
        _log_check(conn, OPENAQ, False, message="no archive files in the last 7 days")
        return "OpenAQ: no files in the last 7 days"

    raw = pd.concat(
        (pd.read_csv(p, usecols=["location_id", "datetime", "parameter", "units", "value"]) for p in paths),
        ignore_index=True,
    )
    raw["datetime"] = pd.to_datetime(raw.datetime, utc=True, format="ISO8601")
    wide = clean.run_pipeline(raw, location_priority())
    wide["source_id"] = OPENAQ
    upsert_air_readings(conn, wide)
    refresh_station_dates(conn)

    newest = wide.ts.max()
    reporting = wide[wide.ts > newest - pd.Timedelta(hours=24)].station_id.nunique()
    age_hours = (datetime.now(timezone.utc) - newest).total_seconds() / 3600
    _log_check(conn, OPENAQ, age_hours < 6, newest, reporting, f"{age_hours:.0f} hours old")
    return f"OpenAQ: {len(wide):,} station-hours, newest {newest:%Y-%m-%d %H:%M} UTC ({age_hours:.0f} h old)"


# --- 4: health checks of the other live sources -------------------------------

def check_datagovin(conn: psycopg.Connection) -> str:
    """Ask the government portal for Mumbai-region stations and log what comes back.

    A copy of each successful response is kept in data/raw/datagovin so the
    format can be studied before these readings are used.
    """
    if not config.DATAGOVIN_API_KEY:
        return "data.gov.in: no key"
    try:
        response = requests.get(
            DATAGOVIN_URL,
            params={"api-key": config.DATAGOVIN_API_KEY, "format": "json", "limit": 2000,
                    "filters[state]": "Maharashtra"},
            timeout=60,
        )
        if response.status_code != 200:
            _log_check(conn, DATAGOVIN, False, message=f"HTTP {response.status_code}")
            return f"data.gov.in: HTTP {response.status_code}"
        records = pd.DataFrame(response.json().get("records", []))
    except (requests.RequestException, ValueError) as error:
        _log_check(conn, DATAGOVIN, False, message=type(error).__name__)
        return f"data.gov.in: {type(error).__name__}"

    DATAGOVIN_RAW_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M")
    (DATAGOVIN_RAW_DIR / f"{stamp}.json").write_text(records.to_json(orient="records"))

    mumbai = records[records.get("city", pd.Series(dtype=str)).isin(MUMBAI_REGION)] if len(records) else records
    if mumbai.empty:
        _log_check(conn, DATAGOVIN, False, message=f"{len(records)} records, none in the Mumbai region")
        return f"data.gov.in: {len(records)} records, none in the Mumbai region"
    # last_update is Indian time, for example "06-10-2026 15:00:00"
    newest = pd.to_datetime(mumbai.last_update, format="%d-%m-%Y %H:%M:%S").max().tz_localize(IST)
    age_hours = (datetime.now(timezone.utc) - newest).total_seconds() / 3600
    _log_check(conn, DATAGOVIN, age_hours < 6, newest, mumbai.station.nunique(), f"{age_hours:.0f} hours old")
    return f"data.gov.in: {mumbai.station.nunique()} Mumbai-region stations, newest {age_hours:.0f} h old"


def link_waqi_stations(conn: psycopg.Connection) -> int:
    """Match World Air Quality Index stations to ours by position (within 500 m).

    Done once; the matches are saved in station_sources so later runs can
    ask for exactly these stations.
    """
    found = {}
    for keyword in ["mumbai", "navi mumbai", "thane", "bhiwandi", "bhayandar", "dombivli"]:
        response = requests.get("https://api.waqi.info/search/",
                                params={"keyword": keyword, "token": config.WAQI_TOKEN}, timeout=60)
        for item in response.json().get("data", []):
            if item.get("station", {}).get("geo"):
                found[item["uid"]] = item["station"]["geo"]
    linked = 0
    for uid, (lat, lon) in found.items():
        match = conn.execute(
            "select station_id from stations "
            "where ST_DWithin(location, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 500) "
            "order by location <-> ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography limit 1",
            (lon, lat, lon, lat),
        ).fetchone()
        if match:
            conn.execute(
                "insert into station_sources (source_id, source_location_id, station_id) "
                "values (%s, %s, %s) on conflict do nothing",
                (WAQI, str(uid), match[0]),
            )
            linked += 1
    return linked


def check_waqi(conn: psycopg.Connection) -> str:
    if not config.WAQI_TOKEN:
        return "WAQI: no token"
    uids = [r[0] for r in conn.execute(
        "select source_location_id from station_sources where source_id = %s", (WAQI,)).fetchall()]
    if not uids:
        link_waqi_stations(conn)
        uids = [r[0] for r in conn.execute(
            "select source_location_id from station_sources where source_id = %s", (WAQI,)).fetchall()]

    newest_times = []
    for uid in uids:
        try:
            data = requests.get(f"https://api.waqi.info/feed/@{uid}/",
                                params={"token": config.WAQI_TOKEN}, timeout=30).json().get("data", {})
            if isinstance(data, dict) and data.get("time", {}).get("iso"):
                newest_times.append(pd.Timestamp(data["time"]["iso"]).tz_convert("UTC"))
        except (requests.RequestException, ValueError):
            continue
    if not newest_times:
        _log_check(conn, WAQI, False, message=f"no readings from {len(uids)} linked stations")
        return f"WAQI: no readings from {len(uids)} linked stations"
    newest = max(newest_times)
    fresh = sum(t > datetime.now(timezone.utc) - timedelta(hours=6) for t in newest_times)
    age_hours = (datetime.now(timezone.utc) - newest).total_seconds() / 3600
    _log_check(conn, WAQI, fresh > 0, newest, fresh, f"{age_hours:.0f} hours old")
    return f"WAQI: {len(uids)} linked stations, {fresh} fresh, newest {age_hours:.0f} h old"


# --- run everything -----------------------------------------------------------

JOBS = [update_cams, update_weather, update_openaq, check_datagovin, check_waqi]


def run_once(conn: psycopg.Connection) -> list[str]:
    """Run every job, committing after each. A failure is reported and skipped."""
    report = []
    for job in JOBS:
        try:
            report.append(job(conn))
            conn.commit()
        except Exception as error:
            conn.rollback()
            report.append(f"{job.__name__} FAILED: {type(error).__name__}: {error}")
            traceback.print_exc()
    # Keep source_checks small: three months is plenty.
    conn.execute("delete from source_checks where checked_at < now() - interval '90 days'")
    conn.commit()
    return report
