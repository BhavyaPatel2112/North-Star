"""The elevation profile of a route: how high the ground is as you run it.

Heights come from the street network (scripts.add_elevation stored the height
of every junction, from NASA's 30 m SRTM terrain model). Along a route we:
1. take the height at each junction, placed by distance from the start;
2. resample every 25 m and smooth over about 200 m, because terrain data in a
   dense city has small bumps (buildings, embankments) that are not
   real climbs (the model measures the surface, buildings included);
3. count climb and descent only when the ground has moved by at least 2 m
   since the last turning point, so tiny wobbles do not add up to fake metres.

The app draws the profile under the route's slider and shows the totals.
"""

import numpy as np

STEP_M = 25.0          # resample every 25 m
SMOOTH_M = 200.0       # moving average window
THRESHOLD_M = 2.0      # ignore ups and downs smaller than this
MAX_POINTS = 120       # points sent to the app


def profile(network, nodes: list[int], edges: list[int]) -> dict | None:
    """Distance (km) and height (m) along the route, plus climb, descent, lowest and highest."""
    heights = getattr(network, "node_elev", None)
    if heights is None or len(nodes) < 2:
        return None
    lengths = network.edge_length[edges].astype(np.float64)
    distance = np.concatenate([[0.0], np.cumsum(lengths)])
    raw = heights[nodes].astype(np.float64)
    total = float(distance[-1])
    if total <= 0:
        return None

    samples = np.arange(0.0, total + STEP_M, STEP_M)
    samples[-1] = min(samples[-1], total)
    resampled = np.interp(samples, distance, raw)
    window = max(1, int(round(SMOOTH_M / STEP_M)))
    if window > 1 and len(resampled) > window:
        pad = window // 2
        padded = np.pad(resampled, pad, mode="edge")
        smooth = np.convolve(padded, np.ones(window) / window, mode="valid")[: len(resampled)]
    else:
        smooth = resampled

    climb = descent = 0.0
    anchor = smooth[0]
    for h in smooth[1:]:
        change = h - anchor
        if change >= THRESHOLD_M:
            climb += change
            anchor = h
        elif change <= -THRESHOLD_M:
            descent -= change
            anchor = h

    pick = np.linspace(0, len(samples) - 1, min(MAX_POINTS, len(samples))).round().astype(int)
    return {
        "points": [[round(float(samples[i]) / 1000, 3), round(float(smooth[i]), 1)] for i in pick],
        "climb_m": round(climb),
        "descent_m": round(descent),
        "min_m": round(float(smooth.min())),
        "max_m": round(float(smooth.max())),
    }
