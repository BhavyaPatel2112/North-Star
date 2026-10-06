"""City-layout features from OpenStreetMap, for any set of points.

For each point (a hexagon centre or a station) we measure what surrounds
it: how much major road is nearby, how far the nearest highway is, how much
land is industrial or green, how far the coast is, and so on. These explain
why two places under the same weather have different air.

All measuring happens in metres, in the UTM zone 43N map projection
(EPSG:32643), which is accurate for Mumbai.
"""

import geopandas as gpd
import numpy as np
import osmnx as ox
import pandas as pd
import shapely

from northstar import config

METRIC_CRS = 32643
OSM_DIR = config.RAW_DIR / "osm"

ROAD_CLASSES = {
    "major": ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link"],
    "secondary": ["secondary", "secondary_link", "tertiary", "tertiary_link"],
    "minor": ["residential", "unclassified", "living_street"],
}
HIGHWAY = ["motorway", "motorway_link", "trunk", "trunk_link"]

LAND_TAGS = {
    "landuse": ["industrial", "commercial", "retail", "residential", "construction",
                "forest", "grass", "meadow", "recreation_ground", "basin", "reservoir"],
    "leisure": ["park", "garden", "nature_reserve", "golf_course"],
    "natural": ["wood", "scrub", "grassland", "wetland", "water"],
    "aeroway": ["aerodrome"],
}


def _category(row) -> str | None:
    """Group OpenStreetMap tags into a few land categories."""
    landuse, leisure, natural, aeroway = (row.get(k) for k in ("landuse", "leisure", "natural", "aeroway"))
    if aeroway == "aerodrome":
        return "airport"
    if landuse == "industrial":
        return "industrial"
    if landuse in ("commercial", "retail"):
        return "commercial"
    if landuse == "residential":
        return "residential"
    if landuse == "construction":
        return "construction"
    if natural == "water" or landuse in ("basin", "reservoir"):
        return "water"
    if (landuse in ("forest", "grass", "meadow", "recreation_ground")
            or leisure in ("park", "garden", "nature_reserve", "golf_course")
            or natural in ("wood", "scrub", "grassland", "wetland")):
        return "green"
    return None


def download_osm(polygon) -> dict[str, gpd.GeoDataFrame]:
    """Download roads, land use and coastline inside `polygon`, cached as files.

    Returns three tables in metres: roads (with a road class), land (with a
    land category, overlaps merged per category) and coastline.
    """
    OSM_DIR.mkdir(parents=True, exist_ok=True)
    paths = {name: OSM_DIR / f"{name}.parquet" for name in ("roads", "land", "coastline")}
    if all(p.exists() for p in paths.values()):
        return {name: gpd.read_parquet(p) for name, p in paths.items()}

    wanted = [c for classes in ROAD_CLASSES.values() for c in classes]
    roads = ox.features_from_polygon(polygon, {"highway": wanted})
    roads = roads[roads.geom_type.isin(["LineString", "MultiLineString"])]
    road_class = {c: name for name, classes in ROAD_CLASSES.items() for c in classes}
    roads = gpd.GeoDataFrame(
        {"highway": roads.highway.astype(str), "road_class": roads.highway.astype(str).map(road_class)},
        geometry=roads.geometry.values, crs=4326,
    ).to_crs(METRIC_CRS)

    land = ox.features_from_polygon(polygon, LAND_TAGS)
    land = land[land.geom_type.isin(["Polygon", "MultiPolygon"])].copy()
    land["category"] = [_category(row) for _, row in land.iterrows()]
    land = land.dropna(subset=["category"])
    # Merge overlapping shapes of the same category so area is not counted twice.
    land = gpd.GeoDataFrame(land[["category"]], geometry=land.geometry.values, crs=4326).to_crs(METRIC_CRS)
    land["geometry"] = land.geometry.make_valid()
    land = land.dissolve(by="category").reset_index().explode(index_parts=False).reset_index(drop=True)

    coast = ox.features_from_polygon(polygon, {"natural": "coastline"})
    coast = gpd.GeoDataFrame(geometry=coast.geometry.values, crs=4326).to_crs(METRIC_CRS)

    tables = {"roads": roads, "land": land, "coastline": coast}
    for name, table in tables.items():
        table.to_parquet(paths[name])
    return tables


def _length_within(points: gpd.GeoSeries, lines: gpd.GeoDataFrame, radius: float) -> np.ndarray:
    """Total length (m) of `lines` inside a circle of `radius` m around each point."""
    # Number rows 0, 1, 2... so join results can be used as positions.
    lines = lines[["geometry"]].reset_index(drop=True)
    buffers = gpd.GeoDataFrame(geometry=points.buffer(radius), crs=METRIC_CRS)
    pairs = gpd.sjoin(buffers, lines, predicate="intersects")
    if pairs.empty:
        return np.zeros(len(points))
    clipped = shapely.intersection(
        buffers.geometry.values[pairs.index.to_numpy()], lines.geometry.values[pairs.index_right.to_numpy()]
    )
    lengths = pd.Series(shapely.length(clipped), index=pairs.index).groupby(level=0).sum()
    return lengths.reindex(range(len(points)), fill_value=0).to_numpy()


def _share_within(points: gpd.GeoSeries, shapes: gpd.GeoDataFrame, radius: float) -> np.ndarray:
    """Fraction (0 to 1) of a circle of `radius` m around each point covered by `shapes`."""
    # Number rows 0, 1, 2... so join results can be used as positions.
    shapes = shapes[["geometry"]].reset_index(drop=True)
    buffers = gpd.GeoDataFrame(geometry=points.buffer(radius), crs=METRIC_CRS)
    pairs = gpd.sjoin(buffers, shapes, predicate="intersects")
    if pairs.empty:
        return np.zeros(len(points))
    clipped = shapely.intersection(
        buffers.geometry.values[pairs.index.to_numpy()], shapes.geometry.values[pairs.index_right.to_numpy()]
    )
    areas = pd.Series(shapely.area(clipped), index=pairs.index).groupby(level=0).sum()
    circle = np.pi * radius ** 2
    return np.clip(areas.reindex(range(len(points)), fill_value=0).to_numpy() / circle, 0, 1)


def _distance_to(points: gpd.GeoSeries, shapes: gpd.GeoDataFrame, cap: float = 20_000) -> np.ndarray:
    """Distance (m) from each point to the nearest shape, capped at `cap`."""
    if shapes.empty:
        return np.full(len(points), cap)
    tree = shapely.STRtree(shapes.geometry.values)
    _, distances = tree.query_nearest(points.values, return_distance=True, all_matches=False)
    return np.minimum(distances, cap)


def compute_features(points: gpd.GeoDataFrame, osm: dict[str, gpd.GeoDataFrame]) -> pd.DataFrame:
    """One row of city-layout features per point (same order as `points`)."""
    pts = points.to_crs(METRIC_CRS).geometry.reset_index(drop=True)
    roads, land, coast = osm["roads"], osm["land"], osm["coastline"]
    major = roads[roads.road_class == "major"]
    features = {}

    for radius in (250, 500, 1000):
        features[f"major_road_m_{radius}"] = _length_within(pts, major, radius)
    features["secondary_road_m_500"] = _length_within(pts, roads[roads.road_class == "secondary"], 500)
    features["minor_road_m_500"] = _length_within(pts, roads[roads.road_class == "minor"], 500)
    features["dist_major_road_m"] = _distance_to(pts, major)
    features["dist_highway_m"] = _distance_to(pts, roads[roads.highway.isin(HIGHWAY)])

    for category in ("industrial", "commercial", "residential", "construction", "green", "water"):
        shapes = land[land.category == category]
        features[f"{category}_share_500"] = _share_within(pts, shapes, 500)
        if category in ("industrial", "green", "water"):
            features[f"{category}_share_1000"] = _share_within(pts, shapes, 1000)
    features["dist_industrial_m"] = _distance_to(pts, land[land.category == "industrial"])
    features["dist_airport_m"] = _distance_to(pts, land[land.category == "airport"])
    features["dist_coast_m"] = _distance_to(pts, coast)

    return pd.DataFrame(features).astype("float32")
