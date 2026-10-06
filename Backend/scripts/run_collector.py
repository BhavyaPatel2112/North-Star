"""Run the hourly collector once.

Run from the Backend folder:
    .venv/bin/python -m scripts.run_collector

In production this runs every hour on a schedule (set up in the server step).
"""

from datetime import datetime, timezone

from northstar.collect.collector import run_once
from northstar.db.connection import connect


def main() -> None:
    started = datetime.now(timezone.utc)
    print(f"Collector run at {started:%Y-%m-%d %H:%M} UTC")
    with connect() as conn:
        for line in run_once(conn):
            print("  " + line)
    seconds = (datetime.now(timezone.utc) - started).total_seconds()
    print(f"Done in {seconds:.0f} seconds")


if __name__ == "__main__":
    main()
