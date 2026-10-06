"""Leave-one-station-out evaluation.

For each station in turn: hide it completely, build predictions for it from
everything else, and compare with what it really measured. Because the
hidden station's readings are never used, this shows how well we predict a
place with no monitor, which is what every hexagon on the map is.
"""

import lightgbm as lgb
import numpy as np
import pandas as pd

# India's National Air Quality Index bands (µg/m³). Officially they use 24-hour
# (8-hour for ozone) averages; applied to hourly values here as an approximation.
NAQI_BANDS = {
    "pm25": [30, 60, 90, 120, 250],
    "pm10": [50, 100, 250, 350, 430],
    "no2": [40, 80, 180, 280, 400],
    "o3": [50, 100, 168, 208, 748],
}
BAND_NAMES = ["Good", "Satisfactory", "Moderate", "Poor", "Very poor", "Severe"]

LGB_PARAMS = dict(
    n_estimators=400, learning_rate=0.05, num_leaves=63, min_child_samples=50,
    subsample=0.8, subsample_freq=1, colsample_bytree=0.8, verbose=-1, n_jobs=-1,
)


def band(values: np.ndarray, target: str) -> np.ndarray:
    """National Air Quality Index band number (0 = Good ... 5 = Severe)."""
    return np.digitize(values, NAQI_BANDS[target], right=True)


def scores(actual: np.ndarray, predicted: np.ndarray, target: str) -> dict:
    """How close the predictions are, in several ways."""
    ok = ~np.isnan(actual) & ~np.isnan(predicted)
    a, p = actual[ok], predicted[ok]
    error = p - a
    band_a, band_p = band(a, target), band(p, target)
    return {
        "hours": int(ok.sum()),
        "mae": float(np.mean(np.abs(error))),             # typical size of the error
        "rmse": float(np.sqrt(np.mean(error ** 2))),      # punishes big misses more
        "bias": float(np.mean(error)),                    # above 0 = predicts too high on average
        "r2": float(1 - np.sum(error ** 2) / np.sum((a - a.mean()) ** 2)),  # 1 = perfect, 0 = no better than the average
        "band_exact": float(np.mean(band_a == band_p)),   # right air quality band
        "band_within_one": float(np.mean(np.abs(band_a - band_p) <= 1)),
    }


def idw_leave_one_out(frame: pd.DataFrame, target: str, coords: pd.DataFrame, power: float = 2) -> pd.Series:
    """Inverse distance weighting: estimate each station from the OTHER stations
    reporting in the same hour, nearer stations counting more (weight 1/distance²)."""
    table = frame.pivot_table(index="ts", columns="station_id", values=target)
    ids = table.columns.to_numpy()
    xy = coords.loc[ids, ["x", "y"]].to_numpy()
    distance = np.sqrt(((xy[:, None, :] - xy[None, :, :]) ** 2).sum(-1))
    with np.errstate(divide="ignore"):
        weights = 1 / distance ** power
    np.fill_diagonal(weights, 0)  # a station never helps estimate itself

    values = table.to_numpy()
    present = ~np.isnan(values)
    filled = np.where(present, values, 0)
    estimate = (filled @ weights.T) / (present.astype(float) @ weights.T)  # hours x stations
    result = pd.DataFrame(estimate, index=table.index, columns=ids).stack().rename("idw")
    return frame.join(result, on=["ts", "station_id"])["idw"]


def lightgbm_leave_one_out(frame: pd.DataFrame, target: str, features: list[str],
                           train_before: pd.Timestamp | None = None,
                           test_from: pd.Timestamp | None = None) -> pd.Series:
    """Train on all other stations, predict the hidden one; repeat for every station.

    With train_before/test_from set, training uses only earlier hours and
    predictions are made only for later hours: an unseen place AND an unseen time.
    """
    predictions = pd.Series(np.nan, index=frame.index)
    for station in sorted(frame.station_id.unique()):
        train = frame[frame.station_id != station]
        test = frame[frame.station_id == station]
        if train_before is not None:
            train = train[train.ts < train_before]
            test = test[test.ts >= test_from]
        if test.empty:
            continue
        model = lgb.LGBMRegressor(**LGB_PARAMS)
        model.fit(train[features], train[target])
        predictions.loc[test.index] = model.predict(test[features])
    return predictions
