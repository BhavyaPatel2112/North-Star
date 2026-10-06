"""Tests for the evaluation helpers."""

import numpy as np
import pandas as pd

from northstar.model.evaluate import band, idw_leave_one_out, scores


def test_band_boundaries_for_pm25():
    # 30 is still Good, 31 is Satisfactory; above 250 is Severe.
    assert list(band(np.array([10, 30, 31, 60, 61, 251]), "pm25")) == [0, 0, 1, 1, 2, 5]


def test_scores_perfect_and_biased():
    actual = np.array([10.0, 20.0, 30.0])
    perfect = scores(actual, actual, "pm25")
    assert perfect["mae"] == 0 and perfect["r2"] == 1 and perfect["band_exact"] == 1
    high = scores(actual, actual + 5, "pm25")
    assert high["bias"] == 5 and high["mae"] == 5


def test_idw_never_uses_the_station_itself_and_prefers_near_stations():
    ts = pd.Timestamp("2025-01-01", tz="UTC")
    frame = pd.DataFrame({"ts": ts, "station_id": [1, 2, 3], "pm25": [100.0, 10.0, 50.0]})
    # Station 1 at 0 m, station 2 at 1 km, station 3 at 3 km (all on a line).
    coords = pd.DataFrame({"x": [0.0, 1000.0, 3000.0], "y": [0.0, 0.0, 0.0]}, index=[1, 2, 3])
    estimate = idw_leave_one_out(frame, "pm25", coords)
    # Station 1 from stations 2 (weight 1/1000²) and 3 (weight 1/3000²): mostly station 2.
    expected = (10 / 1000**2 + 50 / 3000**2) / (1 / 1000**2 + 1 / 3000**2)
    assert np.isclose(estimate.iloc[0], expected)
    assert estimate.iloc[0] != 100.0
