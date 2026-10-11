"""Build the list of train and metro stations a one-way run can end at.

"End near a station" lets a runner finish at a station and ride home. The
stations come from OpenStreetMap: local train stations (Western, Central,
Harbour, Trans-Harbour and Uran lines) and metro stations inside the area
North Star covers. Left out: bus stations, the monorail, stations that are
only planned or being built, and the lists below (lines not yet running, and
stations with no local trains). Review the lists when a new line opens.

OpenStreetMap often records one station several times (a point for the
station, an outline of the building, one point per line at interchanges), so
entries of the same kind with the same name within 400 m become one station.

Run from the Backend folder (downloads from OpenStreetMap, under a minute):
    .venv/bin/python -m scripts.build_stations
The result, data/processed/stations.json, is committed so the server can load it.
"""

import json
import re

import osmnx as ox
import pandas as pd

from northstar import config
from northstar.routing.stations import STATIONS_FILE

TAGS = {"railway": ["station", "halt"], "public_transport": "station"}
MERGE_WITHIN_M = 400
NOT_RAIL = ("BEST", "NMMT", "MSRTC", "TMT", "MBMT", "KDMT")   # bus operators and networks

# Metro stations on lines not confirmed open (Oct 2026): Line 2B (Mandale to Diamond
# Garden and on to Chembur), Line 9 (Dahisar East to Kashigaon), and Navi Mumbai
# stations beyond Line 1. Lines 1, 2A, 3 (Aqua), 7 and Navi Mumbai Line 1 are kept.
METRO_NOT_RUNNING = {
    "Mandale", "Diamond Garden", "Shivaji Chowk (Chembur)", "Chembur", "Deonar", "Mankhurd",
    "RBI Colony", "Pandurang Wadi", "Miragaon", "Kashigaon", "Khandeshwar", "Mansarovar",
}
# Train stations a runner cannot ride home from: long-distance terminals (no local
# trains) and stations on the Diva to Vasai and Diva to Panvel lines (a few trains a day).
TRAIN_NOT_LOCAL = {
    "Bandra Terminus", "Lokmanya Tilak Terminus", "Bhivandi Road", "Kaman Road", "Kharbhav",
    "Nilaje", "Dativali", "Taloje Panchanand", "Targhar",
}


def mode_of(row: pd.Series) -> str | None:
    """"train", "metro", or None for anything that is not a rail station in use."""
    value = lambda key: str(row[key]) if key in row and pd.notna(row[key]) else ""
    station, railway = value("station"), value("railway")
    text = f"{value('network')} {value('operator')}"
    if value("construction") or value("proposed") or railway in ("proposed", "construction"):
        return None
    if station == "monorail":
        return None  # the monorail is left out
    if station in ("subway", "light_rail") or "Metro" in text or "MMRC" in text:
        return "metro"
    if railway in ("station", "halt") and not any(bus in text for bus in NOT_RAIL):
        return "train"
    return None


def clean_name(name: str) -> str:
    """Drop line codes and a trailing "Metro" ("Andheri L1" -> "Andheri"), since the
    app adds "metro station" itself."""
    name = re.sub(r"\s*\[Line [^\]]*\]", "", name.strip())   # "Dahisar (East) [Line 9]"
    name = re.sub(r"\s+L\d+$", "", name)
    return re.sub(r"[\s-]+Metro$", "", name).strip()


def main() -> None:
    south, west, north, east = config.MUMBAI_BBOX
    found = ox.features_from_bbox((west, south, east, north), TAGS)
    found = found[found["name"].notna()].copy()
    for column in ("station", "railway", "network", "operator", "construction", "proposed", "name:en"):
        if column not in found:
            found[column] = None
    found["mode"] = found.apply(mode_of, axis=1)
    found = found[found["mode"].notna()]
    centres = found.geometry.to_crs(32643).centroid          # UTM zone 43N, metres
    found["x"], found["y"] = centres.x, centres.y
    points = centres.to_crs(4326)
    found["lat"], found["lon"] = points.y, points.x

    stations: list[dict] = []
    for _, row in found.sort_values("name").iterrows():
        name = clean_name(str(row["name:en"] if pd.notna(row["name:en"]) else row["name"]))
        if "bus" in name.lower():
            continue  # a bus stop tagged with a metro operator
        if (row["mode"] == "metro" and name in METRO_NOT_RUNNING) or (row["mode"] == "train" and name in TRAIN_NOT_LOCAL):
            continue
        for station in stations:
            if (station["mode"] == row["mode"] and station["name"].lower() == name.lower()
                    and (station["x"] - row["x"]) ** 2 + (station["y"] - row["y"]) ** 2 <= MERGE_WITHIN_M ** 2):
                break
        else:
            stations.append({"name": name, "mode": row["mode"], "lat": round(float(row["lat"]), 6),
                             "lon": round(float(row["lon"]), 6), "x": row["x"], "y": row["y"]})

    for station in stations:
        del station["x"], station["y"]
    STATIONS_FILE.write_text(json.dumps(stations, indent=1, ensure_ascii=False) + "\n")
    counts = pd.Series([s["mode"] for s in stations]).value_counts().to_dict()
    print(f"saved {len(stations)} stations to {STATIONS_FILE.name}: {counts}")


if __name__ == "__main__":
    main()
