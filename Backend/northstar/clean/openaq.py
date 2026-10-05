"""Clean raw OpenAQ readings into one tidy row per station per hour.

Steps, in order (each is its own function so it can be tested and explained):
1. fix_units          the 2025+ feed labels gases "ppb" but sends government units
2. remove_invalid     negative values, instrument error codes, impossible values
3. to_hourly          average 15-minute readings into hours (needs 2+ readings)
4. merge_duplicates   combine several OpenAQ ids that are the same physical station
5. remove_stuck       drop runs of 6+ identical hours (a frozen sensor)
6. remove_pm_mismatch drop hours where PM2.5 is clearly above PM10 (impossible)
7. fill_short_gaps    fill gaps of 1 to 2 hours by straight-line interpolation
8. to_wide            one row per station-hour, one column per pollutant

Every function returns a new table and leaves its input unchanged. All
concentrations end up in micrograms per cubic metre (µg/m³).
"""

import numpy as np
import pandas as pd

# Pollutant columns, in the same order as air_readings_hourly in schema.sql.
# The position in this list is also the pollutant's bit in qc_flags.
POLLUTANTS = ["pm25", "pm10", "no2", "no", "nox", "o3", "co", "so2"]

# Values the instruments send to mean "error" or "out of range". They are
# not used for carbon monoxide, where 1000 µg/m³ (1 mg/m³) is a normal reading.
ERROR_CODES = {985.0, 999.0, 1000.0, 99999.0}

# Anything above these (µg/m³) is physically implausible for a Mumbai station
# hour. Real Mumbai peaks (Diwali, winter nights) are well below them.
UPPER_LIMITS = {
    "pm25": 985.0,
    "pm10": 1500.0,
    "no2": 1000.0,
    "no": 1500.0,
    "o3": 600.0,
    "co": 50000.0,  # 50 mg/m³
    "so2": 1000.0,
}

STUCK_HOURS = 6       # this many identical hourly values in a row = frozen sensor
MAX_FILL_HOURS = 2    # longest gap filled by interpolation
MIN_READINGS = 2      # 15-minute readings needed to trust an hourly average


def fix_units(raw: pd.DataFrame) -> pd.DataFrame:
    """Put every reading in µg/m³.

    Since 2025, OpenAQ labels Indian government gas readings "ppb", but the
    numbers are the government's own units: carbon monoxide in mg/m³ and
    the other gases in µg/m³. (Carbon monoxide at "0.42 ppb" would be
    impossible; 0.42 mg/m³ matches the older data.) Nitrogen oxides in that
    feed are around 0.01 in every station, which fits no unit, so they are dropped.
    """
    df = raw[raw.parameter.isin(POLLUTANTS)].copy()
    mislabelled = df.units == "ppb"
    df = df[~(mislabelled & (df.parameter == "nox"))]
    mislabelled = df.units == "ppb"
    df.loc[mislabelled & (df.parameter == "co"), "value"] *= 1000
    df.loc[mislabelled, "units"] = "µg/m³"
    return df[df.units == "µg/m³"].drop(columns="units")


def remove_invalid(df: pd.DataFrame) -> pd.DataFrame:
    """Drop negative values, instrument error codes and impossible values."""
    is_error_code = df.value.isin(ERROR_CODES) & (df.parameter != "co")
    too_high = df.value > df.parameter.map(UPPER_LIMITS)
    return df[(df.value >= 0) & ~is_error_code & ~too_high]


def to_hourly(df: pd.DataFrame) -> pd.DataFrame:
    """Average readings into UTC hours, labelled by the hour's start time.

    Hours are UTC hours, the same as the weather table, so pollution and
    weather line up exactly. (India is UTC+5:30, so an Indian clock hour
    such as 09:00-10:00 runs from 03:30 to 04:30 UTC; using Indian hours
    would put every pollution hour half an hour off its weather hour.)

    Each OpenAQ timestamp marks the END of its measuring period, so a reading
    at 03:15 UTC covers 03:00-03:15 and one at 04:00 covers 03:45-04:00; both
    belong to the 03:00 hour. Subtracting one second before rounding down
    puts exact hour marks into the hour they close. For 15-minute stations
    this is exact. Stations reporting once an hour on Indian clock hours
    (the US Consulate) end up shifted by 30 minutes, which is acceptable.

    An hour needs at least MIN_READINGS readings, except for locations that
    only report once an hour (such as the US Consulate).
    """
    df = df.copy()
    df["ts"] = (df.datetime - pd.Timedelta(seconds=1)).dt.floor("h")
    hourly = (
        df.groupby(["location_id", "parameter", "ts"])
        .value.agg(["mean", "count"])
        .reset_index()
    )
    # How many readings per hour does each location normally send?
    usual = hourly.groupby("location_id")["count"].transform("median")
    enough = (hourly["count"] >= MIN_READINGS) | (usual <= 1)
    return hourly[enough].rename(columns={"mean": "value"}).drop(columns="count")


def merge_duplicates(hourly: pd.DataFrame, location_priority: dict[int, tuple[int, int]]) -> pd.DataFrame:
    """Map OpenAQ locations to stations, keeping one value per station-hour.

    location_priority maps an OpenAQ location id to (station_id, priority);
    lower priority numbers win when two ids report the same hour.
    """
    df = hourly[hourly.location_id.isin(location_priority)].copy()
    df["station_id"] = df.location_id.map(lambda i: location_priority[i][0])
    df["priority"] = df.location_id.map(lambda i: location_priority[i][1])
    df = df.sort_values("priority").drop_duplicates(["station_id", "parameter", "ts"])
    return df.drop(columns=["location_id", "priority"])


def remove_stuck(df: pd.DataFrame) -> pd.DataFrame:
    """Drop runs of STUCK_HOURS or more consecutive hours with the same value."""
    df = df.sort_values(["station_id", "parameter", "ts"]).copy()
    key = [df.station_id, df.parameter]
    # A new run starts when the value changes, the series changes, or an hour is skipped.
    new_run = (
        (df.value.round(3) != df.groupby(key).value.shift().round(3))
        | (df.ts - df.groupby(key).ts.shift() != pd.Timedelta(hours=1))
    )
    run_id = new_run.cumsum()
    run_length = df.groupby(run_id).value.transform("size")
    return df[run_length < STUCK_HOURS]


def to_wide(df: pd.DataFrame) -> pd.DataFrame:
    """One row per station-hour with a column for each pollutant."""
    wide = df.pivot_table(index=["station_id", "ts"], columns="parameter", values="value")
    wide = wide.reindex(columns=POLLUTANTS).reset_index()
    wide.columns.name = None
    wide["qc_flags"] = 0
    return wide


def remove_pm_mismatch(wide: pd.DataFrame, tolerance: float = 1.1) -> pd.DataFrame:
    """Blank PM2.5 and PM10 where PM2.5 > PM10 by more than 10%.

    PM2.5 particles are part of PM10, so PM2.5 cannot really exceed it. When
    it does, one of the two sensors is wrong and we cannot tell which.
    """
    wide = wide.copy()
    bad = wide.pm25 > wide.pm10 * tolerance
    wide.loc[bad, ["pm25", "pm10"]] = np.nan
    return wide


def fill_short_gaps(wide: pd.DataFrame) -> pd.DataFrame:
    """Fill gaps of up to MAX_FILL_HOURS hours by drawing a straight line.

    Only gaps with real readings on both sides are filled. Filled values
    set that pollutant's bit in qc_flags so they can always be told apart.
    """
    pieces = []
    for station_id, group in wide.groupby("station_id"):
        hours = pd.date_range(group.ts.min(), group.ts.max(), freq="h")
        group = group.set_index("ts").reindex(hours)
        group.index.name = "ts"
        group["station_id"] = station_id
        flags = group.qc_flags.fillna(0).astype(int)
        for bit, column in enumerate(POLLUTANTS):
            series = group[column]
            filled = series.interpolate(limit=MAX_FILL_HOURS, limit_area="inside")
            # interpolate's limit fills the first hours of a long gap too;
            # keep only gaps that are MAX_FILL_HOURS long or shorter.
            gap_id = series.notna().cumsum()
            gap_length = series.isna().groupby(gap_id).transform("sum")
            filled = filled.where(series.notna() | (gap_length <= MAX_FILL_HOURS))
            was_filled = series.isna() & filled.notna()
            flags = flags | (was_filled.astype(int) * (1 << bit))
            group[column] = filled
        group["qc_flags"] = flags
        pieces.append(group.reset_index())
    result = pd.concat(pieces, ignore_index=True)
    # Drop hours where every pollutant is still empty.
    return result.dropna(subset=POLLUTANTS, how="all")
