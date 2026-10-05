"""Download historical hourly weather from Open-Meteo.

Open-Meteo's Historical Weather API serves reanalysis data (a best estimate
of past weather built from observations and a weather model) on a grid of
squares about 8 km apart. Every station is matched to its nearest grid
square, and weather is downloaded once per square, not once per station.

Files are saved as data/raw/open_meteo/cell_<lat>_<lon>/<year>.parquet.
Finished years are skipped on re-runs; the current year is always refreshed.
"""

import time
from datetime import date, timedelta

import pandas as pd
import requests

from northstar import config

ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
OPEN_METEO_RAW_DIR = config.RAW_DIR / "open_meteo"

# Open-Meteo variable name -> our column name (see weather_hourly in schema.sql).
VARIABLES = {
    "temperature_2m": "temperature_c",
    "relative_humidity_2m": "relative_humidity",
    "dew_point_2m": "dew_point_c",
    "precipitation": "precipitation_mm",
    "surface_pressure": "pressure_hpa",
    "cloud_cover": "cloud_cover",
    "wind_speed_10m": "wind_speed_ms",
    "wind_direction_10m": "wind_dir_deg",
    "wind_gusts_10m": "wind_gust_ms",
    "shortwave_radiation": "shortwave_radiation",
    # Height of the air layer pollution mixes into. Low at night and in
    # winter, which traps pollution near the ground.
    "boundary_layer_height": "boundary_layer_height_m",
}

# "nearest" picks the closest grid square even if it is mostly sea. The
# default ("land") sent Colaba to a square 15.7 km away; "nearest" keeps
# every station within 5.5 km.
CELL_SELECTION = "nearest"

# Recent days are not final in the archive yet.
ARCHIVE_DELAY_DAYS = 2

# Pause between requests to stay well under the free plan's per-minute limit.
PAUSE_SECONDS = 4


def find_cells(latitudes: list[float], longitudes: list[float]) -> list[tuple[float, float, float]]:
    """Return the (latitude, longitude, elevation) of the grid square for each location."""
    response = requests.get(
        ARCHIVE_URL,
        params={
            "latitude": ",".join(map(str, latitudes)),
            "longitude": ",".join(map(str, longitudes)),
            "start_date": "2021-01-01",
            "end_date": "2021-01-01",
            "hourly": "temperature_2m",
            "cell_selection": CELL_SELECTION,
        },
        timeout=60,
    )
    response.raise_for_status()
    results = response.json()
    if isinstance(results, dict):  # a single location comes back as one object
        results = [results]
    return [(r["latitude"], r["longitude"], r["elevation"]) for r in results]


def cell_dir(latitude: float, longitude: float):
    return OPEN_METEO_RAW_DIR / f"cell_{latitude:.4f}_{longitude:.4f}"


def download_year(latitude: float, longitude: float, year: int, end: date) -> pd.DataFrame:
    """Fetch one calendar year (up to `end`) of hourly weather for one grid square, in UTC."""
    for attempt in range(5):
        response = requests.get(
            ARCHIVE_URL,
            params={
                "latitude": latitude,
                "longitude": longitude,
                "start_date": f"{year}-01-01",
                "end_date": min(date(year, 12, 31), end).isoformat(),
                "hourly": ",".join(VARIABLES),
                "wind_speed_unit": "ms",
                "timezone": "GMT",
                "cell_selection": CELL_SELECTION,
            },
            timeout=120,
        )
        if response.status_code == 429:  # rate limited: wait and retry
            time.sleep(60 * (attempt + 1))
            continue
        response.raise_for_status()
        hourly = response.json()["hourly"]
        frame = pd.DataFrame(hourly).rename(columns=VARIABLES)
        frame["ts"] = pd.to_datetime(frame.pop("time"), utc=True)
        return frame
    raise RuntimeError(f"Open-Meteo kept rate limiting {latitude},{longitude} {year}")


def download_cells(cells: list[tuple[float, float]], start: date) -> None:
    """Download every year from `start` to now for each grid square."""
    end = date.today() - timedelta(days=ARCHIVE_DELAY_DAYS)
    for latitude, longitude in cells:
        folder = cell_dir(latitude, longitude)
        folder.mkdir(parents=True, exist_ok=True)
        for year in range(start.year, end.year + 1):
            path = folder / f"{year}.parquet"
            if path.exists() and year < end.year:
                continue
            frame = download_year(latitude, longitude, year, end)
            frame = frame[frame.ts >= pd.Timestamp(start, tz="UTC")]
            frame.to_parquet(path, index=False)
            print(f"  cell {latitude:.4f},{longitude:.4f} {year}: {len(frame)} hours")
            time.sleep(PAUSE_SECONDS)
