"""The two-part model: a time part and a place part.

Why two parts: we have hundreds of thousands of hours but only about 37
places. One big model given both can quietly memorise each station ("this
exact mix of roads and parks is usually 45") instead of learning rules that
work at a new place, which is what every map hexagon is.

Part A, time (LightGBM): how pollution rises and falls, from CAMS, weather,
    time of day, season and festivals. It never sees city-layout features,
    so it cannot memorise places. Plenty of data, so it can be flexible.

Part B, place (ridge regression): how much dirtier or cleaner a place is than
    Part A expects, from its roads, industry, greenery and coast. It learns
    from one number per station (its average leftover error), so it is kept
    deliberately simple: a straight-line formula whose strength is chosen
    automatically to avoid over-fitting the few stations.

Both work on log values, so a place 20% dirtier is 20% dirtier whether the
city is at 30 or at 150, and the final prediction is
    exp(Part A + Part B) - 1.

Recent hours can count more in training (`half_life_days`), so the model
keeps up when the air gets cleaner or dirtier from year to year.
"""

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.linear_model import RidgeCV
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

TIME_PARAMS = dict(
    n_estimators=500, learning_rate=0.05, num_leaves=63, min_child_samples=100,
    subsample=0.8, subsample_freq=1, colsample_bytree=0.8, verbose=-1, n_jobs=-1,
)

# Distances and road lengths matter most when small ("50 m vs 500 m from a
# highway" is a bigger difference than "5 km vs 5.5 km"), so they are log-scaled.
LOG_SCALED_PREFIXES = ("dist_", "major_road_m", "secondary_road_m", "minor_road_m")


def split_columns(columns: list[str], place_columns: list[str]) -> tuple[list[str], list[str]]:
    """Separate model inputs into time inputs (Part A) and place inputs (Part B)."""
    place = [c for c in columns if c in place_columns]
    time = [c for c in columns if c not in place_columns]
    return time, place


def recency_weights(ts: pd.Series, half_life_days: float | None) -> np.ndarray:
    """Weight 1 for the newest hour, halving every `half_life_days` going back."""
    if not half_life_days:
        return np.ones(len(ts))
    age_days = (ts.max() - ts).dt.total_seconds().to_numpy() / 86400
    return 0.5 ** (age_days / half_life_days)


def _place_matrix(frame: pd.DataFrame, place_columns: list[str]) -> pd.DataFrame:
    matrix = frame[place_columns].astype(float).copy()
    for column in place_columns:
        if column.startswith(LOG_SCALED_PREFIXES):
            matrix[column] = np.log1p(matrix[column])
    return matrix


class TwoPartModel:
    def __init__(self, target: str, time_columns: list[str], place_columns: list[str],
                 half_life_days: float | None = None, use_place_part: bool = True,
                 bias_correction: bool = False):
        self.target = target
        self.time_columns = time_columns
        self.place_columns = place_columns
        self.half_life_days = half_life_days
        self.use_place_part = use_place_part
        self.bias_correction = bias_correction

    def fit(self, frame: pd.DataFrame) -> "TwoPartModel":
        y = np.log1p(frame[self.target].clip(lower=0).to_numpy())
        weights = recency_weights(frame.ts, self.half_life_days)

        # Part A: time.
        self.time_model = lgb.LGBMRegressor(**TIME_PARAMS)
        self.time_model.fit(frame[self.time_columns], y, sample_weight=weights)

        # Part B: place. One number per station: how far above or below Part A it sits on average.
        if self.use_place_part:
            leftover = pd.Series(y - self.time_model.predict(frame[self.time_columns]), index=frame.index)
            stations = frame.assign(leftover=leftover, weight=weights).groupby("station_id").apply(
                lambda g: pd.Series({"offset": np.average(g.leftover, weights=g.weight), "hours": len(g)})
            )
            place = _place_matrix(frame.groupby("station_id")[self.place_columns].first(), self.place_columns)
            # RidgeCV tries many strengths and keeps the one that best predicts
            # each station when it is left out (built-in leave-one-out check).
            self.place_model = make_pipeline(StandardScaler(), RidgeCV(alphas=np.logspace(-1, 4, 30)))
            self.place_model.fit(place.loc[stations.index], stations.offset,
                                 ridgecv__sample_weight=np.sqrt(stations.hours))

        # Averaging in log units predicts the typical (median-like) value, which
        # sits below the average. The "smearing" factor (Duan, 1983) scales
        # predictions back up by the average size of the training errors.
        self.scale = 1.0
        if self.bias_correction:
            time_part, place_part = self.predict_parts(frame)
            self.scale = float(np.average(np.exp(y - time_part - place_part), weights=weights))
        return self

    def predict_parts(self, frame: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
        """Part A and Part B separately (in log units), useful for explaining predictions."""
        time_part = self.time_model.predict(frame[self.time_columns])
        if not self.use_place_part:
            return time_part, np.zeros(len(frame))
        place_part = self.place_model.predict(_place_matrix(frame, self.place_columns))
        return time_part, place_part

    def predict(self, frame: pd.DataFrame) -> np.ndarray:
        time_part, place_part = self.predict_parts(frame)
        return (np.exp(time_part + place_part) * self.scale - 1).clip(min=0)
