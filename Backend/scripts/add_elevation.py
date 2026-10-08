"""Add the height of every street junction to the street network (run once).

Runners care about hills, so each planned route comes with an elevation
profile. Rather than asking an elevation service on every route request, we
look up all ~67,000 junctions once and store the heights in
data/processed/street_network.npz, which the route server already loads.

Source: OpenTopoData's free public service (no key), dataset "srtm30m": NASA's
Shuttle Radar Topography Mission terrain at about 30 m. Mumbai checks: Malabar
Hill 58 m, Powai 42 m, Shivaji Park 11 m, Marine Drive 8 m. 100 points per
request, about 680 requests at one a second (its limit; 1,000 a day), so about
12 minutes. (Open-Meteo's elevation service gave similar heights but its hourly
limit stopped a full run.)

Run from the Backend folder:
    .venv/bin/python -m scripts.add_elevation
"""

import time

import numpy as np
import requests

from northstar import config
from northstar.routing.network import StreetNetwork

# Progress so far, so a stopped run carries on where it left off (not committed).
PARTIAL = config.PROCESSED_DIR / "node_elev_partial.npy"

URL = "https://api.opentopodata.org/v1/srtm30m"
BATCH = 100
PAUSE_S = 1.1


def fetch(lats: np.ndarray, lons: np.ndarray) -> list[float]:
    params = {"locations": "|".join(f"{a:.5f},{o:.5f}" for a, o in zip(lats, lons))}
    for attempt in range(8):
        try:
            response = requests.get(URL, params=params, timeout=30)
        except requests.RequestException:
            time.sleep(5 * (attempt + 1))
            continue
        if response.status_code == 200:
            # A point with no data (open sea) comes back as null: treat it as sea level.
            return [r["elevation"] if r["elevation"] is not None else 0.0 for r in response.json()["results"]]
        # Too many requests, or the service briefly unavailable: wait longer each time.
        if response.status_code == 429 or response.status_code >= 500:
            time.sleep(10 * (attempt + 1))
            continue
        response.raise_for_status()
    raise RuntimeError("OpenTopoData: still failing after 8 tries; run again to continue")


def main() -> None:
    network = StreetNetwork.load()
    n = len(network.node_lat)
    heights = np.full(n, np.nan, dtype=np.float32)
    if PARTIAL.exists():
        saved = np.load(PARTIAL)
        if len(saved) == n:
            heights = saved
            print(f"Carrying on: {int(np.isfinite(heights).sum()):,} junctions already done")
    for start in range(0, n, BATCH):
        end = min(n, start + BATCH)
        if np.isfinite(heights[start:end]).all():
            continue
        heights[start:end] = fetch(network.node_lat[start:end], network.node_lon[start:end])
        if (start // BATCH) % 25 == 0:
            print(f"{end:,} of {n:,} junctions", flush=True)
            np.save(PARTIAL, heights)
        time.sleep(PAUSE_S)
    # The terrain model reports the sea as 0 and can dip below; a street is never under the sea.
    network.node_elev = np.maximum(heights, 0).astype(np.float32)
    network.save()
    PARTIAL.unlink(missing_ok=True)
    print(f"Saved. Heights from {heights.min():.0f} to {heights.max():.0f} m, median {np.median(heights):.0f} m.")


if __name__ == "__main__":
    main()
