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


def test_fire_upwind_score_positive_only_when_wind_blows_from_the_fire():
    import pandas as pd
    from northstar.model.dataset import add_fire_features

    # A fire 50 km due north of the station, one hour before.
    fires = pd.DataFrame({"detected_at": pd.to_datetime(["2025-01-01 10:00"], utc=True),
                          "latitude": [19.0 + 50 / 111.0], "longitude": [72.9], "frp": [100.0]})
    locations = pd.DataFrame({"latitude": [19.0], "longitude": [72.9]}, index=[1])
    ts = pd.to_datetime(["2025-01-01 11:00"] * 2 + ["2025-01-03 11:00"], utc=True)
    # Wind from the north (0°) blows smoke towards us; wind from the south (180°) blows it away.
    frame = pd.DataFrame({"station_id": 1, "ts": ts, "wind_dir_deg": [0.0, 180.0, 0.0]})
    out = add_fire_features(frame, fires, locations)
    assert out.fire_upwind_300km_24h[0] > 0 > out.fire_upwind_300km_24h[1]
    assert out.fire_frp_100km_24h[0] == 100 and out.fire_frp_25km_24h[0] == 0
    assert out.fire_frp_100km_24h[2] == 0  # two days later: outside the 24-hour window
    assert out.fire_frp_300km_72h[2] == 100  # but still inside the 72-hour window
