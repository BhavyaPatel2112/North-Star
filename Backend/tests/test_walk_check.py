from northstar.routing import walk_check
from northstar.routing.walk_check import decode_polyline, overlap
from northstar.server.forecast import best_start


def test_decode_polyline_matches_googles_example():
    # Example from Google's polyline documentation.
    points = decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    assert points == [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]


def test_overlap_full_and_none():
    line = [(19.0, 72.80), (19.0, 72.81)]
    ours = [(19.0, 72.80 + i * 0.001) for i in range(11)]
    assert overlap(ours, line) == 1.0
    far = [(19.01, 72.80 + i * 0.001) for i in range(11)]  # about 1.1 km north
    assert overlap(far, line) == 0.0


def test_best_start_skips_night_hours():
    hours = [{"time": "2026-10-08T03:30:00+05:30", "pm25": 10},
             {"time": "2026-10-08T06:30:00+05:30", "pm25": 30},
             {"time": "2026-10-08T15:30:00+05:30", "pm25": 25}]
    assert best_start(hours)["pm25"] == 25


def test_long_routes_are_checked_in_pieces():
    # A straight 21 km line north: 3 pieces of about 7 km that join end to end.
    shape = [(19.0 + i * 0.001, 72.85) for i in range(190)]   # about 111 m apart
    pieces = walk_check.pieces_of(shape, 21_000)
    assert len(pieces) == 3
    assert pieces[0][0] == shape[0] and pieces[-1][-1] == shape[-1]
    assert all(pieces[k][-1] == pieces[k + 1][0] for k in range(2))
    # Short routes stay in one piece (one Google request).
    assert walk_check.pieces_of(shape[:40], 4_300) == [shape[:40]]
