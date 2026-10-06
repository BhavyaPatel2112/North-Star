"""Leave-one-station-out evaluation.

For each station in turn: hide it completely, build predictions for it from
everything else, and compare with what it really measured. Because the
hidden station's readings are never used, this shows how well we predict a
place with no monitor, which is what every hexagon on the map is.
"""

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.model_selection import GroupKFold

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


def grouped_station_cv(frame: pd.DataFrame, make_model, n_groups: int = 8,
                       train_before: pd.Timestamp | None = None) -> pd.Series:
    """Faster version of leave-one-station-out for experiments.

    Stations are split into `n_groups` groups; each group is hidden in turn
    and predicted by a model trained on the other groups. Every station is
    still predicted by a model that never saw it. `make_model()` must return
    an object with fit(frame) and predict(frame). With `train_before`, models
    train on earlier hours only and predict later hours only.
    """
    predictions = pd.Series(np.nan, index=frame.index)
    folds = GroupKFold(n_splits=n_groups)
    for train_idx, test_idx in folds.split(frame, groups=frame.station_id):
        train, test = frame.iloc[train_idx], frame.iloc[test_idx]
        if train_before is not None:
            train, test = train[train.ts < train_before], test[test.ts >= train_before]
        if test.empty:
            continue
        model = make_model().fit(train)
        predictions.loc[test.index] = model.predict(test)
    return predictions


def ordering_accuracy(frame: pd.DataFrame, target: str, predicted: str, by: str, within: list[str],
                      min_difference: float, max_pairs: int = 200_000, max_groups: int = 4000,
                      seed: int = 0) -> float:
    """How often the prediction picks the cleaner of two options.

    by="ts" with within=["station_id", "day"]: two hours at the same place on the
    same day ("best time to go out"). by="station_id" with within=["ts"]: two
    places at the same hour ("cleaner area or route"). Only pairs whose real
    values differ by at least `min_difference` count, since tiny differences
    don't matter to a person deciding.
    """
    rng = np.random.default_rng(seed)
    data = frame[within + [by, target, predicted]].dropna()
    # Use a random sample of groups (days or hours) so the pair table stays small.
    groups = data[within].drop_duplicates()
    if len(groups) > max_groups:
        groups = groups.iloc[rng.choice(len(groups), max_groups, replace=False)]
        data = data.merge(groups, on=within)
    pairs = data.merge(data, on=within, suffixes=("_a", "_b"))
    pairs = pairs[pairs[f"{by}_a"] < pairs[f"{by}_b"]]
    pairs = pairs[(pairs[f"{target}_a"] - pairs[f"{target}_b"]).abs() >= min_difference]
    if len(pairs) > max_pairs:
        pairs = pairs.iloc[rng.choice(len(pairs), max_pairs, replace=False)]
    real = np.sign(pairs[f"{target}_a"] - pairs[f"{target}_b"])
    guess = np.sign(pairs[f"{predicted}_a"] - pairs[f"{predicted}_b"])
    # A tie (the prediction cannot tell them apart) counts as half right, like a coin flip.
    return float(((real == guess) + 0.5 * (guess == 0)).mean())


def place_average_accuracy(frame: pd.DataFrame, target: str, predicted: str, min_difference: float) -> float:
    """How often the prediction picks which of two stations is cleaner ON AVERAGE.

    Averages each station over the hours both were measured, which removes
    hour-to-hour noise; closer to "is this area usually cleaner?".
    """
    table = frame.pivot_table(index="ts", columns="station_id", values=[target, predicted])
    stations = table[target].columns
    right, total = 0.0, 0
    for i, a in enumerate(stations):
        for b in stations[i + 1:]:
            both = table[target][a].notna() & table[target][b].notna() & table[predicted][a].notna()
            if both.sum() < 24 * 30:  # need at least a month in common
                continue
            real = table[target][a][both].mean() - table[target][b][both].mean()
            if abs(real) < min_difference:
                continue
            guess = table[predicted][a][both].mean() - table[predicted][b][both].mean()
            right += 1.0 if np.sign(real) == np.sign(guess) else (0.5 if guess == 0 else 0.0)
            total += 1
    return right / total if total else float("nan")
