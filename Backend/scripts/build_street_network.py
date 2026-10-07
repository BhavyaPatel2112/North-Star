"""Download the runnable street network for the covered area and save it compactly.

Run from the Backend folder (first run downloads from OpenStreetMap, several minutes):
    .venv/bin/python -m scripts.build_street_network
"""

import time

import geopandas as gpd

from northstar.model.features import METRIC_CRS
from northstar.model.grid import app_area
from northstar.routing.network import NETWORK_FILE, build


def main() -> None:
    started = time.time()
    area = app_area()
    # 1 km margin so routes near the edge of the covered cities still work.
    polygon = gpd.GeoSeries([area.to_crs(METRIC_CRS).buffer(1000).union_all()], crs=METRIC_CRS).to_crs(4326).iloc[0]
    network = build(polygon)
    network.save()
    size = NETWORK_FILE.stat().st_size / 1e6
    km = network.edge_length.sum() / 1000
    by_class = {c: round(float(network.edge_length[network.edge_class == c].sum() / 1000)) for c in range(4)}
    print(f"{len(network.node_lat):,} junctions, {len(network.edge_from):,} street segments, {km:,.0f} km of streets")
    print(f"km by road type (0 quiet street ... 3 highway): {by_class}")
    print(f"saved {NETWORK_FILE.name}: {size:.1f} MB in {time.time() - started:.0f} s")


if __name__ == "__main__":
    main()
