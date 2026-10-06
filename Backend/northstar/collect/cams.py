"""CAMS air quality model data from Open-Meteo.

CAMS (the European Copernicus Atmosphere Monitoring Service) runs a global
pollution model, like a weather forecast for pollution. Open-Meteo serves it
on a grid of squares about 10 km apart, with history from mid-August 2022
and forecasts 5 days ahead. It is always available, unlike the government
station feeds, but it is coarse and often biased; our model learns to
correct it using the station readings.
"""

import time
from datetime import date, timedelta

import pandas as pd
import requests

from northstar import config

API_URL = "https://air-quality-api.open-meteo.com/v1/air-quality"
CAMS_RAW_DIR = config.RAW_DIR / "cams"
HISTORY_START = date(2022, 8, 1)  # CAMS data on Open-Meteo begins mid-August 2022

# Open-Meteo variable name -> our column name (see cams_hourly in schema.sql).
VARIABLES = {
    "pm2_5": "pm25",
    "pm10": "pm10",
    "nitrogen_dioxide": "no2",
    "ozone": "o3",
    "carbon_monoxide": "co",
    "sulphur_dioxide": "so2",
    "dust": "dust",
}

PAUSE_SECONDS = 4  # between history requests, to stay under the free limits


def _get(params: dict) -> dict | list:
    """Call the API, waiting and retrying if it says we are going too fast."""
    for attempt in range(5):
        response = requests.get(API_URL, params=params, timeout=120)
        if response.status_code == 429:
            time.sleep(60 * (attempt + 1))
            continue
        response.raise_for_status()
        return response.json()
    raise RuntimeError("Open-Meteo kept rate limiting the air quality API")


def _to_frame(result: dict) -> pd.DataFrame:
    frame = pd.DataFrame(result["hourly"]).rename(columns=VARIABLES)
    frame["ts"] = pd.to_datetime(frame.pop("time"), utc=True)
    return frame


def find_cells(latitudes: list[float], longitudes: list[float]) -> list[tuple[float, float]]:
    """Return the CAMS grid square (latitude, longitude) for each location."""
    results = _get({
        "latitude": ",".join(map(str, latitudes)),
        "longitude": ",".join(map(str, longitudes)),
        "hourly": "pm2_5",
        "start_date": "2025-01-01",
        "end_date": "2025-01-01",
    })
    if isinstance(results, dict):
        results = [results]
    return [(r["latitude"], r["longitude"]) for r in results]


def download_history(latitude: float, longitude: float, end: date) -> pd.DataFrame:
    """All hourly CAMS values for one grid square from HISTORY_START to `end`.

    Fetched one calendar year at a time; finished years are cached under
    data/raw/cams so re-runs only fetch the current year again.
    """
    folder = CAMS_RAW_DIR / f"cell_{latitude:.4f}_{longitude:.4f}"
    folder.mkdir(parents=True, exist_ok=True)
    pieces = []
    for year in range(HISTORY_START.year, end.year + 1):
        path = folder / f"{year}.parquet"
        if not path.exists() or year == end.year:
            result = _get({
                "latitude": latitude,
                "longitude": longitude,
                "hourly": ",".join(VARIABLES),
                "start_date": max(date(year, 1, 1), HISTORY_START).isoformat(),
                "end_date": min(date(year, 12, 31), end).isoformat(),
                "timezone": "GMT",
            })
            _to_frame(result).to_parquet(path, index=False)
            time.sleep(PAUSE_SECONDS)
        pieces.append(pd.read_parquet(path))
    frame = pd.concat(pieces, ignore_index=True)
    return frame.dropna(subset=list(VARIABLES.values()), how="all")


def fetch_recent(cells: list[tuple[float, float]], past_days: int = 2, forecast_days: int = 3) -> pd.DataFrame:
    """Recent hours plus the latest forecast for several grid squares in one request.

    Used by the hourly collector. Returns columns latitude, longitude, ts and
    one column per pollutant.
    """
    results = _get({
        "latitude": ",".join(str(lat) for lat, _ in cells),
        "longitude": ",".join(str(lon) for _, lon in cells),
        "hourly": ",".join(VARIABLES),
        "past_days": past_days,
        "forecast_days": forecast_days,
        "timezone": "GMT",
    })
    if isinstance(results, dict):
        results = [results]
    frames = []
    for (latitude, longitude), result in zip(cells, results):
        frame = _to_frame(result)
        frame["latitude"], frame["longitude"] = latitude, longitude
        frames.append(frame)
    return pd.concat(frames, ignore_index=True).dropna(subset=list(VARIABLES.values()), how="all")


def recent_end() -> date:
    """Last full day to request as history (today's hours come from fetch_recent)."""
    return date.today() - timedelta(days=1)
