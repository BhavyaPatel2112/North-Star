"""Compare raw CAMS, inverse distance weighting and LightGBM with
leave-one-station-out evaluation, for each pollutant.

Run from the Backend folder (takes a while: 38 models per pollutant):
    .venv/bin/python -m scripts.evaluate_models [pm25 no2 ...]
"""

import json
import sys

import geopandas as gpd
import pandas as pd
from shapely.geometry import Point

from northstar import config
from northstar.db.connection import connect
from northstar.model.dataset import TARGETS, TRAINING_FILE, feature_columns, target_is_real
from northstar.model.evaluate import idw_leave_one_out, lightgbm_leave_one_out, scores
from northstar.model.features import METRIC_CRS

RESULTS_FILE = config.PROCESSED_DIR / "evaluation.json"
SPLIT = pd.Timestamp("2026-01-01", tz="UTC")


def station_coordinates() -> pd.DataFrame:
    with connect() as conn:
        rows = conn.execute(
            "select station_id, ST_X(location::geometry), ST_Y(location::geometry) from stations"
        ).fetchall()
    points = gpd.GeoSeries([Point(lon, lat) for _, lon, lat in rows], crs=4326).to_crs(METRIC_CRS)
    return pd.DataFrame({"x": points.x.values, "y": points.y.values}, index=[r[0] for r in rows])


def main(targets: list[str]) -> None:
    data = pd.read_parquet(TRAINING_FILE)
    features = feature_columns(data)
    coords = station_coordinates()
    results = json.loads(RESULTS_FILE.read_text()) if RESULTS_FILE.exists() else {}

    for target in targets:
        frame = data[target_is_real(data, target)].copy()
        print(f"\n=== {target}: {len(frame):,} real station-hours, {frame.station_id.nunique()} stations ===")
        frame["cams"] = frame[f"cams_{target}"]
        frame["idw"] = idw_leave_one_out(frame, target, coords)
        frame["lgbm"] = lightgbm_leave_one_out(frame, target, features)
        frame["lgbm_future"] = lightgbm_leave_one_out(frame, target, features, train_before=SPLIT, test_from=SPLIT)

        actual = frame[target].to_numpy()
        result = {
            "all hours": {name: scores(actual, frame[name].to_numpy(), target) for name in ("cams", "idw", "lgbm")},
        }
        future = frame.ts >= SPLIT
        result["2026, trained on earlier data"] = {
            name: scores(actual[future], frame.loc[future, name].to_numpy(), target)
            for name in ("cams", "idw", "lgbm_future")
        }
        per_station = frame.groupby("station_id").apply(
            lambda g: pd.Series({m: scores(g[target].to_numpy(), g[m].to_numpy(), target)["mae"]
                                 for m in ("cams", "idw", "lgbm")})
        )
        result["mae per station"] = per_station.round(1).to_dict(orient="index")
        results[target] = result
        RESULTS_FILE.write_text(json.dumps(results, indent=1, default=str))

        for period in ("all hours", "2026, trained on earlier data"):
            table = pd.DataFrame(result[period]).T[["hours", "mae", "rmse", "bias", "r2", "band_exact", "band_within_one"]]
            print(f"\n{period}:\n{table.round(3).to_string()}")


if __name__ == "__main__":
    main(sys.argv[1:] or TARGETS)
