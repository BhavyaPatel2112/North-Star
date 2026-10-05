"""Download OpenAQ history for every station in stations.csv.

Run from the Backend folder (safe to re-run; it skips files already downloaded):
    .venv/bin/python -m scripts.download_openaq_history
"""

from datetime import date
from pathlib import Path

import pandas as pd

from northstar.collect.openaq_archive import download_locations

STATIONS_FILE = Path(__file__).resolve().parent.parent / "northstar" / "collect" / "stations.csv"
START_DATE = date(2019, 6, 1)


def main() -> None:
    stations = pd.read_csv(STATIONS_FILE, dtype={"openaq_location_ids": str})
    location_ids = [i.strip() for ids in stations.openaq_location_ids for i in ids.split(";")]
    print(f"{len(stations)} stations, {len(location_ids)} OpenAQ locations, from {START_DATE}")
    download_locations(location_ids, START_DATE)


if __name__ == "__main__":
    main()
