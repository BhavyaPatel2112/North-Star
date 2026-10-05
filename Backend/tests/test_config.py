"""Checks that settings load without needing any secrets."""

from northstar import config


def test_paths_point_inside_backend():
    assert config.DATA_DIR.parent == config.BACKEND_DIR
    assert config.BACKEND_DIR.name == "Backend"


def test_mumbai_box_is_sensible():
    south, west, north, east = config.MUMBAI_BBOX
    assert south < 19.0 < north
    assert west < 72.85 < east
