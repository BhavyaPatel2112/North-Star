"""Checks for "feels like" and the air-and-heat score (northstar/routing/comfort.py)."""

from northstar.routing.comfort import feels_like_c, run_score


def test_feels_like_matches_published_heat_index():
    # US National Weather Service table: 32 °C (90 °F) at 70% humidity feels like about 41 °C (106 °F).
    assert 40 <= feels_like_c(32, 70) <= 42
    # Mild air: humidity barely matters.
    assert abs(feels_like_c(22, 60) - 22) <= 1.5


def test_heat_can_outweigh_cleaner_air():
    early = run_score(pm25=60, feels_like=28)      # hazier but cool
    afternoon = run_score(pm25=40, feels_like=38)   # cleaner but sweltering
    assert early < afternoon


def test_no_weather_means_air_only():
    assert run_score(45, None) == 45 / 30
