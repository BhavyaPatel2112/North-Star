"""Plan running routes of a chosen distance that keep exposure to pollution low.

How it works, in short:
- Every street segment gets a cost for the chosen hour: its length, scaled up
  by how polluted it is (the forecast for its hexagon, raised for main roads
  and highways where exhaust concentrates). The cheapest path is then both
  short and clean.
- Each request only searches the streets within reach of the start (a run
  of 5 km never goes further than 2.5 km away), which keeps it fast.
- Round trips: loops through two turning points, tried in many directions and
  sizes at once (in Mumbai, loop length jumps around as creeks, highways and
  the National Park get in the way, so resizing one loop does not converge).
  Streets already used get a penalty so loops do not double back. Loops within
  a few percent of the target are kept, and the cleanest distinct ones win.
- One way: every junction reachable at about the target distance is a possible
  finish; the cleanest ones in different directions are kept. With chosen
  finishing places (such as cafes), routes go to them, adding a detour when
  they are closer than the target distance.
- Every option is compared with the plain shortest route of the same kind, so
  the app can say how much cleaner it is.
"""

from dataclasses import dataclass, field
from math import cos, radians, sin

import numpy as np
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import cKDTree

from northstar.routing.network import ROAD_CLASS_NAMES, StreetNetwork

# How much more polluted the air right beside each road type is than the
# hexagon average (a modest near-road uplift for fine particles).
ROAD_UPLIFT = {0: 1.0, 1: 1.08, 2: 1.18, 3: 1.30}

# How strongly a route avoids pollution: 0 = shortest only, higher = cleaner.
STYLES = {"cleanest": 2.0, "direct": 0.0}

TOLERANCE = 0.03          # routes must be within 3% of the target distance
REUSE_PENALTY = 4.0       # cost multiplier for streets already used earlier in a loop
EARTH_M_PER_DEG = 111_320.0


@dataclass
class RouteOption:
    kind: str                       # "loop", "out_and_back" or "one_way"
    style: str                      # "cleanest" or "direct"
    edges: list[int]                # street segments (network-wide ids), in running order
    nodes: list[int]                # junctions (network-wide ids), in running order
    distance_m: float
    mean_pm25: float                # length-weighted, including the near-road uplift
    quiet_share: float              # share of distance on quiet streets
    main_road_share: float          # share of distance on main roads or highways
    repeated_share: float           # share of distance run twice
    finish: tuple[float, float] = (0.0, 0.0)
    cleaner_than_direct: float | None = None  # 0.18 = 18% less exposure than the direct route
    label: str = ""
    extra: dict = field(default_factory=dict)


class Area:
    """The streets within reach of one start point, as a small graph for fast searches."""

    def __init__(self, net: StreetNetwork, node_ids: np.ndarray):
        self.node_ids = node_ids                                   # local -> network-wide
        self.local = {int(n): i for i, n in enumerate(node_ids)}   # network-wide -> local
        inside = np.isin(net.edge_from, node_ids) & np.isin(net.edge_to, node_ids)
        self.edge_ids = np.where(inside)[0]                        # local edge -> network-wide
        lookup = np.full(len(net.node_lat), -1, dtype=np.int64)
        lookup[node_ids] = np.arange(len(node_ids))
        self.a = lookup[net.edge_from[self.edge_ids]]
        self.b = lookup[net.edge_to[self.edge_ids]]
        self.length = net.edge_length[self.edge_ids].astype(np.float64)
        self.pair = {}
        for i, (a, b) in enumerate(zip(self.a.tolist(), self.b.tolist())):
            self.pair[(a, b)] = i
            self.pair[(b, a)] = i

    def graph(self, weights: np.ndarray) -> csr_matrix:
        n = len(self.node_ids)
        w = np.maximum(weights, 0.01)
        return csr_matrix((np.concatenate([w, w]), (np.concatenate([self.a, self.b]), np.concatenate([self.b, self.a]))),
                          shape=(n, n))

    def tree(self, weights: np.ndarray, source: int):
        """Cheapest-path costs from `source` to every junction, and each junction's predecessor."""
        return dijkstra(self.graph(weights), indices=source, return_predecessors=True)

    def path(self, predecessors: np.ndarray, source: int, target: int) -> list[int] | None:
        nodes, node = [target], target
        while node != source:
            node = int(predecessors[node])
            if node < 0:
                return None
            nodes.append(node)
        return nodes[::-1]

    def edges_of(self, nodes: list[int]) -> list[int]:
        return [self.pair[(a, b)] for a, b in zip(nodes[:-1], nodes[1:])]

    def lengths_along_tree(self, costs: np.ndarray, predecessors: np.ndarray, source: int) -> np.ndarray:
        """Distance in metres along the cheapest-path tree from `source` to every junction."""
        length = np.full(len(self.node_ids), np.inf)
        length[source] = 0.0
        for node in np.argsort(costs):
            parent = predecessors[node]
            if parent >= 0 and np.isfinite(length[parent]):
                length[node] = length[parent] + self.length[self.pair[(int(parent), int(node))]]
        return length


class Planner:
    def __init__(self, network: StreetNetwork):
        self.net = network
        self.lat0 = float(np.mean(network.node_lat))
        self.kx = cos(radians(self.lat0)) * EARTH_M_PER_DEG
        self.xy = np.column_stack([network.node_lon * self.kx, network.node_lat * EARTH_M_PER_DEG])
        self.tree = cKDTree(self.xy)
        self.uplift = np.vectorize(ROAD_UPLIFT.get)(network.edge_class).astype(np.float32)

    # ---------- basics ----------

    def nearest_node(self, lat: float, lon: float) -> int:
        _, index = self.tree.query([lon * self.kx, lat * EARTH_M_PER_DEG])
        return int(index)

    def point_at(self, lat: float, lon: float, bearing_deg: float, distance_m: float) -> tuple[float, float]:
        """The point `distance_m` from (lat, lon) in compass direction `bearing_deg`."""
        b = radians(bearing_deg)
        return (lat + distance_m * cos(b) / EARTH_M_PER_DEG, lon + distance_m * sin(b) / self.kx)

    def area(self, lat: float, lon: float, reach_m: float) -> Area:
        """Streets within `reach_m` (straight line) of a point."""
        nodes = np.array(sorted(self.tree.query_ball_point([lon * self.kx, lat * EARTH_M_PER_DEG], reach_m)))
        return Area(self.net, nodes)

    def edge_exposure(self, cell_pm25: dict[int, float], default_pm25: float) -> np.ndarray:
        """PM2.5 a runner breathes on each street at one hour (hexagon value x road uplift)."""
        base = np.array([cell_pm25.get(int(c), default_pm25) for c in self.net.edge_cell], dtype=np.float32)
        return base * self.uplift

    def _weights(self, area: Area, exposure: np.ndarray, style: str) -> np.ndarray:
        """Street cost = length x (exposure relative to the local median) ^ strength."""
        local = exposure[area.edge_ids].astype(np.float64)
        relative = local / max(float(np.median(local)), 1.0)
        return area.length * np.power(relative, STYLES[style])

    def _describe(self, area: Area, kind: str, style: str, local_nodes: list[int], exposure: np.ndarray) -> RouteOption:
        edges = area.edge_ids[area.edges_of(local_nodes)].tolist()
        nodes = area.node_ids[local_nodes].tolist()
        lengths = self.net.edge_length[edges].astype(np.float64)
        classes = self.net.edge_class[edges]
        distance = float(lengths.sum())
        unique, counts = np.unique(edges, return_counts=True)
        repeated = float(sum(self.net.edge_length[e] * (c - 1) for e, c in zip(unique, counts) if c > 1))
        return RouteOption(
            kind=kind, style=style, edges=edges, nodes=nodes, distance_m=distance,
            mean_pm25=float(np.average(exposure[edges], weights=lengths)) if distance else 0.0,
            quiet_share=float(lengths[classes == 0].sum()) / distance if distance else 0.0,
            main_road_share=float(lengths[classes >= 2].sum()) / distance if distance else 0.0,
            repeated_share=repeated / distance if distance else 0.0,
            finish=(float(self.net.node_lat[nodes[-1]]), float(self.net.node_lon[nodes[-1]])),
        )

    # ---------- round trips ----------

    def round_trips(self, lat: float, lon: float, distance_m: float, exposure: np.ndarray,
                    options: int = 3) -> list[RouteOption]:
        area = self.area(lat, lon, distance_m * 0.55)
        start = area.local[self.nearest_node(lat, lon)]
        positions = self.xy[area.node_ids]
        local_tree = cKDTree(positions)
        origin = np.array([lon * self.kx, lat * EARTH_M_PER_DEG])

        def snap(bearing: float, radius: float) -> int:
            b = radians(bearing)
            return int(local_tree.query(origin + radius * np.array([sin(b), cos(b)]))[1])

        found = []
        for style in ("cleanest", "direct"):
            base = self._weights(area, exposure, style)
            for bearing in range(0, 360, 30):
                for spread in (30, 50, 70):
                    for radius in distance_m * np.array([0.14, 0.17, 0.20, 0.23, 0.26, 0.30, 0.34]):
                        p1, p2 = snap(bearing - spread, radius), snap(bearing + spread, radius)
                        if len({start, p1, p2}) < 3:
                            continue
                        weights, route = base.copy(), [start]
                        for a, b in ((start, p1), (p1, p2), (p2, start)):
                            _, predecessors = area.tree(weights, a)
                            leg = area.path(predecessors, a, b)
                            if leg is None:
                                route = None
                                break
                            weights[area.edges_of(leg)] *= REUSE_PENALTY  # avoid running the same street again
                            route.extend(leg[1:])
                        if route is None:
                            continue
                        length = float(area.length[area.edges_of(route)].sum())
                        if abs(length - distance_m) <= TOLERANCE * distance_m:
                            found.append(self._describe(area, "loop", style, route, exposure))
        chosen = self._finalise(found, options)
        if len(chosen) < options:
            # Not enough distinct loops (for example hemmed in by a creek or the National
            # Park): top up with out-and-back runs along the cleanest way.
            chosen += self.out_and_back(lat, lon, distance_m, exposure, options)[: options - len(chosen)]
        return chosen

    def out_and_back(self, lat: float, lon: float, distance_m: float, exposure: np.ndarray,
                     options: int = 3) -> list[RouteOption]:
        """Run out half the distance along the cleanest way and come back the same way."""
        results = []
        for out in self.one_way(lat, lon, distance_m / 2, exposure, options):
            option = RouteOption(**{**out.__dict__})
            option.kind = "out_and_back"
            option.nodes = out.nodes + out.nodes[-2::-1]
            option.edges = out.edges + out.edges[::-1]
            option.distance_m = out.distance_m * 2
            option.repeated_share = 0.5
            option.finish = (float(self.net.node_lat[option.nodes[-1]]), float(self.net.node_lon[option.nodes[-1]]))
            results.append(option)
        return results

    # ---------- one way ----------

    def one_way(self, lat: float, lon: float, distance_m: float, exposure: np.ndarray,
                options: int = 3) -> list[RouteOption]:
        """Routes of about `distance_m` from the start to finishes chosen for clean air."""
        area = self.area(lat, lon, distance_m * 1.05)
        start = area.local[self.nearest_node(lat, lon)]
        found = []
        for style in ("cleanest", "direct"):
            costs, predecessors = area.tree(self._weights(area, exposure, style), start)
            lengths = area.lengths_along_tree(costs, predecessors, start)
            candidates = np.where(np.abs(lengths - distance_m) <= TOLERANCE * distance_m)[0]
            if len(candidates) == 0:
                continue
            delta = self.xy[area.node_ids[candidates]] - np.array([lon * self.kx, lat * EARTH_M_PER_DEG])
            bearings = np.degrees(np.arctan2(delta[:, 0], delta[:, 1])) % 360
            for sector in range(8):  # one finish per compass direction
                in_sector = candidates[(bearings >= sector * 45) & (bearings < (sector + 1) * 45)]
                if len(in_sector):
                    best = int(min(in_sector, key=lambda n: costs[n] / max(lengths[n], 1)))
                    nodes = area.path(predecessors, start, best)
                    if nodes:
                        found.append(self._describe(area, "one_way", style, nodes, exposure))
        return self._finalise(found, options)

    def to_places(self, lat: float, lon: float, distance_m: float, exposure: np.ndarray,
                  places: list[dict], options: int = 3) -> list[RouteOption]:
        """One-way routes of about `distance_m` that finish at one of `places`
        (each a dict with name, lat, lon), adding a detour when a place is too close."""
        area = self.area(lat, lon, distance_m * 1.05)
        start = area.local[self.nearest_node(lat, lon)]
        found = []
        for style in ("cleanest", "direct"):
            weights = self._weights(area, exposure, style)
            costs_a, pred_a = area.tree(weights, start)
            lengths_a = area.lengths_along_tree(costs_a, pred_a, start)
            for place in places:
                finish_global = self.nearest_node(place["lat"], place["lon"])
                if finish_global not in area.local:
                    continue
                finish = area.local[finish_global]
                direct = lengths_a[finish]
                if not np.isfinite(direct) or direct > distance_m * (1 + TOLERANCE):
                    continue  # too far to reach within the distance
                if direct >= distance_m * (1 - TOLERANCE):
                    nodes = area.path(pred_a, start, finish)
                else:
                    # Detour through a turning point W with start->W + W->finish close to the target.
                    costs_b, pred_b = area.tree(weights, finish)
                    lengths_b = area.lengths_along_tree(costs_b, pred_b, finish)
                    total = lengths_a + lengths_b
                    turning = np.where(np.abs(total - distance_m) <= TOLERANCE * distance_m)[0]
                    if len(turning) == 0:
                        continue
                    w = int(min(turning, key=lambda n: (costs_a[n] + costs_b[n]) / total[n]))
                    first, second = area.path(pred_a, start, w), area.path(pred_b, finish, w)
                    if not first or not second:
                        continue
                    nodes = first + second[::-1][1:]
                if nodes:
                    option = self._describe(area, "one_way", style, nodes, exposure)
                    option.extra["place"] = place
                    found.append(option)
        return self._finalise(found, options)

    # ---------- choosing and labelling ----------

    def _finalise(self, found: list[RouteOption], options: int) -> list[RouteOption]:
        clean = [o for o in found if o.style == "cleanest"]
        direct = [o for o in found if o.style == "direct"]
        # Lowest exposure first, with a penalty for streets run twice; keep options that differ.
        clean.sort(key=lambda o: o.mean_pm25 * (1 + 0.5 * o.repeated_share))
        chosen: list[RouteOption] = []
        for option in clean:
            edges = set(option.edges)
            if all(len(edges & set(c.edges)) / max(len(edges | set(c.edges)), 1) < 0.5 for c in chosen):
                chosen.append(option)
            if len(chosen) == options:
                break
        reference = float(np.median([o.mean_pm25 for o in direct])) if direct else None
        for option in chosen:
            if reference:
                option.cleaner_than_direct = max(0.0, 1 - option.mean_pm25 / reference)
            option.label = self._label(option)
        return chosen

    @staticmethod
    def _label(option: RouteOption) -> str:
        """A short plain description of the streets the route uses."""
        if option.main_road_share >= 0.4:
            return "Mostly main roads"
        if option.quiet_share >= 0.6:
            return "Mostly quiet streets"
        if option.main_road_share >= 0.15:
            return "Mixed, some main road"
        return "Quiet and medium roads"

    def shape(self, option: RouteOption) -> list[tuple[float, float]]:
        """The route's full line (latitude, longitude points), in running order."""
        points: list[tuple[float, float]] = []
        for a, edge in zip(option.nodes[:-1], option.edges):
            coords = self.net.edge_shape(edge).tolist()
            if self.net.edge_from[edge] != a:
                coords.reverse()
            points.extend(map(tuple, coords if not points else coords[1:]))
        return points


def steps(planner: Planner, option: RouteOption, exposure: np.ndarray) -> list[dict]:
    """The route as named stretches, merging consecutive segments of the same street:
    [{name, km_from, km, pm25, road}], in running order."""
    result: list[dict] = []
    done = 0.0
    for edge in option.edges:
        name = planner.net.street_name(edge) or "unnamed lane"
        length = float(planner.net.edge_length[edge]) / 1000
        road = ROAD_CLASS_NAMES[int(planner.net.edge_class[edge])]
        if result and result[-1]["name"] == name:
            last = result[-1]
            last["pm25"] = (last["pm25"] * last["km"] + float(exposure[edge]) * length) / (last["km"] + length)
            last["km"] += length
        else:
            result.append({"name": name, "km_from": done, "km": length, "pm25": float(exposure[edge]), "road": road})
        done += length
    return _merge_short(result)


def _merge_short(stretches: list[dict], shortest_km: float = 0.03) -> list[dict]:
    """Fold stretches under 30 m (crossings, slip lanes) into the previous one, then
    join neighbours that now share a name, so the list reads like real directions."""
    merged: list[dict] = []
    for stretch in stretches:
        if merged and (stretch["km"] < shortest_km or stretch["name"] == merged[-1]["name"]):
            last = merged[-1]
            last["pm25"] = (last["pm25"] * last["km"] + stretch["pm25"] * stretch["km"]) / (last["km"] + stretch["km"])
            last["km"] += stretch["km"]
        else:
            merged.append(dict(stretch))
    return merged


def google_maps_link(planner: Planner, option: RouteOption, waypoints: int = 8) -> str:
    """A Google Maps link that shows the route as a walking route through evenly spaced
    points, for checking it with street names and Street View (no key needed)."""
    shape = planner.shape(option)
    picks = [shape[round(i * (len(shape) - 1) / (waypoints + 1))] for i in range(1, waypoints + 1)]
    fmt = lambda p: f"{p[0]:.6f},{p[1]:.6f}"
    return ("https://www.google.com/maps/dir/?api=1&travelmode=walking"
            f"&origin={fmt(shape[0])}&destination={fmt(shape[-1])}&waypoints={'%7C'.join(fmt(p) for p in picks)}")


def road_mix(planner: Planner, option: RouteOption) -> dict[str, float]:
    """Kilometres of each road type on the route, for the app's summary."""
    lengths = planner.net.edge_length[option.edges]
    classes = planner.net.edge_class[option.edges]
    return {ROAD_CLASS_NAMES[c]: round(float(lengths[classes == c].sum()) / 1000, 2) for c in range(4)}
