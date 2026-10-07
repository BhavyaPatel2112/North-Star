"""Check planned routes against Google's walking directions.

For each planned route we ask Google's Routes API for a walking route through
the same points (start, up to 10 evenly spaced points along our route, and the
finish), then compare:
- distance: Google's walking distance against ours
- overlap: the share of our route that lies within 25 m of Google's line

If Google needs a much longer way round, or follows little of our line, our
route probably uses something that cannot really be walked through (a gated
lane, a highway without a footpath, a railway crossing that does not exist).

Uses basic walking routes with at most 10 intermediate points, billed as
Routes "Essentials" (70,000 free a month with an Indian billing account),
counted by the spending guard in api_usage (shared with the server,
see northstar/routing/walk_check.py).

Run from the Backend folder:
    .venv/bin/python -m scripts.validate_routes_google
"""

import numpy as np
import pandas as pd

from northstar import config
from northstar.db.connection import connect
from northstar.routing.network import StreetNetwork
from northstar.routing.planner import Planner
from northstar.routing.walk_check import budget_left, google_walk, overlap

STARTS = {
    "Thakur Village, Kandivali East": (19.2105, 72.8740),
    "Dadar West": (19.0178, 72.8420),
    "Powai": (19.1197, 72.9050),
    "Chembur": (19.0622, 72.9005),
    "Vashi": (19.0771, 72.9986),
    "Malad West": (19.1868, 72.8484),
}


def main() -> None:
    planner = Planner(StreetNetwork.load())
    with connect() as conn:
        now = pd.Timestamp.now(tz="UTC").floor("h")
        cells = {int(h): float(v) for h, v in conn.execute(
            "select h3, pm25 from grid_predictions where ts = %s", (now,)).fetchall()}
        exposure = planner.edge_exposure(cells, float(np.median(list(cells.values()))))
        rows = []
        for name, (lat, lon) in STARTS.items():
            for kind, plan in (("loop", planner.round_trips), ("one way", planner.one_way)):
                for i, option in enumerate(plan(lat, lon, 5000, exposure)):
                    shape = planner.shape(option)
                    if not budget_left(conn):
                        raise RuntimeError("Google Routes limit reached; stopping.")
                    distance, google_line = google_walk(conn, shape)
                    walkable = bool(google_line)
                    rows.append({
                        "start": name, "kind": option.kind, "option": i + 1,
                        "ours_km": round(option.distance_m / 1000, 2), "google_km": round(distance / 1000, 2),
                        "ratio": round(distance / option.distance_m, 2),
                        "overlap": round(overlap(shape, google_line), 2) if walkable else 0.0,
                        "google_found_route": walkable,
                    })
    table = pd.DataFrame(rows)
    table["flag"] = np.where(~table.google_found_route, "NO WALK ROUTE",
                             np.where((table.ratio > 1.15) | (table.overlap < 0.8), "CHECK", "ok"))
    print(table.to_string(index=False))
    print(f"\n{(table.flag == 'ok').mean():.0%} of routes pass "
          f"(median Google/ours distance {table.ratio.median():.2f}, median overlap {table.overlap.median():.0%})")
    (config.PROCESSED_DIR / "route_validation.json").write_text(table.to_json(orient="records", indent=1))


if __name__ == "__main__":
    main()
