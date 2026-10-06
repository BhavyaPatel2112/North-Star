"""Clean the downloaded OpenAQ history and save it locally for review.

Reads every file in data/raw/openaq, runs the cleaning steps in
northstar/clean/openaq.py, prints what each step removed, and writes
data/processed/air_readings_hourly.parquet. Nothing is sent to the database.

Run from the Backend folder:
    .venv/bin/python -m scripts.clean_openaq_history
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd

from northstar import config
from northstar.clean import openaq as clean
from northstar.collect.openaq_archive import OPENAQ_RAW_DIR
from northstar.collect.stations import STATIONS_FILE, location_priority

OUTPUT_FILE = config.PROCESSED_DIR / "air_readings_hourly.parquet"


def read_file(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, usecols=["location_id", "datetime", "parameter", "units", "value"])


def load_raw() -> pd.DataFrame:
    files = sorted(OPENAQ_RAW_DIR.glob("*/*.csv.gz"))
    with ThreadPoolExecutor(max_workers=8) as pool:
        raw = pd.concat(pool.map(read_file, files), ignore_index=True)
    raw["datetime"] = pd.to_datetime(raw.datetime, utc=True, format="ISO8601")
    print(f"Read {len(files):,} files")
    return raw


def main() -> None:
    raw = load_raw()
    print(f"\n{'Step':<44}{'rows left':>14}")

    def report(step: str, table: pd.DataFrame) -> None:
        print(f"{step:<44}{len(table):>14,}")

    report("raw readings (all parameters)", raw)
    df = clean.fix_units(raw)
    report("1. pollutants in µg/m³ (NOx dropped)", df)
    df = clean.remove_invalid(df)
    report("2. without negatives/error codes/extremes", df)
    df = clean.to_hourly(df)
    report("3. hourly values (location x pollutant)", df)
    df = clean.merge_duplicates(df, location_priority())
    report("4. after merging duplicate ids", df)
    df = clean.remove_stuck(df)
    report("5. after removing stuck sensors", df)
    wide = clean.to_wide(df)
    pm_before = wide[["pm25", "pm10"]].notna().sum().sum()
    wide = clean.remove_pm_mismatch(wide)
    pm_after = wide[["pm25", "pm10"]].notna().sum().sum()
    report("6. station-hours (PM2.5 > PM10 blanked)", wide)
    print(f"{'   PM values blanked by step 6':<44}{pm_before - pm_after:>14,}")
    wide = clean.fill_short_gaps(wide)
    report("7. station-hours after filling short gaps", wide)
    print(f"{'   station-hours with a filled value':<44}{(wide.qc_flags > 0).sum():>14,}")

    # Summary per station.
    names = pd.read_csv(STATIONS_FILE).set_index("station_id").name
    summary = wide.groupby("station_id").agg(
        first=("ts", "min"), last=("ts", "max"), hours=("ts", "size"),
        pm25=("pm25", "count"), no2=("no2", "count"), co_median=("co", "median"),
    )
    summary.insert(0, "name", names.reindex(summary.index).str[:30])
    summary["first"] = summary["first"].dt.strftime("%Y-%m")
    summary["last"] = summary["last"].dt.strftime("%Y-%m")
    print("\n" + summary.to_string())

    print("\nMedian µg/m³ by year (should be similar before and after the unit fix):")
    by_year = wide.groupby(wide.ts.dt.year)[["pm25", "pm10", "no2", "o3", "co", "so2"]].median()
    print(by_year.round(1).to_string())

    wide["source_id"] = 1  # OpenAQ
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    wide.to_parquet(OUTPUT_FILE, index=False)
    print(f"\nSaved {len(wide):,} station-hours to {OUTPUT_FILE.relative_to(config.BACKEND_DIR)}")


if __name__ == "__main__":
    main()
