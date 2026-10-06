"""Train the final models on all the data and save them as files.

One two-part model per pollutant, saved in Backend/models/ (committed to Git
so the hourly prediction job on GitHub can load them). They are retrained
regularly as new data arrives.
"""

from datetime import datetime, timezone
from pathlib import Path

import joblib
import pandas as pd

from northstar.model.dataset import TARGETS, feature_columns, target_is_real
from northstar.model.two_part import TwoPartModel, split_columns

MODELS_DIR = Path(__file__).resolve().parent.parent.parent / "models"

# Whether each pollutant uses the place part (grouped station cross-validation,
# October 2026). For PM2.5 and PM10 it helps or is neutral. For ozone and
# nitrogen dioxide it ranked places backwards (27% and 38% right on which
# place is cleaner on average), likely because of the uncertain gas units in
# the 2025+ station feed, so those use the time part only.
USE_PLACE_PART = {"pm25": True, "pm10": True, "no2": False, "o3": False}


def train_all(training: pd.DataFrame, place_columns: list[str]) -> dict[str, dict]:
    """Train one model per pollutant; return a summary of each."""
    time_columns, place_columns = split_columns(feature_columns(training), place_columns)
    MODELS_DIR.mkdir(exist_ok=True)
    summary = {}
    for target in TARGETS:
        rows = training[target_is_real(training, target)]
        model = TwoPartModel(target, time_columns, place_columns,
                             use_place_part=USE_PLACE_PART[target]).fit(rows)
        bundle = {
            "model": model,
            "trained_at": datetime.now(timezone.utc),
            "rows": len(rows),
            "stations": int(rows.station_id.nunique()),
            "data_until": rows.ts.max(),
        }
        joblib.dump(bundle, MODELS_DIR / f"{target}.joblib", compress=3)
        summary[target] = {k: v for k, v in bundle.items() if k != "model"}
    return summary


def load_models() -> dict[str, dict]:
    return {target: joblib.load(MODELS_DIR / f"{target}.joblib") for target in TARGETS}
