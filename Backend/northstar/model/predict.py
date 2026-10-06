"""Predict every hexagon for the coming hours and save the results.

Runs every hour after the collector: builds the inputs for all 8,445
hexagons from the latest CAMS and weather forecasts, runs the four
pollutant models, and replaces the grid_predictions table in one step
(inside a transaction, so the app never sees a half-written table).
"""

import h3
import numpy as np
import pandas as pd
import psycopg

from northstar.model.dataset import TARGETS, load_grid_rows
from northstar.model.train import load_models

HOURS_BEFORE = 1   # keep the previous hour too, for the app's "last hour" view
HOURS_AHEAD = 36   # enough for "best time tomorrow" even late in the evening


def predict_grid(conn: psycopg.Connection) -> str:
    now = pd.Timestamp.now(tz="UTC").floor("h")
    start, end = now - pd.Timedelta(hours=HOURS_BEFORE), now + pd.Timedelta(hours=HOURS_AHEAD)
    rows = load_grid_rows(conn, start, end)
    if rows.empty:
        return "Predictions: no CAMS or weather data for the coming hours"

    models = load_models()
    result = pd.DataFrame({
        "h3": [h3.str_to_int(cell) for cell in rows.h3_index],
        "ts": rows.ts,
    })
    for target in TARGETS:
        values = models[target]["model"].predict(rows)
        if models[target].get("calibrator") is not None:
            values = models[target]["calibrator"].apply(values)
        result[target] = np.clip(np.round(values), 0, 32767).astype("int16")

    with conn.transaction():
        conn.execute("truncate grid_predictions")
        with conn.cursor().copy("copy grid_predictions (h3, ts, pm25, pm10, no2, o3) from stdin") as copy:
            for row in result.itertuples(index=False):
                copy.write_row(row)
        station_data_at = conn.execute("select max(ts) from air_readings_hourly").fetchone()[0]
        conn.execute(
            "insert into prediction_runs (hours_from, hours_to, rows_written, models_trained, station_data_at) "
            "values (%s, %s, %s, %s, %s)",
            (result.ts.min(), result.ts.max(), len(result), models["pm25"]["trained_at"], station_data_at),
        )
        conn.execute("delete from prediction_runs where run_at < now() - interval '90 days'")
    return (f"Predictions: {len(result):,} hexagon-hours "
            f"({result.ts.min():%d %b %H:%M} to {result.ts.max():%d %b %H:%M} UTC)")
