"""Download fire detections from August 2022 to today and save them.

Run from the Backend folder (safe to re-run):
    .venv/bin/python -m scripts.download_fire_history
"""

from datetime import date

from northstar.collect import firms
from northstar.db.connection import connect

START = date(2022, 8, 1)  # same start as the CAMS history


def main() -> None:
    fires = firms.download(START, date.today())
    print(f"{len(fires):,} detections, {fires.detected_at.min()} to {fires.detected_at.max()}")
    with connect() as conn:
        firms.save(conn, fires)
        conn.commit()
        size = conn.execute("select pg_size_pretty(pg_total_relation_size('fires'))").fetchone()[0]
        by_month = conn.execute(
            "select to_char(detected_at, 'MM') as month, count(*) from fires group by 1 order by 1"
        ).fetchall()
    print(f"fires table: {size}")
    print("detections by month of year:", dict(by_month))


if __name__ == "__main__":
    main()
