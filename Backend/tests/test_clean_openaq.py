"""Tests for each cleaning step, using tiny hand-made tables."""

import numpy as np
import pandas as pd

from northstar.clean import openaq as clean


def raw(rows):
    """Build a raw table from (parameter, units, value) tuples."""
    return pd.DataFrame(rows, columns=["parameter", "units", "value"])


def test_fix_units_converts_mislabelled_co_and_drops_nox():
    df = clean.fix_units(raw([
        ("co", "ppb", 0.42),       # really mg/m³
        ("no2", "ppb", 15.0),      # really µg/m³
        ("nox", "ppb", 0.01),      # unusable
        ("co", "µg/m³", 600.0),    # older feed, already fine
        ("temperature", "c", 30),  # not a pollutant
    ]))
    assert sorted(zip(df.parameter, df.value)) == [("co", 420.0), ("co", 600.0), ("no2", 15.0)]


def test_remove_invalid():
    df = clean.remove_invalid(raw([
        ("pm25", "µg/m³", -3.0),     # negative
        ("pm25", "µg/m³", 985.0),    # error code
        ("pm10", "µg/m³", 99999.0),  # error code
        ("o3", "µg/m³", 5379.0),     # impossible
        ("co", "µg/m³", 1000.0),     # 1 mg/m³: normal for carbon monoxide
        ("pm25", "µg/m³", 45.0),     # fine
    ]).drop(columns="units"))
    assert sorted(df.value) == [45.0, 1000.0]


def test_to_hourly_uses_utc_hours_and_needs_two_readings():
    times = pd.to_datetime([
        "2021-01-01T03:15Z", "2021-01-01T03:30Z",
        "2021-01-01T03:45Z", "2021-01-01T04:00Z",  # four readings for the 03:00 UTC hour
        "2021-01-01T04:15Z",                       # lone reading for 04:00 UTC
    ], utc=True)
    df = pd.DataFrame({"location_id": 1, "parameter": "pm25", "datetime": times,
                       "value": [10.0, 20.0, 30.0, 40.0, 99.0]})
    hourly = clean.to_hourly(df)
    assert len(hourly) == 1
    assert hourly.ts.iloc[0] == pd.Timestamp("2021-01-01T03:00Z")
    assert hourly.value.iloc[0] == 25.0


def test_merge_duplicates_prefers_main_feed():
    ts = pd.Timestamp("2021-06-01T00:00Z")
    hourly = pd.DataFrame({
        "location_id": [6959, 60661, 60661],
        "parameter": ["pm25", "pm25", "pm10"],
        "ts": [ts, ts, ts],
        "value": [30.0, 35.0, 80.0],
    })
    merged = clean.merge_duplicates(hourly, {6959: (2, 0), 60661: (2, 1)})
    values = dict(zip(merged.parameter, merged.value))
    assert values == {"pm25": 30.0, "pm10": 80.0}  # main feed wins; duplicate fills pm10


def test_remove_stuck_drops_six_identical_hours():
    ts = pd.date_range("2021-01-01", periods=10, freq="h", tz="UTC")
    values = [5, 5, 5, 5, 5, 5, 7, 8, 9, 9]
    df = pd.DataFrame({"station_id": 1, "parameter": "so2", "ts": ts, "value": values})
    kept = clean.remove_stuck(df)
    assert list(kept.value) == [7, 8, 9, 9]


def test_pm_mismatch_blanks_both():
    wide = pd.DataFrame({"pm25": [50.0, 90.0], "pm10": [100.0, 60.0]})
    result = clean.remove_pm_mismatch(wide)
    assert result.pm25.iloc[0] == 50.0
    assert np.isnan(result.pm25.iloc[1]) and np.isnan(result.pm10.iloc[1])


def test_fill_short_gaps_only_fills_up_to_two_hours():
    ts = pd.date_range("2021-01-01", periods=9, freq="h", tz="UTC")
    pm25 = [10.0, np.nan, 30.0, 40.0, np.nan, np.nan, np.nan, 80.0, 90.0]
    wide = pd.DataFrame({"station_id": 1, "ts": ts, "pm25": pm25})
    for column in clean.POLLUTANTS[1:]:
        wide[column] = np.nan
    wide["qc_flags"] = 0
    filled = clean.fill_short_gaps(wide).set_index("ts")
    assert filled.loc[ts[1], "pm25"] == 20.0           # 1-hour gap filled
    assert filled.loc[ts[1], "qc_flags"] == 1          # pm25 is bit 0
    assert ts[4] not in filled.index                   # 3-hour gap left empty
    assert filled.loc[ts[3], "qc_flags"] == 0          # real reading not flagged
