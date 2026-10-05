"""Pollution model.

- Splits Mumbai into H3 hexagon cells (about 200 to 300 metres across).
- Baseline: inverse distance weighting between stations.
- Main model: LightGBM predicting pollution for every cell, now and for the
  next 6 to 24 hours.
- Evaluation: leave-one-station-out, reported as improvement over the baseline.
"""
