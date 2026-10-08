"""Checks for choosing stations to end a run at (northstar/routing/stations.py)."""

from northstar.routing import stations

BANDSTAND = (19.0457, 72.8194)
STATIONS = [
    {"name": "Bandra", "mode": "train", "lat": 19.0550, "lon": 72.8402},        # about 2.4 km away
    {"name": "Khar Road", "mode": "train", "lat": 19.0682, "lon": 72.8400},     # about 3.3 km away
    {"name": "Dadar", "mode": "metro", "lat": 19.0190, "lon": 72.8430},         # about 3.9 km, across the creek
    {"name": "Andheri", "mode": "metro", "lat": 19.1197, "lon": 72.8464},       # about 8.6 km away
    {"name": "Next door", "mode": "train", "lat": 19.0460, "lon": 72.8196},     # at the start
]


def test_labels_name_the_kind_of_station():
    assert stations.label({"name": "Bandra", "mode": "train"}) == "Bandra station"
    assert stations.label({"name": "Worli", "mode": "metro"}) == "Worli metro station"
    assert stations.label({"name": "Wadala Depot", "mode": "monorail"}) == "Wadala Depot monorail station"
    assert stations.label({"name": "Mumbai Central Station", "mode": "train"}) == "Mumbai Central Station"


def test_within_reach_skips_the_start_and_far_stations():
    near = stations.within_reach(STATIONS, *BANDSTAND, distance_m=5000)
    assert [s["name"] for s in near] == ["Bandra", "Khar Road", "Dadar"]


def test_candidates_use_street_distance_not_straight_lines():
    near = stations.within_reach(STATIONS, *BANDSTAND, distance_m=5000)
    # Dadar is close in a straight line but 7 km by street (round Mahim Creek): dropped.
    street_m = [2900.0, 4950.0, 7000.0]
    chosen = stations.candidates(near, street_m, distance_m=5000)
    assert [c["name"] for c in chosen] == ["Khar Road station", "Bandra station"]
    # Khar Road needs no detour, so it comes first; every candidate is marked as a station.
    assert all(c["kind"] == "station" for c in chosen)
    assert chosen[0]["street_km"] == 4.95


def test_unreachable_stations_are_dropped():
    near = stations.within_reach(STATIONS, *BANDSTAND, distance_m=5000)
    chosen = stations.candidates(near, [float("inf")] * len(near), distance_m=5000)
    assert chosen == []


def test_station_list_is_built():
    # The committed list the server loads: train, metro and monorail stations, with names.
    loaded = stations.load()
    assert len(loaded) > 150
    assert {s["mode"] for s in loaded} == {"train", "metro", "monorail"}
    assert all(s["name"] and 18.8 < s["lat"] < 19.4 and 72.7 < s["lon"] < 73.2 for s in loaded)
