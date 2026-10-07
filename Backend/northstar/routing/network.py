"""The street network runners can use, in a compact form for fast routing.

Downloaded once from OpenStreetMap (every street and lane you can walk or run
on, main roads included) for the area the map covers plus a margin, then
stored as plain arrays:

- nodes: latitude and longitude of every junction
- edges: from-node, to-node, length in metres, road class, the H3 hexagon of
  the edge's midpoint (to look up its pollution forecast) and its shape (for
  drawing the route)

Arrays load in about a second and use far less memory than a general graph
library's objects, which matters on a small cloud server.
"""

from dataclasses import dataclass
from pathlib import Path

import h3
import numpy as np
import osmnx as ox

from northstar import config

NETWORK_FILE = config.PROCESSED_DIR / "street_network.npz"

# OpenStreetMap road types grouped by how much traffic they usually carry.
# Exhaust is concentrated within about 100 to 200 m of busy roads, so running
# along them means more exposure than the hexagon average suggests.
ROAD_CLASS = {
    "motorway": 3, "motorway_link": 3, "trunk": 3, "trunk_link": 3,
    "primary": 2, "primary_link": 2,
    "secondary": 1, "secondary_link": 1, "tertiary": 1, "tertiary_link": 1,
}
ROAD_CLASS_NAMES = {0: "quiet street", 1: "medium road", 2: "main road", 3: "highway"}


@dataclass
class StreetNetwork:
    node_lat: np.ndarray      # float64, one per node
    node_lon: np.ndarray
    edge_from: np.ndarray     # int32 node index
    edge_to: np.ndarray
    edge_length: np.ndarray   # float32, metres
    edge_class: np.ndarray    # int8, see ROAD_CLASS
    edge_cell: np.ndarray     # int64, H3 cell (resolution 9) of the midpoint
    shape_offsets: np.ndarray  # int64, edge i's points are shape_points[offsets[i]:offsets[i+1]]
    shape_points: np.ndarray   # float32, (n, 2) latitude, longitude

    def edge_shape(self, edge: int) -> np.ndarray:
        return self.shape_points[self.shape_offsets[edge]:self.shape_offsets[edge + 1]]

    def save(self, path: Path = NETWORK_FILE) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(path, **self.__dict__)

    @classmethod
    def load(cls, path: Path = NETWORK_FILE) -> "StreetNetwork":
        with np.load(path) as data:
            return cls(**{name: data[name] for name in data.files})


def _road_class(highway) -> int:
    values = highway if isinstance(highway, list) else [highway]
    return max(ROAD_CLASS.get(str(v), 0) for v in values)


def build(polygon) -> StreetNetwork:
    """Download the walkable street network inside `polygon` and pack it into arrays."""
    ox.settings.cache_folder = str(config.RAW_DIR / "osm" / "cache")
    graph = ox.graph_from_polygon(polygon, network_type="walk", simplify=True, retain_all=False)

    node_ids = list(graph.nodes)
    index = {node: i for i, node in enumerate(node_ids)}
    node_lat = np.array([graph.nodes[n]["y"] for n in node_ids])
    node_lon = np.array([graph.nodes[n]["x"] for n in node_ids])

    # The walk network is stored with both directions of each street; keep one
    # edge per direction pair (runners can go either way), using the shortest
    # if there are parallel edges between the same two junctions.
    best = {}
    for u, v, data in graph.edges(data=True):
        a, b = sorted((index[u], index[v]))
        length = float(data.get("length", 0))
        if (a, b) not in best or length < best[(a, b)][0]:
            best[(a, b)] = (length, data)

    edge_from, edge_to, lengths, classes, cells, offsets, points = [], [], [], [], [], [0], []
    for (a, b), (length, data) in best.items():
        if "geometry" in data:
            coords = [(lat, lon) for lon, lat in data["geometry"].coords]
            # make the shape run from node a to node b
            if abs(coords[0][0] - node_lat[a]) + abs(coords[0][1] - node_lon[a]) > \
               abs(coords[-1][0] - node_lat[a]) + abs(coords[-1][1] - node_lon[a]):
                coords.reverse()
        else:
            coords = [(node_lat[a], node_lon[a]), (node_lat[b], node_lon[b])]
        middle = coords[len(coords) // 2]
        edge_from.append(a)
        edge_to.append(b)
        lengths.append(length)
        classes.append(_road_class(data.get("highway")))
        cells.append(h3.str_to_int(h3.latlng_to_cell(middle[0], middle[1], 9)))
        points.extend(coords)
        offsets.append(len(points))

    return StreetNetwork(
        node_lat=node_lat, node_lon=node_lon,
        edge_from=np.array(edge_from, dtype=np.int32), edge_to=np.array(edge_to, dtype=np.int32),
        edge_length=np.array(lengths, dtype=np.float32), edge_class=np.array(classes, dtype=np.int8),
        edge_cell=np.array(cells, dtype=np.int64),
        shape_offsets=np.array(offsets, dtype=np.int64), shape_points=np.array(points, dtype=np.float32),
    )
