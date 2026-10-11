"""Mark the streets that run through or beside parks and seafront promenades (run once).

Runners would rather run in Shivaji Park or along Marine Drive than on a busy
road, so the planner treats these streets as cheaper to run on (see
GREEN_FACTOR in northstar/routing/planner.py). This script finds them and stores
the result in data/processed/street_network.npz as edge_green (1 = green).

A street counts as green when its middle point is inside, or within 20 m of
(so the road around a maidan counts too):
- a park, garden, maidan or running track in OpenStreetMap (leisure = park,
  garden, recreation_ground or track), or
- it is a footpath or pedestrian street named like a promenade or jogging
  track (Bandstand Promenade, Worli Sea Face, Joggers Park...).
Nature reserves (the National Park) are not included: their unpaved tracks
already cost extra in the planner.

Run from the Backend folder (downloads from OpenStreetMap, about a minute):
    .venv/bin/python -m scripts.add_green
"""

import re

import geopandas as gpd
import numpy as np
import osmnx as ox
from shapely.geometry import Point

from northstar import config
from northstar.routing.network import StreetNetwork

GREEN_LEISURE = ["park", "garden", "recreation_ground", "track"]
NEAR_M = 20
PROMENADE = re.compile(r"promenade|sea ?face|jogg|walkway|chowpatty|marine drive|carter road", re.IGNORECASE)
METRIC_CRS = 32643   # UTM zone 43N, metres


def main() -> None:
    network = StreetNetwork.load()
    south, west, north, east = config.MUMBAI_BBOX
    ox.settings.cache_folder = str(config.RAW_DIR / "osm" / "cache")
    areas = ox.features_from_bbox((west, south, east, north), {"leisure": GREEN_LEISURE})
    areas = areas[areas.geometry.geom_type.isin(["Polygon", "MultiPolygon"])].to_crs(METRIC_CRS)
    print(f"{len(areas):,} parks, gardens, maidans and tracks")
    zone = gpd.GeoDataFrame(geometry=[areas.buffer(NEAR_M).union_all()], crs=METRIC_CRS)

    # The middle point of every street's shape.
    middles = []
    for edge in range(len(network.edge_from)):
        shape = network.edge_shape(edge)
        lat, lon = shape[len(shape) // 2]
        middles.append(Point(float(lon), float(lat)))
    points = gpd.GeoDataFrame(geometry=middles, crs=4326).to_crs(METRIC_CRS)
    in_park = points.within(zone.geometry.iloc[0]).to_numpy()

    # Promenades and jogging tracks by name (only footpaths and quiet streets, not main roads).
    named = np.array([bool(PROMENADE.search(network.street_name(e))) for e in range(len(network.edge_from))])
    promenade = named & (network.edge_class <= 1)

    green = (in_park | promenade).astype(np.int8)
    network.edge_green = green
    network.save()
    km = float(network.edge_length[green == 1].sum()) / 1000
    print(f"{int(green.sum()):,} green streets ({km:,.0f} km): {int(in_park.sum()):,} by parks, "
          f"{int(promenade.sum()):,} promenades; saved")


if __name__ == "__main__":
    main()
