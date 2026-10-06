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
- fires seen by satellite: nearby, regional, and upwind (smoke blowing this way)
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


EARTH_RADIUS_KM = 6371.0


def _distance_and_bearing(lat0, lon0, lat1, lon1):
    """Distance (km) and compass bearing (radians, 0 = north) from points 0 to points 1."""
    lat0, lon0, lat1, lon1 = map(np.radians, (lat0, lon0, lat1, lon1))
    d_lat, d_lon = lat1 - lat0, lon1 - lon0
    a = np.sin(d_lat / 2) ** 2 + np.cos(lat0) * np.cos(lat1) * np.sin(d_lon / 2) ** 2
    distance = 2 * EARTH_RADIUS_KM * np.arcsin(np.sqrt(a))
    bearing = np.arctan2(np.sin(d_lon) * np.cos(lat1),
                         np.cos(lat0) * np.sin(lat1) - np.sin(lat0) * np.cos(lat1) * np.cos(d_lon))
    return distance, bearing


def add_fire_features(frame: pd.DataFrame, fires: pd.DataFrame, locations: pd.DataFrame,
                      key: str = "station_id") -> pd.DataFrame:
    """Fire features for each row, from satellite detections before that hour.

    `locations` gives latitude and longitude per `key` (station or hexagon).
    - fire_count_25km_24h, fire_frp_25km_24h: fires within 25 km in the last 24 hours
    - fire_frp_100km_24h: total fire power within 100 km in the last 24 hours
    - fire_frp_300km_72h: total within 300 km in the last 72 hours (regional smoke lingers)
    - fire_upwind_300km_24h: fires within 300 km, counted more when the wind blows
      from them towards this place and when they are closer. Below 0 means
      the fires are mostly downwind.

    The upwind score uses cos(bearing to fire - direction the wind comes from),
    which splits into a part that depends only on the fire (summed once per
    hour) and a part that depends only on the wind at the row's hour, so it
    is fast to compute for every hour.
    """
    fire_hours = fires.detected_at.dt.floor("h")
    out = {name: np.zeros(len(frame), dtype="float32") for name in (
        "fire_count_25km_24h", "fire_frp_25km_24h", "fire_frp_100km_24h",
        "fire_frp_300km_72h", "fire_upwind_300km_24h")}
    hours_all = pd.date_range(frame.ts.min() - pd.Timedelta(hours=72), frame.ts.max(), freq="h")

    for place, rows in frame.groupby(key).groups.items():
        lat, lon = locations.loc[place, ["latitude", "longitude"]]
        distance, bearing = _distance_and_bearing(lat, lon, fires.latitude.to_numpy(), fires.longitude.to_numpy())
        near = distance <= 300
        f = pd.DataFrame({
            "hour": fire_hours[near].to_numpy(), "distance": distance[near],
            "bearing": bearing[near], "frp": fires.frp.to_numpy()[near],
        })
        closeness = f.frp / (1 + f.distance / 50)  # nearer fires count more
        f["count_25"] = (f.distance <= 25).astype(float)
        f["frp_25"] = f.frp * (f.distance <= 25)
        f["frp_100"] = f.frp * (f.distance <= 100)
        f["frp_300"] = f.frp
        f["up_cos"] = closeness * np.cos(f.bearing)
        f["up_sin"] = closeness * np.sin(f.bearing)
        hourly = f.groupby("hour")[["count_25", "frp_25", "frp_100", "frp_300", "up_cos", "up_sin"]].sum()
        hourly = hourly.reindex(hours_all, fill_value=0)
        last_24 = hourly.rolling(24, min_periods=1).sum()
        last_72 = hourly.frp_300.rolling(72, min_periods=1).sum()

        row_index = frame.index.get_indexer(rows)
        ts = frame.ts.to_numpy()[row_index]
        window = last_24.reindex(ts)
        wind_from = np.radians(frame.wind_dir_deg.to_numpy()[row_index])
        out["fire_count_25km_24h"][row_index] = window.count_25.to_numpy()
        out["fire_frp_25km_24h"][row_index] = window.frp_25.to_numpy()
        out["fire_frp_100km_24h"][row_index] = window.frp_100.to_numpy()
        out["fire_frp_300km_72h"][row_index] = last_72.reindex(ts).to_numpy()
        out["fire_upwind_300km_24h"][row_index] = (
            window.up_cos.to_numpy() * np.cos(wind_from) + window.up_sin.to_numpy() * np.sin(wind_from))

    for name, values in out.items():
        frame[name] = values
    return frame


def load_fires(conn: psycopg.Connection, start: str) -> pd.DataFrame:
    rows = conn.execute(
        "select detected_at, latitude, longitude, frp from fires where detected_at >= %s::timestamptz - interval '4 days'",
        (start,),
    ).fetchall()
    fires = pd.DataFrame(rows, columns=["detected_at", "latitude", "longitude", "frp"])
    fires["detected_at"] = pd.to_datetime(fires.detected_at, utc=True)
    return fires.astype({"latitude": float, "longitude": float, "frp": float})


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
    frame = add_weather_features(add_time_features(frame))
    frame = add_event_features(frame, load_events(conn))
    locations = pd.DataFrame(
        conn.execute("select station_id, ST_Y(location::geometry), ST_X(location::geometry) from stations").fetchall(),
        columns=["station_id", "latitude", "longitude"],
    ).set_index("station_id")
    return add_fire_features(frame, load_fires(conn, start), locations)


def target_is_real(frame: pd.DataFrame, target: str) -> pd.Series:
    """True where the target is a real reading (not missing, not gap-filled)."""
    filled = (frame.qc_flags.astype(int) // (2 ** TARGET_BIT[target])) % 2
    return frame[target].notna() & (filled == 0)


def feature_columns(frame: pd.DataFrame) -> list[str]:
    """Every input column (everything except identifiers, targets and flags)."""
    excluded = {"station_id", "ts", "qc_flags", *TARGETS}
    return [c for c in frame.columns if c not in excluded]
