"""Calibration: correcting the model's habit of predicting too low on bad days.

The model is trained in log units and pulled towards typical values, so when
real pollution is high it predicts too low (for PM2.5, real values above 60
were predicted around 53 when they were really around 76). A calibrator
learns, from the model's own honest test predictions, what real value each
prediction usually corresponds to, and applies that as a final step.

Two methods are compared:
- isotonic: the average real value for each predicted value, forced to only
  go up (a higher prediction never maps to a lower one)
- quantile mapping: stretches predictions so their spread matches the spread
  of real values (the 90th percentile of predictions maps to the 90th
  percentile of reality, and so on)
"""

import numpy as np
from sklearn.isotonic import IsotonicRegression


class IsotonicCalibrator:
    name = "isotonic"

    def fit(self, predicted: np.ndarray, actual: np.ndarray) -> "IsotonicCalibrator":
        self.model = IsotonicRegression(out_of_bounds="clip", increasing=True).fit(predicted, actual)
        return self

    def apply(self, predicted: np.ndarray) -> np.ndarray:
        return self.model.predict(predicted)


class QuantileCalibrator:
    name = "quantile mapping"
    LEVELS = np.linspace(0, 1, 201)

    def fit(self, predicted: np.ndarray, actual: np.ndarray) -> "QuantileCalibrator":
        self.from_q = np.quantile(predicted, self.LEVELS)
        self.to_q = np.quantile(actual, self.LEVELS)
        return self

    def apply(self, predicted: np.ndarray) -> np.ndarray:
        return np.interp(predicted, self.from_q, self.to_q)
