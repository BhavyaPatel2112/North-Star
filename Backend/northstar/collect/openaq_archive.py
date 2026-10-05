"""Download historical readings from the OpenAQ public archive.

OpenAQ stores its full history on Amazon S3 as one compressed CSV file per
station per day, at paths like:

    records/csv.gz/locationid=6956/year=2021/month=01/location-6956-20210101.csv.gz

The bucket is public, so no API key or rate limit applies. Files are saved
under data/raw/openaq/<location id>/ with the same file name. Files already
on disk are skipped, so an interrupted download can simply be run again.
"""

import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from pathlib import Path

import requests

from northstar import config

ARCHIVE_URL = "https://openaq-data-archive.s3.amazonaws.com/"
OPENAQ_RAW_DIR = config.RAW_DIR / "openaq"

# The date is the last 8 digits of the file name, e.g. location-6956-20210101.csv.gz
FILE_DATE = re.compile(r"-(\d{4})(\d{2})(\d{2})\.csv\.gz$")


def list_files(location_id: str, start: date) -> list[str]:
    """Return archive paths of all daily files for one location from `start` onward."""
    keys: list[str] = []
    params = {"list-type": "2", "prefix": f"records/csv.gz/locationid={location_id}/"}
    while True:
        # S3 returns at most 1000 names per request; follow the continuation token.
        response = requests.get(ARCHIVE_URL, params=params, timeout=60)
        response.raise_for_status()
        text = response.text
        keys += re.findall(r"<Key>([^<]+)</Key>", text)
        token = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", text)
        if not token:
            break
        params["continuation-token"] = token.group(1)

    def file_date(key: str) -> date | None:
        match = FILE_DATE.search(key)
        return date(*map(int, match.groups())) if match else None

    return [k for k in keys if (d := file_date(k)) is not None and d >= start]


def local_path(key: str, location_id: str) -> Path:
    return OPENAQ_RAW_DIR / location_id / key.rsplit("/", 1)[-1]


def download_file(key: str, destination: Path) -> int:
    """Download one file. Writes to a temporary name first so a crash never leaves a half file."""
    response = requests.get(ARCHIVE_URL + key, timeout=60)
    response.raise_for_status()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".part")
    temporary.write_bytes(response.content)
    temporary.rename(destination)
    return len(response.content)


def download_locations(location_ids: list[str], start: date, workers: int = 16) -> None:
    """Download every missing daily file for the given OpenAQ locations."""
    todo: list[tuple[str, Path]] = []
    for location_id in location_ids:
        keys = list_files(location_id, start)
        missing = [(k, local_path(k, location_id)) for k in keys]
        missing = [(k, p) for k, p in missing if not p.exists()]
        print(f"  location {location_id}: {len(keys)} files in archive, {len(missing)} to download")
        todo += missing

    print(f"Downloading {len(todo)} files with {workers} parallel workers...")
    done = failed = total_bytes = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(download_file, key, path): key for key, path in todo}
        for future in as_completed(futures):
            try:
                total_bytes += future.result()
                done += 1
            except Exception as error:
                failed += 1
                print(f"  FAILED {futures[future]}: {error}")
            if (done + failed) % 1000 == 0:
                print(f"  {done + failed}/{len(todo)} files, {total_bytes / 1e6:.0f} MB")

    print(f"Finished: {done} downloaded, {failed} failed, {total_bytes / 1e6:.0f} MB.")
    if failed:
        print("Run the script again to retry the failed files.")
