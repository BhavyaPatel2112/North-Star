"""Tests for the city-layout measurements, using shapes with known answers."""

import geopandas as gpd
import numpy as np
from shapely.geometry import LineString, Point, box

from northstar.model.features import METRIC_CRS, _distance_to, _length_within, _share_within


def points(*xy):
    return gpd.GeoSeries([Point(x, y) for x, y in xy], crs=METRIC_CRS)


def shapes(*geoms):
    return gpd.GeoDataFrame(geometry=list(geoms), crs=METRIC_CRS)


def test_length_within_counts_only_the_part_inside_the_circle():
    # A straight 10 km road passing through the centre: 500 m circle holds 1000 m of it.
    road = shapes(LineString([(-5000, 0), (5000, 0)]))
    lengths = _length_within(points((0, 0), (0, 3000)), road, 500)
    assert np.isclose(lengths[0], 1000, rtol=0.01)
    assert lengths[1] == 0  # 3 km away: none of the road inside


def test_share_within_half_covered_circle():
    # Land covering everything east of the point covers half the circle.
    land = shapes(box(0, -5000, 5000, 5000))
    share = _share_within(points((0, 0)), land, 500)
    assert np.isclose(share[0], 0.5, rtol=0.02)


def test_distance_to_nearest_shape():
    road = shapes(LineString([(0, 1000), (100, 1000)]))
    assert np.isclose(_distance_to(points((0, 0)), road)[0], 1000)


def test_works_on_filtered_tables_with_gaps_in_row_numbers():
    # Filtering keeps the original row labels (here 1 and 3); results must not depend on them.
    roads = shapes(LineString([(9000, 9000), (9100, 9000)]), LineString([(-5000, 0), (5000, 0)]),
                   LineString([(9000, 9000), (9100, 9000)]), LineString([(0, -5000), (0, 5000)]))
    roads.index.name = "osm_id"
    crossing = roads.iloc[[1, 3]]
    assert np.isclose(_length_within(points((0, 0)), crossing, 500)[0], 2000, rtol=0.01)
    assert np.isclose(_share_within(points((0, 0)), shapes(box(0, -5000, 5000, 5000)).iloc[[0]], 500)[0], 0.5, rtol=0.02)

