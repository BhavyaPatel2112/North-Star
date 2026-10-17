"""Park loops for "Park laps": laps of a nearby park as part (or all) of a run.

The loops are found once by scripts.build_park_loops and saved in
data/processed/park_loops.json as junction numbers on the street network. For a
request, the planner looks for loops within a short run of the start (straight
line first, then by street), and builds a route: the way there, the laps, and the
way back (or the finish, for one-way runs).
"""

import json
from math import cos, radians, sqrt

from northstar import config

PARK_LOOPS_FILE = config.PROCESSED_DIR / "park_loops.json"
MAX_APPROACH_M = 1500   # a park counts as "nearby" up to 1.5 km from the start (straight line)
EARTH_M_PER_DEG = 111_320.0


def load() -> list[dict]:
    """All park loops: [{name, lat, lon, length_m, green_share, nodes}]. Empty if not built."""
    if not PARK_LOOPS_FILE.exists():
        return []
    return json.loads(PARK_LOOPS_FILE.read_text())


def nearby(loops: list[dict], lat: float, lon: float, reach_m: float = MAX_APPROACH_M) -> list[dict]:
    """Loops whose middle is within `reach_m` of a point (straight line), nearest first."""
    kx = cos(radians(lat)) * EARTH_M_PER_DEG
    found = []
    for loop in loops:
        straight = sqrt(((loop["lon"] - lon) * kx) ** 2 + ((loop["lat"] - lat) * EARTH_M_PER_DEG) ** 2)
        # Measured to the middle of the park, so allow for its own size.
        if straight - loop["length_m"] / 6 <= reach_m:
            found.append((straight, loop))
    return [loop for _, loop in sorted(found, key=lambda item: item[0])]
