"""Checks for park laps (northstar/routing/parks.py and Planner.park_laps)."""

import numpy as np
import pytest

from northstar.routing import parks
from northstar.routing.network import StreetNetwork
from northstar.routing.planner import Planner

SHIVAJI_PARK = (19.0270, 72.8380)
DADAR_WEST = (19.0200, 72.8440)   # about 1 km from Shivaji Park


@pytest.fixture(scope="module")
def planner():
    return Planner(StreetNetwork.load())


@pytest.fixture(scope="module")
def exposure(planner):
    return np.full(len(planner.net.edge_from), 40.0, dtype=np.float32) * planner.uplift


def test_park_loops_are_built():
    loops = parks.load()
    assert len(loops) >= 20
    shivaji = next(l for l in loops if l["name"] == "Shivaji Park")
    assert 1000 <= shivaji["length_m"] <= 1500
    assert all(l["length_m"] >= 400 for l in loops)


def test_nearby_finds_shivaji_park():
    assert parks.nearby(parks.load(), *SHIVAJI_PARK)[0]["name"] == "Shivaji Park"


@pytest.mark.parametrize("kind", ["loop", "one_way"])
@pytest.mark.parametrize("mode,count", [("half", None), ("all", None), ("count", 3)])
def test_laps_hit_the_distance(planner, exposure, kind, mode, count):
    near = parks.nearby(parks.load(), *SHIVAJI_PARK)
    options = planner.park_laps(*SHIVAJI_PARK, 5000, exposure, near, mode, count, kind, True, 1)
    assert options, f"no lap route for {kind} {mode}"
    option = options[0]
    assert abs(option.distance_m - 5000) <= 300
    assert option.extra["park"]["name"] == "Shivaji Park"
    assert option.extra["park"]["laps"] >= 1.5


def test_too_far_for_a_short_loop(planner, exposure):
    # 1 km away: a 2 km loop cannot reach the park and come back, so no lap route.
    near = parks.nearby(parks.load(), *DADAR_WEST)
    assert planner.park_laps(*DADAR_WEST, 2000, exposure, near, "all", None, "loop", True, 1) == []


def test_one_way_from_nearby_finishes_with_laps(planner, exposure):
    near = parks.nearby(parks.load(), *DADAR_WEST)
    options = planner.park_laps(*DADAR_WEST, 2000, exposure, near, "half", None, "one_way", True, 1)
    assert options and abs(options[0].distance_m - 2000) <= 120
