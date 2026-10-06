"""The hexagon grid the app shows on its map.

Uber's H3 library splits the Earth into hexagons. At resolution 9 each
hexagon is about 0.1 km² (roughly 350 m across), small enough to show
street-to-street differences without needing more data than we have.
Hexagons are used instead of squares because all six neighbours of a
hexagon are the same distance from its centre, which keeps smoothing and
routing simple.
"""

import geopandas as gpd
import h3
import osmnx as ox
import pandas as pd
from shapely.geometry import Point

from northstar import config

H3_RESOLUTION = 9

# OpenStreetMap boundaries of the area the map covers (looked up by name
# once; the ids are stable, the names are ambiguous).
AREA_RELATIONS = {
    "R7964376": "Mumbai City District",
    "R7964375": "Mumbai Suburban District",
    "R7120000": "Thane",
    "R13180880": "Navi Mumbai",
    "R13180677": "Mira-Bhayandar",
}

ox.settings.cache_folder = str(config.RAW_DIR / "osm" / "cache")


def app_area() -> gpd.GeoDataFrame:
    """The covered cities as polygons (latitude/longitude)."""
    area = ox.geocode_to_gdf(list(AREA_RELATIONS), by_osmid=True)
    area["name"] = list(AREA_RELATIONS.values())
    return area[["name", "geometry"]]


def build_cells(area: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Every H3 hexagon whose centre lies inside the area, with its centre point."""
    cells = set()
    for polygon in area.explode(index_parts=False).geometry:
        # h3 expects (latitude, longitude) pairs; shapely stores (longitude, latitude).
        outer = [(lat, lon) for lon, lat in polygon.exterior.coords]
        holes = [[(lat, lon) for lon, lat in ring.coords] for ring in polygon.interiors]
        cells.update(h3.polygon_to_cells(h3.LatLngPoly(outer, *holes), H3_RESOLUTION))

    rows = []
    for cell in sorted(cells):
        lat, lon = h3.cell_to_latlng(cell)
        rows.append({"h3_index": cell, "latitude": lat, "longitude": lon})
    frame = pd.DataFrame(rows)
    return gpd.GeoDataFrame(
        frame, geometry=[Point(lon, lat) for lat, lon in zip(frame.latitude, frame.longitude)], crs=4326
    )
