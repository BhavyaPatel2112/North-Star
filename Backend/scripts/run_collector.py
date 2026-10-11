"""Run the hourly collector once.

Run from the Backend folder:
    .venv/bin/python -m scripts.run_collector

In production GitHub Actions runs it every hour (.github/workflows/collector.yml).
"""

import sys
from datetime import datetime, timezone

from northstar.collect.collector import run_once
from northstar.db.connection import connect


def main() -> None:
    started = datetime.now(timezone.utc)
    print(f"Collector run at {started:%Y-%m-%d %H:%M} UTC")
    with connect() as conn:
        report = run_once(conn)
    for line in report:
        print("  " + line)
    seconds = (datetime.now(timezone.utc) - started).total_seconds()
    print(f"Done in {seconds:.0f} seconds")

    # An optional source being down (fires, stations, Google) is expected: show it as
    # a warning on the GitHub run and carry on. Only a failed essential job (CAMS or
    # weather, without which there is no forecast) fails the run and sends an alert.
    for line in report:
        if " SKIPPED: " in line:
            print(f"::warning title=Collector::{line}")
    if any(" FAILED: " in line for line in report):
        sys.exit(1)


if __name__ == "__main__":
    main()
