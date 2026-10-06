"""The curated station list (stations.csv) and how OpenAQ ids map onto it."""

from pathlib import Path

import pandas as pd

STATIONS_FILE = Path(__file__).resolve().parent / "stations.csv"


def load_stations() -> pd.DataFrame:
    return pd.read_csv(STATIONS_FILE, dtype={"openaq_location_ids": str})


def openaq_location_ids() -> list[str]:
    """Every OpenAQ location id in the list, as strings."""
    return [i.strip() for ids in load_stations().openaq_location_ids for i in ids.split(";")]


def location_priority() -> dict[int, tuple[int, int]]:
    """OpenAQ id -> (station_id, priority). The first id listed for a station wins."""
    mapping = {}
    for row in load_stations().itertuples():
        for priority, location_id in enumerate(row.openaq_location_ids.split(";")):
            mapping[int(location_id)] = (row.station_id, priority)
    return mapping
