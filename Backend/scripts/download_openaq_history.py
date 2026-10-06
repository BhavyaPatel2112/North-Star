"""Download OpenAQ history for every station in stations.csv.

Run from the Backend folder (safe to re-run; it skips files already downloaded):
    .venv/bin/python -m scripts.download_openaq_history
"""

from datetime import date

from northstar.collect.openaq_archive import download_locations
from northstar.collect.stations import openaq_location_ids

START_DATE = date(2019, 6, 1)


def main() -> None:
    location_ids = openaq_location_ids()
    print(f"{len(location_ids)} OpenAQ locations, from {START_DATE}")
    download_locations(location_ids, START_DATE)


if __name__ == "__main__":
    main()
