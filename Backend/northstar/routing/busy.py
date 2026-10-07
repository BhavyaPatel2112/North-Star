"""Which streets cross a highway.

A runner can cross a highway in two ways:
1. At road level, through a junction the street shares with the highway
   (found in the planner from the junctions themselves).
2. Over or under it: a road passing beneath a flyover, or a bridge over the
   highway. These share no junction with the highway, so we find them by
   geometry: does the street's line cross a highway's line?

Both count as "crossing a highway" for the app's "OK with highways" switch.
This file handles the second kind. It runs once when the server starts
(about a second) using plain numpy, so the server needs no extra libraries.
"""

import numpy as np
from scipy.spatial import cKDTree

EARTH_M_PER_DEG = 111_320.0
PIECE_M = 40.0  # long highway segments are cut into pieces this long for the nearby search


def _segments(network, edges: np.ndarray, kx: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Every straight piece of the given edges as start and end points in metres, plus its edge id."""
    starts, ends, owner = [], [], []
    for edge in edges:
        points = network.edge_shape(int(edge)).astype(np.float64)
        if len(points) < 2:
            continue
        xy = np.column_stack([points[:, 1] * kx, points[:, 0] * EARTH_M_PER_DEG])
        starts.append(xy[:-1])
        ends.append(xy[1:])
        owner.append(np.full(len(xy) - 1, edge))
    if not starts:
        empty = np.zeros((0, 2))
        return empty, empty, np.zeros(0, dtype=np.int64)
    return np.vstack(starts), np.vstack(ends), np.concatenate(owner)


def _split(starts: np.ndarray, ends: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Cut segments longer than PIECE_M into equal pieces."""
    lengths = np.linalg.norm(ends - starts, axis=1)
    counts = np.maximum(1, np.ceil(lengths / PIECE_M).astype(int))
    index = np.repeat(np.arange(len(starts)), counts)
    step = np.concatenate([np.arange(c) for c in counts])
    t0 = step / counts[index]
    t1 = (step + 1) / counts[index]
    delta = ends[index] - starts[index]
    return starts[index] + delta * t0[:, None], starts[index] + delta * t1[:, None]


def _cross(p1, p2, q1, q2) -> np.ndarray:
    """True where segment p1-p2 properly crosses q1-q2 (touching at an end does not count)."""
    def side(a, b, c):
        return np.sign((b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0]))
    return (side(p1, p2, q1) * side(p1, p2, q2) < 0) & (side(q1, q2, p1) * side(q1, q2, p2) < 0)


def edges_crossing_highways(network, kx: float) -> np.ndarray:
    """A True/False flag per street: does it pass over or under a highway?"""
    highway = network.edge_class == 3
    result = np.zeros(len(network.edge_class), dtype=bool)
    h_start, h_end, _ = _segments(network, np.where(highway)[0], kx)
    if len(h_start) == 0:
        return result
    h_start, h_end = _split(h_start, h_end)
    tree = cKDTree((h_start + h_end) / 2)

    # Only streets with a point near a highway can cross one; check those.
    node_xy = np.column_stack([network.node_lon * kx, network.node_lat * EARTH_M_PER_DEG])
    dist, _ = tree.query(node_xy, distance_upper_bound=1_000)
    near_node = np.isfinite(dist)
    candidates = np.where(~highway & (near_node[network.edge_from] | near_node[network.edge_to]))[0]

    s_start, s_end, owner = _segments(network, candidates, kx)
    if len(s_start) == 0:
        return result
    half = np.linalg.norm(s_end - s_start, axis=1) / 2 + PIECE_M
    pairs = tree.query_ball_point((s_start + s_end) / 2, r=half)
    a = np.repeat(np.arange(len(pairs)), [len(p) for p in pairs])
    if len(a) == 0:
        return result
    b = np.concatenate([np.asarray(p, dtype=np.int64) for p in pairs])
    hits = _cross(s_start[a], s_end[a], h_start[b], h_end[b])
    result[np.unique(owner[a[hits]])] = True
    return result
