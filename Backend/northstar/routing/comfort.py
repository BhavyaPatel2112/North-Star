"""How a run will feel: "feels like" temperature, and a score that balances air and heat.

In Mumbai the cleanest air is often in the early afternoon, which is also the
hottest, most humid part of the day. A good time to run needs both.

- feels_like_c: the heat index (how hot it feels once humidity is counted), with
  the US National Weather Service formula (Rothfusz regression), in Celsius. Below
  about 27 °C humidity matters little and the air temperature is used.
- run_score: lower is better. Each band of worse air (about 30 µg/m³ of PM2.5)
  counts the same as each 3 °C of "feels like" above 27 °C.
"""

COMFORTABLE_C = 27.0     # up to here, heat does not count against a time
DEGREES_PER_BAND = 3.0   # 3 °C of "feels like" costs as much as one air band
PM25_PER_BAND = 30.0


def feels_like_c(temperature_c: float, humidity: float) -> float:
    """Heat index in °C from air temperature (°C) and relative humidity (%)."""
    t = temperature_c * 9 / 5 + 32
    rh = humidity
    simple = 0.5 * (t + 61 + (t - 68) * 1.2 + rh * 0.094)
    if (simple + t) / 2 < 80:
        f = simple
    else:
        f = (-42.379 + 2.04901523 * t + 10.14333127 * rh - 0.22475541 * t * rh - 0.00683783 * t * t
             - 0.05481717 * rh * rh + 0.00122874 * t * t * rh + 0.00085282 * t * rh * rh
             - 0.00000199 * t * t * rh * rh)
        if rh < 13 and 80 <= t <= 112:
            f -= (13 - rh) / 4 * ((17 - abs(t - 95)) / 17) ** 0.5
        elif rh > 85 and 80 <= t <= 87:
            f += (rh - 85) / 10 * (87 - t) / 5
    return round((f - 32) * 5 / 9, 1)


def run_score(pm25: float, feels_like: float | None) -> float:
    """Lower is better: air bands plus heat bands above a comfortable 27 °C."""
    heat = 0.0 if feels_like is None else max(0.0, feels_like - COMFORTABLE_C) / DEGREES_PER_BAND
    return pm25 / PM25_PER_BAND + heat
