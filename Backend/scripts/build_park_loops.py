"""Find a runnable loop around each named park in Mumbai, for "Park laps" (run once).

For short runs, laps of a park are often the best run: quieter, cleaner, no traffic
crossings. This script finds, for every named park, maidan, garden or running track
in OpenStreetMap whose edge is 400 m to 3.5 km long, a loop on our street network
that follows that edge:
1. walk round the park's outline, a point every 30 m;
2. snap each point to the nearest street within 45 m (any point of its line, as
   junctions can be far apart along a straight road), and take that street's
   nearer end junction;
3. join neighbouring junctions by the shortest way, preferring green streets (those
   through or beside parks), so the loop hugs the park.
A loop is kept only if at least 80% of the outline found a street, it is at least
400 m long, its length is 0.6 to 1.6 times the outline, and it repeats less than
15% of itself.

The loops are saved as junction numbers in data/processed/park_loops.json, which
the route server loads. Run again whenever the street network is rebuilt.

Run from the Backend folder (downloads parks from OpenStreetMap, about a minute):
    .venv/bin/python -m scripts.build_park_loops
"""

import json

import numpy as np
import osmnx as ox
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import cKDTree

from northstar import config
from northstar.routing.network import StreetNetwork
from northstar.routing.parks import PARK_LOOPS_FILE

LEISURE = ["park", "recreation_ground", "track", "garden"]
METRIC_CRS = 32643          # UTM zone 43N, metres
STEP_M = 30
SNAP_M = 45
NON_GREEN_COST = 4.0        # a non-green street costs 4x its length when tracing a loop


def main() -> None:
    net = StreetNetwork.load()
    green = net.edge_green.astype(bool) if net.edge_green is not None else np.zeros(len(net.edge_from), bool)
    lat0 = float(np.mean(net.node_lat))
    kx = np.cos(np.radians(lat0)) * 111_320
    xy = np.column_stack([net.node_lon * kx, net.node_lat * 111_320])
    tree = cKDTree(xy)
    # Every point of every street's line, to snap the outline onto streets.
    counts = np.diff(net.shape_offsets)
    shape_edge = np.repeat(np.arange(len(counts)), counts)
    shape_xy = np.column_stack([net.shape_points[:, 1] * kx, net.shape_points[:, 0] * 111_320])
    shape_tree = cKDTree(shape_xy)

    south, west, north, east = config.MUMBAI_BBOX
    ox.settings.cache_folder = str(config.RAW_DIR / "osm" / "cache")
    parks = ox.features_from_bbox((west, south, east, north), {"leisure": LEISURE})
    parks = parks[parks.geometry.geom_type.isin(["Polygon", "MultiPolygon"]) & parks["name"].notna()]
    metric = parks.to_crs(METRIC_CRS)
    outlines = metric.geometry.apply(lambda g: g if g.geom_type == "Polygon" else max(g.geoms, key=lambda p: p.area)).exterior
    parks = parks.assign(perimeter=outlines.length.values)
    parks = parks[(parks.perimeter >= 400) & (parks.perimeter <= 3500)]
    print(f"{len(parks)} named parks with a 0.4 to 3.5 km edge")

    loops, seen = [], set()
    import collections, os
    reasons = collections.Counter()
    debug = os.getenv('PARK_DEBUG', '')
    for (_, park), outline in zip(parks.iterrows(), outlines.loc[parks.index]):
        name = str(park["name"]).strip()
        # Points along the outline, back in latitude and longitude.
        count = max(8, int(outline.length / STEP_M))
        metric_points = [outline.interpolate(i / count, normalized=True) for i in range(count)]
        lonlat = gpd_to_lonlat(metric_points)
        snapped, found = [], 0
        for lon, lat in lonlat:
            point = np.array([lon * kx, lat * 111_320])
            # The nearest green street (beside or through the park) within reach, else
            # the nearest street, so the loop does not snap onto side streets.
            distances, ids = shape_tree.query(point, k=12, distance_upper_bound=SNAP_M)
            hits = [(d, shape_edge[i]) for d, i in zip(distances, ids) if np.isfinite(d)]
            if not hits:
                continue
            found += 1
            edge = next((e for _, e in hits if green[e]), hits[0][1])
            ends = (int(net.edge_from[edge]), int(net.edge_to[edge]))
            node = min(ends, key=lambda n: np.hypot(*(xy[n] - point)))
            if not snapped or snapped[-1] != node:
                snapped.append(node)
        if len(snapped) > 1 and snapped[0] == snapped[-1]:
            snapped.pop()
        if len(snapped) < 4 or found / count < 0.8:
            reasons['outline not on streets'] += 1
            if debug and debug in name: print(name, 'found share', round(found / count, 2), 'snapped', len(snapped))
            continue

        # The streets near the park, as a small graph that prefers green streets.
        near = np.array(sorted(set(tree.query_ball_point(xy[snapped].mean(axis=0), outline.length / 2 + 200))))
        index = {int(n): i for i, n in enumerate(near)}
        inside = np.isin(net.edge_from, near) & np.isin(net.edge_to, near)
        edges = np.where(inside)[0]
        a = np.array([index[int(n)] for n in net.edge_from[edges]])
        b = np.array([index[int(n)] for n in net.edge_to[edges]])
        cost = net.edge_length[edges].astype(float) * np.where(green[edges], 1.0, NON_GREEN_COST)
        graph = csr_matrix((np.concatenate([cost, cost]), (np.concatenate([a, b]), np.concatenate([b, a]))),
                           shape=(len(near), len(near)))
        pair = {}
        for i, e in enumerate(edges):
            pair[(a[i], b[i])] = pair[(b[i], a[i])] = int(e)

        loop_nodes, ok = [snapped[0]], True
        for here, there in zip(snapped, snapped[1:] + snapped[:1]):
            if here not in index or there not in index:
                ok = False
                break
            _, previous = dijkstra(graph, indices=index[here], return_predecessors=True)
            path, node = [index[there]], index[there]
            while node != index[here]:
                node = previous[node]
                if node < 0:
                    ok = False
                    break
                path.append(node)
            if not ok:
                break
            loop_nodes += [int(near[n]) for n in path[::-1][1:]]
        if not ok:
            reasons['no path between points'] += 1
            if debug and debug in name: print(name, 'no path')
            continue
        loop_nodes = without_spurs(loop_nodes)
        loop_edges = [pair[(index[x], index[y])] for x, y in zip(loop_nodes[:-1], loop_nodes[1:])]
        length = float(net.edge_length[loop_edges].sum())
        unique = float(net.edge_length[list(set(loop_edges))].sum())
        repeated = 1 - unique / max(length, 1)
        if not (0.6 * outline.length <= length <= 1.6 * outline.length) or repeated > 0.15 or length < 400:
            reasons['loop too long, short or doubled back'] += 1
            if debug and debug in name: print(name, 'length', round(length), 'outline', round(outline.length), 'repeated', round(repeated, 2))
            continue
        key = (name.lower(), round(length / 50))
        if key in seen:
            continue
        seen.add(key)
        centre = xy[loop_nodes].mean(axis=0)
        loops.append({"name": name, "lat": round(float(centre[1] / 111_320), 6), "lon": round(float(centre[0] / kx), 6),
                      "length_m": round(length), "green_share": round(float(net.edge_length[[e for e in loop_edges if green[e]]].sum()) / length, 2),
                      "nodes": loop_nodes})

    print("dropped:", dict(reasons))
    PARK_LOOPS_FILE.write_text(json.dumps(loops) + "\n")
    print(f"saved {len(loops)} park loops to {PARK_LOOPS_FILE.name}")
    for loop in sorted(loops, key=lambda l: l["name"])[:400]:
        if any(word in loop["name"] for word in ("Shivaji Park", "Priyadarshini", "Joggers", "Cross Maidan", "Hanging", "Kamala Nehru")):
            print(f"  {loop['name']}: {loop['length_m']} m, {loop['green_share']:.0%} green")


def without_spurs(nodes: list[int]) -> list[int]:
    """Removes in-and-out spurs (a -> b -> a becomes a), repeatedly, so the loop only
    goes round the park."""
    changed = True
    while changed:
        changed = False
        out: list[int] = []
        for node in nodes:
            if len(out) >= 2 and out[-2] == node:
                out.pop()          # went to out[-1] and straight back
                changed = True
            elif out and out[-1] == node:
                continue
            else:
                out.append(node)
        nodes = out
    return nodes


def gpd_to_lonlat(points) -> list[tuple[float, float]]:
    """Points in metres (UTM 43N) back to (longitude, latitude)."""
    import geopandas as gpd
    series = gpd.GeoSeries(points, crs=METRIC_CRS).to_crs(4326)
    return [(p.x, p.y) for p in series]


if __name__ == "__main__":
    main()
