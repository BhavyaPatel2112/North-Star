"""Test calibration fairly, for each pollutant.

1. Honest test predictions: 8 station groups, each predicted by a model that
   never saw it (grouped station cross-validation).
2. Each group's predictions are calibrated with a curve learned only from
   the OTHER groups (cross-fitting), so no group is graded on data its
   correction learned from.
3. Scores include the two errors that matter most for health: missed bad
   air (real band Moderate or worse, predicted Good or Satisfactory) and
   false alarms (real Good, predicted Moderate or worse).

Run from the Backend folder:
    .venv/bin/python -m scripts.test_calibration pm25 pm10
"""

import json
import sys

import numpy as np
import pandas as pd

from northstar import config
from northstar.db.connection import connect
from northstar.model.calibration import IsotonicCalibrator, QuantileCalibrator
from northstar.model.dataset import TRAINING_FILE, feature_columns, target_is_real
from northstar.model.evaluate import band, grouped_station_cv, ordering_accuracy, scores
from northstar.model.train import USE_PLACE_PART
from northstar.model.two_part import TwoPartModel, split_columns
from sklearn.model_selection import GroupKFold

RESULTS_FILE = config.PROCESSED_DIR / "calibration_test.json"
MIN_DIFFERENCE = {"pm25": 10, "pm10": 20, "no2": 10, "o3": 10}
HIGH = {"pm25": 60, "pm10": 100, "no2": 80, "o3": 100}  # top of "Satisfactory" in India's index


def health_scores(actual, predicted, target):
    a, p = band(actual, target), band(predicted, target)
    bad = a >= 2
    return {
        "missed bad air": float(np.mean(p[bad] <= 1)) if bad.any() else float("nan"),
        "false alarms": float(np.mean(p[a == 0] >= 2)) if (a == 0).any() else float("nan"),
    }


def main(targets):
    data = pd.read_parquet(TRAINING_FILE)
    with connect() as conn:
        place = list(conn.execute("select features from station_features limit 1").fetchone()[0])
    time_cols, place_cols = split_columns(feature_columns(data), place)
    results = json.loads(RESULTS_FILE.read_text()) if RESULTS_FILE.exists() else {}

    for target in targets:
        f = data[target_is_real(data, target)].reset_index(drop=True)
        f["day"] = f.ts.dt.tz_convert("Asia/Kolkata").dt.date
        f["raw"] = grouped_station_cv(
            f, lambda: TwoPartModel(target, time_cols, place_cols, use_place_part=USE_PLACE_PART[target]))

        # Cross-fitted calibration: each group's correction is learned from the other groups.
        groups = np.zeros(len(f), dtype=int)
        for g, (_, test_idx) in enumerate(GroupKFold(n_splits=8).split(f, groups=f.station_id)):
            groups[test_idx] = g
        for calibrator in (IsotonicCalibrator, QuantileCalibrator):
            out = np.empty(len(f))
            for g in range(8):
                others = groups != g
                cal = calibrator().fit(f.raw[others].to_numpy(), f[target][others].to_numpy())
                out[groups == g] = cal.apply(f.raw[groups == g].to_numpy())
            f[calibrator.name] = out

        rows = {}
        actual = f[target].to_numpy()
        for name in ("raw", "isotonic", "quantile mapping"):
            pred = f[name].to_numpy()
            s = scores(actual, pred, target)
            high = actual > HIGH[target]
            in_2026 = (f.ts >= pd.Timestamp("2026-01-01", tz="UTC")).to_numpy()
            rows[name] = {
                "error": s["mae"], "bias": s["bias"], "right band": s["band_exact"],
                "within 1 band": s["band_within_one"],
                **health_scores(actual, pred, target),
                f"when real > {HIGH[target]}: predicted median": float(np.median(pred[high])),
                f"when real > {HIGH[target]}: real median": float(np.median(actual[high])),
                "best hour": ordering_accuracy(f, target, name, "ts", ["station_id", "day"], MIN_DIFFERENCE[target]),
                "2026 right band": scores(actual[in_2026], pred[in_2026], target)["band_exact"],
                "2026 missed bad air": health_scores(actual[in_2026], pred[in_2026], target)["missed bad air"],
            }
        results[target] = rows
        RESULTS_FILE.write_text(json.dumps(results, indent=1))
        print(f"\n{target}\n" + pd.DataFrame(rows).T.round(3).to_string(), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:] or ["pm25", "pm10"])
