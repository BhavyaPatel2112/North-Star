"""Compare model versions quickly with grouped station cross-validation.

Each version is scored on: typical error, right band, picking the cleaner
of two hours at a place ("best time"), and picking the cleaner of two places
at the same hour ("cleaner area or route"). Two settings: all hours, and
2026 predicted by models trained only on earlier data.

Run from the Backend folder:
    .venv/bin/python -m scripts.experiment pm25
"""

import json
import sys

import pandas as pd

from northstar import config
from northstar.db.connection import connect
from northstar.model.dataset import TRAINING_FILE, feature_columns, target_is_real
from northstar.model.evaluate import LGB_PARAMS, grouped_station_cv, ordering_accuracy, place_average_accuracy, scores
from northstar.model.two_part import TwoPartModel, split_columns

SPLIT = pd.Timestamp("2026-01-01", tz="UTC")
MIN_DIFFERENCE = {"pm25": 10, "pm10": 20, "no2": 10, "o3": 10}
RESULTS_FILE = config.PROCESSED_DIR / "experiments.json"


class OneModel:
    """The first version: one LightGBM given every input (for comparison)."""

    def __init__(self, target, columns):
        self.target, self.columns = target, columns

    def fit(self, frame):
        import lightgbm as lgb
        self.model = lgb.LGBMRegressor(**LGB_PARAMS).fit(frame[self.columns], frame[self.target])
        return self

    def predict(self, frame):
        return self.model.predict(frame[self.columns])


class Cams:
    """Raw CAMS, no correction."""

    def __init__(self, target):
        self.target = target

    def fit(self, frame):
        return self

    def predict(self, frame):
        return frame[f"cams_{self.target}"].to_numpy()


def main(target: str) -> None:
    data = pd.read_parquet(TRAINING_FILE)
    frame = data[target_is_real(data, target)].reset_index(drop=True)
    frame["day"] = frame.ts.dt.tz_convert("Asia/Kolkata").dt.date
    with connect() as conn:
        place_columns = list(conn.execute("select features from station_features limit 1").fetchone()[0])
    columns = feature_columns(data)
    time_columns, place_columns = split_columns(columns, place_columns)

    no_fires = [c for c in time_columns if not c.startswith("fire_")]
    versions = {
        "raw CAMS": lambda: Cams(target),
        "one model (first version)": lambda: OneModel(target, [c for c in columns if not c.startswith("fire_")]),
        "two-part": lambda: TwoPartModel(target, no_fires, place_columns),
        "two-part + fires": lambda: TwoPartModel(target, time_columns, place_columns),
    }
    if len(sys.argv) > 2:  # only the named versions, e.g. "two-part"
        versions = {k: v for k, v in versions.items() if k in sys.argv[2:]}
    results = {}
    for name, make_model in versions.items():
        row = {}
        for period, before in (("all", None), ("2026", SPLIT)):
            frame["pred"] = grouped_station_cv(frame, make_model, train_before=before)
            part = frame[frame.pred.notna()]
            s = scores(part[target].to_numpy(), part.pred.to_numpy(), target)
            row[f"{period} mae"] = s["mae"]
            row[f"{period} bias"] = s["bias"]
            row[f"{period} band"] = s["band_exact"]
            row[f"{period} best hour"] = ordering_accuracy(part, target, "pred", "ts", ["station_id", "day"], MIN_DIFFERENCE[target])
            row[f"{period} cleaner place"] = ordering_accuracy(part, target, "pred", "station_id", ["ts"], MIN_DIFFERENCE[target])
            row[f"{period} cleaner place on average"] = place_average_accuracy(part, target, "pred", MIN_DIFFERENCE[target] / 2)
        results[name] = row
        print(f"done: {name}", flush=True)

    table = pd.DataFrame(results).T
    print(f"\n{target} (grouped station cross-validation, 8 groups)\n" + table.round(3).to_string())
    saved = json.loads(RESULTS_FILE.read_text()) if RESULTS_FILE.exists() else {}
    saved[target] = results
    RESULTS_FILE.write_text(json.dumps(saved, indent=1))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "pm25")
