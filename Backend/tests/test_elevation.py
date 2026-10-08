"""Checks for the route elevation profile (northstar/routing/elevation.py)."""

from types import SimpleNamespace

import numpy as np

from northstar.routing import elevation


def network(heights: list[float], segment_m: float = 100.0) -> SimpleNamespace:
    """A straight test road: junctions every `segment_m` metres with the given heights."""
    n = len(heights)
    return SimpleNamespace(node_elev=np.array(heights, dtype=np.float32),
                           edge_length=np.full(n - 1, segment_m, dtype=np.float32))


def run(heights: list[float]) -> dict:
    net = network(heights)
    return elevation.profile(net, list(range(len(heights))), list(range(len(heights) - 1)))


def test_flat_road_has_no_climb():
    # Small wobbles (buildings in the terrain data) must not count as climbing.
    result = run([10, 11, 10, 11.5, 10, 10.5, 11, 10, 10.5, 10, 11])
    assert result["climb_m"] == 0
    assert result["descent_m"] == 0


def test_hill_counts_its_height_once_each_way():
    # Up 40 m over 1 km, then back down.
    up = list(np.linspace(10, 50, 11))
    result = run(up + up[::-1][1:])
    assert 30 <= result["climb_m"] <= 42      # smoothing rounds the top off a little
    assert 30 <= result["descent_m"] <= 42
    assert result["max_m"] <= 50 and result["min_m"] >= 10


def test_profile_runs_the_whole_distance_in_km():
    result = run([5] * 21)                    # 2 km
    points = result["points"]
    assert points[0][0] == 0
    assert abs(points[-1][0] - 2.0) < 0.001
    assert len(points) <= elevation.MAX_POINTS


def test_no_heights_means_no_profile():
    net = SimpleNamespace(node_elev=None, edge_length=np.ones(3, dtype=np.float32))
    assert elevation.profile(net, [0, 1, 2], [0, 1]) is None
