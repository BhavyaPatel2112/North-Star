"""Build model inputs: one row per place per hour.

The same function makes the rows for training (stations, past hours) and for
prediction (hexagons, current and future hours), so the model always sees
inputs built exactly the same way.

Each row combines:
- CAMS values for that hour (the coarse model we correct)
- weather for that hour
- city-layout features of the place (roads, industry, green, coast...)
- time: hour of day and day of week in Indian time, season
- festivals: days since and until each festival (Diwali, Ganesh Chaturthi...)

Satellite fire features were tested (October 2026) and left out: they did
not improve predictions even in fire-affected hours, because CAMS already
includes fire smoke from the same satellites. Fires are still collected
and shown in the app as information.
"""

import json

import numpy as np
import pandas as pd
import psycopg

from northstar import config
from northstar.collect.events import EVENT_TYPES, load_events

TRAINING_FILE = config.PROCESSED_DIR / "training.parquet"
TARGETS = ["pm25", "pm10", "no2", "o3"]  # pollutants we predict
TARGET_BIT = {"pm25": 0, "pm10": 1, "no2": 2, "o3": 5}  # qc_flags bit per pollutant

CAMS_COLUMNS = ["pm25", "pm10", "no2", "o3", "co", "so2", "dust"]
WEATHER_COLUMNS = [
    "temperature_c", "relative_humidity", "dew_point_c", "precipitation_mm", "pressure_hpa",
    "cloud_cover", "wind_speed_ms", "wind_dir_deg", "wind_gust_ms", "shortwave_radiation",
    "boundary_layer_height_m",
]

# Festival effects are measured up to this many days before and after.
EVENT_WINDOW_DAYS = 21


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
    return frame


def add_event_features(frame: pd.DataFrame, events: pd.DataFrame) -> pd.DataFrame:
    """For each festival type: days since it last started and days until it next starts.

    Counting days (instead of a yes/no "is it Diwali") lets the model learn
    how pollution builds up before a festival and how long it lingers after,
    for example several days of poor air after Diwali. Values are capped at
    EVENT_WINDOW_DAYS, meaning "not near this festival".
    """
    local_day = frame.ts.dt.tz_convert("Asia/Kolkata").dt.normalize().dt.tz_localize(None)
    days = local_day.to_numpy().astype("datetime64[D]")
    for event_type in EVENT_TYPES:
        dates = np.sort(pd.to_datetime(
            events.loc[events.event_type == event_type, "event_date"]).to_numpy().astype("datetime64[D]"))
        if len(dates) == 0:
            frame[f"days_since_{event_type}"] = EVENT_WINDOW_DAYS
            frame[f"days_until_{event_type}"] = EVENT_WINDOW_DAYS
            continue
        # Where each day falls among the festival dates. On the festival day
        # itself both "since" and "until" are 0.
        on_or_before = np.searchsorted(dates, days, side="right") - 1  # latest festival today or earlier
        on_or_after = np.searchsorted(dates, days, side="left")        # next festival today or later
        since = np.where(on_or_before >= 0,
                         (days - dates[np.clip(on_or_before, 0, None)]).astype(int), EVENT_WINDOW_DAYS)
        until = np.where(on_or_after < len(dates),
                         (dates[np.clip(on_or_after, None, len(dates) - 1)] - days).astype(int), EVENT_WINDOW_DAYS)
        frame[f"days_since_{event_type}"] = np.minimum(since, EVENT_WINDOW_DAYS).astype("float32")
        frame[f"days_until_{event_type}"] = np.minimum(until, EVENT_WINDOW_DAYS).astype("float32")
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
    frame = _finish(frame, conn, keep=["ts"])
    frame["station_id"] = frame.station_id.astype("int16")
    return frame


def load_grid_rows(conn: psycopg.Connection, start: pd.Timestamp, end: pd.Timestamp) -> pd.DataFrame:
    """Every map hexagon for every hour from `start` to `end`, with all inputs.

    Built exactly like the station rows, so the model sees the same kind of
    input for a hexagon as it saw for stations during training.
    """
    cams = ", ".join(f"{c} as cams_{c}" for c in CAMS_COLUMNS)
    grid = pd.DataFrame(
        conn.execute("select h3_index, cams_cell_id, weather_cell_id, features from grid_cells").fetchall(),
        columns=["h3_index", "cams_cell_id", "weather_cell_id", "features"],
    )
    cams_rows = conn.execute(
        f"select cell_id as cams_cell_id, ts, {cams} from cams_hourly where ts between %s and %s", (start, end)
    )
    cams_frame = pd.DataFrame(cams_rows.fetchall(), columns=[d.name for d in cams_rows.description])
    weather_rows = conn.execute(
        f"select cell_id as weather_cell_id, ts, {', '.join(WEATHER_COLUMNS)} from weather_hourly "
        "where ts between %s and %s", (start, end)
    )
    weather_frame = pd.DataFrame(weather_rows.fetchall(), columns=[d.name for d in weather_rows.description])

    # Every hexagon x every hour that has both CAMS and weather.
    frame = grid.merge(cams_frame, on="cams_cell_id").merge(weather_frame, on=["weather_cell_id", "ts"])
    return _finish(frame, conn, keep=["ts", "h3_index"])


def _finish(frame: pd.DataFrame, conn: psycopg.Connection, keep: list[str]) -> pd.DataFrame:
    """Shared last steps: numbers as 32-bit floats, then time, weather and festival inputs."""
    frame["ts"] = pd.to_datetime(frame.ts, utc=True)
    frame = _expand_features(frame)
    numeric = frame.columns.difference(keep)
    frame[numeric] = frame[numeric].apply(pd.to_numeric).astype("float32")
    frame = add_weather_features(add_time_features(frame))
    return add_event_features(frame, load_events(conn))


def target_is_real(frame: pd.DataFrame, target: str) -> pd.Series:
    """True where the target is a real reading (not missing, not gap-filled)."""
    filled = (frame.qc_flags.astype(int) // (2 ** TARGET_BIT[target])) % 2
    return frame[target].notna() & (filled == 0)


def feature_columns(frame: pd.DataFrame) -> list[str]:
    """Every input column (everything except identifiers, targets and flags)."""
    excluded = {"station_id", "h3_index", "cams_cell_id", "weather_cell_id", "ts", "qc_flags", *TARGETS}
    return [c for c in frame.columns if c not in excluded]
