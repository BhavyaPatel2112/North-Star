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

    # A station source being down is expected and only logged. A crash in
    # one of our own jobs is a real problem: exit with an error so the
    # scheduler marks the run as failed and sends an alert.
    if any(" FAILED: " in line for line in report):
        sys.exit(1)


if __name__ == "__main__":
    main()
