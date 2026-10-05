"""Load the cleaned pollution history into the database.

Reads data/processed/air_readings_hourly.parquet (made by
scripts.clean_openaq_history) and upserts it into air_readings_hourly.
Safe to re-run.

Run from the Backend folder:
    .venv/bin/python -m scripts.load_air_readings
"""

import pandas as pd

from northstar import config
from northstar.db.air_readings import refresh_station_dates, upsert_air_readings
from northstar.db.connection import connect

INPUT_FILE = config.PROCESSED_DIR / "air_readings_hourly.parquet"
BATCH_ROWS = 50_000


def main() -> None:
    frame = pd.read_parquet(INPUT_FILE)
    print(f"Loading {len(frame):,} station-hours from {INPUT_FILE.name}")

    with connect() as conn:
        # Commit in batches so an interruption keeps the batches already sent.
        for start in range(0, len(frame), BATCH_ROWS):
            upsert_air_readings(conn, frame.iloc[start:start + BATCH_ROWS])
            conn.commit()
            print(f"  {min(start + BATCH_ROWS, len(frame)):,} / {len(frame):,}")

        refresh_station_dates(conn)
        conn.commit()

        rows = conn.execute("select count(*) from air_readings_hourly").fetchone()[0]
        size = conn.execute("select pg_size_pretty(pg_total_relation_size('air_readings_hourly'))").fetchone()[0]
        total = conn.execute("select pg_size_pretty(pg_database_size(current_database()))").fetchone()[0]
        print(f"air_readings_hourly: {rows:,} rows, {size}. Whole database: {total} of 500 MB.")


if __name__ == "__main__":
    main()
