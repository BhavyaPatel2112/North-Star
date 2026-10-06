"""Build model inputs: one row per place per hour.

The same function makes the rows for training (stations, past hours) and for
prediction (hexagons, current and future hours), so the model always sees
inputs built exactly the same way.

Each row combines:
- CAMS values for that hour (the coarse model we correct)
- weather for that hour
- city-layout features of the place (roads, industry, green, coast...)
- time: hour of day and day of week in Indian time, season, festival days
"""

import json
from datetime import date

import numpy as np
import pandas as pd
import psycopg

from northstar import config

TRAINING_FILE = config.PROCESSED_DIR / "training.parquet"
TARGETS = ["pm25", "pm10", "no2", "o3"]  # pollutants we predict
TARGET_BIT = {"pm25": 0, "pm10": 1, "no2": 2, "o3": 5}  # qc_flags bit per pollutant

CAMS_COLUMNS = ["pm25", "pm10", "no2", "o3", "co", "so2", "dust"]
WEATHER_COLUMNS = [
    "temperature_c", "relative_humidity", "dew_point_c", "precipitation_mm", "pressure_hpa",
    "cloud_cover", "wind_speed_ms", "wind_dir_deg", "wind_gust_ms", "shortwave_radiation",
    "boundary_layer_height_m",
]

# Main Diwali day each year: firecrackers cause the worst hours of the year.
DIWALI = [date(2022, 10, 24), date(2023, 11, 12), date(2024, 11, 1), date(2025, 10, 21), date(2026, 11, 8)]


def add_time_features(frame: pd.DataFrame) -> pd.DataFrame:
    """Hour, weekday and season in Indian time, plus a festival flag."""
    local = frame.ts.dt.tz_convert("Asia/Kolkata")
    frame["hour_ist"] = local.dt.hour
    frame["weekday"] = local.dt.weekday
    frame["month"] = local.dt.month
    # Day of year as a point on a circle, so 31 December sits next to 1 January.
    day = local.dt.dayofyear
    frame["season_sin"] = np.sin(2 * np.pi * day / 365.25)
    frame["season_cos"] = np.cos(2 * np.pi * day / 365.25)
    days_from_diwali = pd.Series(
        [min(abs((d - festival).days) for festival in DIWALI) for d in local.dt.date], index=frame.index
    )
    frame["diwali_window"] = (days_from_diwali <= 2).astype("int8")
    return frame


def add_weather_features(frame: pd.DataFrame) -> pd.DataFrame:
    """Wind as east-west and north-south parts (a direction of 359° and 1° are
    nearly the same wind, which a plain angle hides)."""
    radians = np.radians(frame.wind_dir_deg)
    frame["wind_u"] = -frame.wind_speed_ms * np.sin(radians)  # wind blowing towards the east
    frame["wind_v"] = -frame.wind_speed_ms * np.cos(radians)  # wind blowing towards the north
    # Same amount of pollution in a shallower layer means higher concentrations.
    frame["ventilation"] = frame.wind_speed_ms * frame.boundary_layer_height_m
    return frame


def _expand_features(frame: pd.DataFrame, column: str = "features") -> pd.DataFrame:
    expanded = pd.DataFrame([json.loads(f) if isinstance(f, str) else f for f in frame[column]], index=frame.index)
    return pd.concat([frame.drop(columns=column), expanded], axis=1)


def load_station_rows(conn: psycopg.Connection, start: str = "2022-08-04") -> pd.DataFrame:
    """Every station-hour since `start` with its readings and all inputs."""
    cams = ", ".join(f"c.{c} as cams_{c}" for c in CAMS_COLUMNS)
    weather = ", ".join(f"w.{c}" for c in WEATHER_COLUMNS)
    query = f"""
        select a.station_id, a.ts, a.pm25, a.pm10, a.no2, a.o3, a.qc_flags,
               {cams}, {weather}, f.features
        from air_readings_hourly a
        join stations s using (station_id)
        join station_features f using (station_id)
        join cams_hourly c on c.cell_id = s.cams_cell_id and c.ts = a.ts
        join weather_hourly w on w.cell_id = s.weather_cell_id and w.ts = a.ts
        where a.ts >= %s
    """
    with conn.cursor() as cursor:
        cursor.execute(query, (start,))
        columns = [d.name for d in cursor.description]
        frame = pd.DataFrame(cursor.fetchall(), columns=columns)
    frame["ts"] = pd.to_datetime(frame.ts, utc=True)
    frame = _expand_features(frame)
    numeric = frame.columns.difference(["ts"])
    frame[numeric] = frame[numeric].apply(pd.to_numeric).astype("float32")
    frame["station_id"] = frame.station_id.astype("int16")
    return add_weather_features(add_time_features(frame))


def target_is_real(frame: pd.DataFrame, target: str) -> pd.Series:
    """True where the target is a real reading (not missing, not gap-filled)."""
    filled = (frame.qc_flags.astype(int) // (2 ** TARGET_BIT[target])) % 2
    return frame[target].notna() & (filled == 0)


def feature_columns(frame: pd.DataFrame) -> list[str]:
    """Every input column (everything except identifiers, targets and flags)."""
    excluded = {"station_id", "ts", "qc_flags", *TARGETS}
    return [c for c in frame.columns if c not in excluded]
