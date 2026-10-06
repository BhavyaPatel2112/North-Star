"""Train the final models on all the data and save them as files.

One two-part model per pollutant, saved in Backend/models/ (committed to Git
so the hourly prediction job on GitHub can load them). They are retrained
regularly as new data arrives.
"""

from datetime import datetime, timezone
from pathlib import Path

import joblib
import pandas as pd

from northstar.model.calibration import IsotonicCalibrator
from northstar.model.dataset import TARGETS, feature_columns, target_is_real
from northstar.model.evaluate import grouped_station_cv
from northstar.model.two_part import TwoPartModel, split_columns

MODELS_DIR = Path(__file__).resolve().parent.parent.parent / "models"

# Whether each pollutant uses the place part (grouped station cross-validation,
# October 2026). For PM2.5 and PM10 it helps or is neutral. For ozone and
# nitrogen dioxide it ranked places backwards (27% and 38% right on which
# place is cleaner on average), likely because of the uncertain gas units in
# the 2025+ station feed, so those use the time part only.
USE_PLACE_PART = {"pm25": True, "pm10": True, "no2": False, "o3": False}

# Isotonic calibration (October 2026 test, cross-fitted by station group):
# for PM2.5 it cut "missed bad air" (real Moderate or worse, predicted Good or
# Satisfactory) from 69% to 50% with false alarms staying near 1%; for PM10
# from 32% to 24%. It did not help ozone or nitrogen dioxide, whose rare high
# hours the model cannot see coming.
CALIBRATE = {"pm25": True, "pm10": True, "no2": False, "o3": False}

# The app warns "may reach Moderate" from these corrected values (µg/m³).
# For PM2.5 a threshold of 45 caught 83% of bad-air hours while warning on
# 3.7% of clean hours (October 2026 test).
WARN_FROM = {"pm25": 45, "pm10": 85, "no2": 70, "o3": 85}


def train_all(training: pd.DataFrame, place_columns: list[str]) -> dict[str, dict]:
    """Train one model per pollutant; return a summary of each."""
    time_columns, place_columns = split_columns(feature_columns(training), place_columns)
    MODELS_DIR.mkdir(exist_ok=True)
    summary = {}
    for target in TARGETS:
        rows = training[target_is_real(training, target)].reset_index(drop=True)

        def make_model():
            return TwoPartModel(target, time_columns, place_columns, use_place_part=USE_PLACE_PART[target])

        model = make_model().fit(rows)
        calibrator = None
        if CALIBRATE[target]:
            # Learn the correction from honest predictions: each station group
            # predicted by a model that never saw it.
            honest = grouped_station_cv(rows, make_model).to_numpy()
            calibrator = IsotonicCalibrator().fit(honest, rows[target].to_numpy())
        bundle = {
            "model": model,
            "calibrator": calibrator,
            "trained_at": datetime.now(timezone.utc),
            "rows": len(rows),
            "stations": int(rows.station_id.nunique()),
            "data_until": rows.ts.max(),
        }
        joblib.dump(bundle, MODELS_DIR / f"{target}.joblib", compress=3)
        summary[target] = {k: v for k, v in bundle.items() if k not in ("model", "calibrator")}
        summary[target]["calibrated"] = calibrator is not None
    return summary


def load_models() -> dict[str, dict]:
    return {target: joblib.load(MODELS_DIR / f"{target}.joblib") for target in TARGETS}
