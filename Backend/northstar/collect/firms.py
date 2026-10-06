"""Fire detections from NASA FIRMS (Fire Information for Resource Management System).

Two VIIRS satellites (Suomi NPP and NOAA-20) pass over Mumbai about twice a
day each and spot fires as small as a few hundred square metres: landfill
fires at Deonar and Kanjurmarg, mangrove and grass burning, crop and forest
fires inland. Smoke from these can raise pollution for days.

Each detection has a position, a time and a "fire radiative power" (FRP, in
megawatts): how much heat it gives off, a rough measure of how big it is.

NASA keeps two versions: "standard" (final, a few months late) and "near
real-time" (within about 3 hours). History uses standard where available
and near real-time after that.
"""

import io
import time
from datetime import date, timedelta

import pandas as pd
import psycopg
import requests

from northstar import config
from northstar.db.upsert import upsert_frame

API = "https://firms.modaps.eosdis.nasa.gov/api"
SATELLITES = ["VIIRS_SNPP", "VIIRS_NOAA20"]

# Box around Mumbai, about 500 km wide: far enough for inland crop and forest
# smoke to count, but starting at 72.0° east so the offshore Bombay High oil
# platform flares (permanent "fires" at sea) are left out.
REGION = (72.0, 17.0, 76.5, 21.5)  # west, south, east, north
MAX_DAYS_PER_REQUEST = 5  # the API refuses longer ranges


def _area_request(source: str, day: date, days: int) -> pd.DataFrame:
    """All detections from `source` in REGION for `days` days starting `day`."""
    region = ",".join(map(str, REGION))
    url = f"{API}/area/csv/{config.FIRMS_MAP_KEY}/{source}/{region}/{days}/{day.isoformat()}"
    for attempt in range(5):
        response = requests.get(url, timeout=120)
        if response.status_code == 429:
            time.sleep(60 * (attempt + 1))
            continue
        if response.status_code != 200:
            # Never include the URL in the message: it contains the secret key.
            raise RuntimeError(f"FIRMS {source} {day}: HTTP {response.status_code}: {response.text[:100]}")
        text = response.text.strip()
        if not text or text.startswith("Invalid") or "\n" not in text:
            return pd.DataFrame()
        return pd.read_csv(io.StringIO(text))
    raise RuntimeError("FIRMS kept rate limiting")


def _standard_until() -> date:
    """Last date the final ("standard") archive covers."""
    table = pd.read_csv(io.StringIO(
        requests.get(f"{API}/data_availability/csv/{config.FIRMS_MAP_KEY}/ALL", timeout=60).text))
    return pd.to_datetime(table.loc[table.data_id == "VIIRS_SNPP_SP", "max_date"].iloc[0]).date()


def _tidy(raw: pd.DataFrame, satellite: str) -> pd.DataFrame:
    if raw.empty:
        return pd.DataFrame(columns=["detected_at", "latitude", "longitude", "frp", "confidence", "satellite"])
    # acq_time is UTC "hhmm" without leading zeros, e.g. 733 = 07:33.
    if "type" in raw:  # standard archive only: 3 = offshore (oil and gas platforms)
        raw = raw[raw["type"] != 3]
    hhmm = raw.acq_time.astype(int).astype(str).str.zfill(4)
    detected = pd.to_datetime(raw.acq_date + " " + hhmm.str[:2] + ":" + hhmm.str[2:], utc=True)
    return pd.DataFrame({
        "detected_at": detected,
        "latitude": raw.latitude.round(5),
        "longitude": raw.longitude.round(5),
        "frp": raw.frp,
        "confidence": raw.confidence.astype(str),
        "satellite": satellite,
    })


def download(start: date, end: date) -> pd.DataFrame:
    """Every detection between `start` and `end` (inclusive) from both satellites."""
    standard_until = _standard_until()
    pieces = []
    for satellite in SATELLITES:
        day = start
        while day <= end:
            days = min(MAX_DAYS_PER_REQUEST, (end - day).days + 1)
            # Do not let one request straddle the standard / near real-time boundary.
            if day <= standard_until < day + timedelta(days=days - 1):
                days = (standard_until - day).days + 1
            source = f"{satellite}_SP" if day <= standard_until else f"{satellite}_NRT"
            pieces.append(_tidy(_area_request(source, day, days), satellite))
            day += timedelta(days=days)
    frame = pd.concat(pieces, ignore_index=True)
    # Low-confidence detections are often false alarms (hot roofs, sun glint).
    return frame[frame.confidence != "l"].drop_duplicates(["satellite", "detected_at", "latitude", "longitude"])


def save(conn: psycopg.Connection, fires: pd.DataFrame) -> int:
    if fires.empty:
        return 0
    return upsert_frame(conn, "fires", fires, ["satellite", "detected_at", "latitude", "longitude"])


def update_recent(conn: psycopg.Connection, days: int = 3) -> str:
    """Collector job: fetch the last few days of detections."""
    if not config.FIRMS_MAP_KEY:
        return "Fires: no key"
    fires = download(date.today() - timedelta(days=days - 1), date.today())
    save(conn, fires)
    newest = fires.detected_at.max() if len(fires) else None
    return f"Fires: {len(fires)} detections in the last {days} days, newest {newest}"
