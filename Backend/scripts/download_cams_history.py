"""Match stations to CAMS grid squares, download CAMS history and load it.

Run from the Backend folder (safe to re-run):
    .venv/bin/python -m scripts.download_cams_history
"""

from northstar.collect import cams
from northstar.db.connection import connect
from northstar.db.upsert import upsert_frame

COLUMNS = ["cell_id", "ts", *cams.VARIABLES.values()]


def main() -> None:
    with connect() as conn:
        stations = conn.execute(
            "select station_id, ST_Y(location::geometry), ST_X(location::geometry) "
            "from stations order by station_id"
        ).fetchall()

        # 1. Find each station's CAMS grid square and save the squares.
        found = cams.find_cells([s[1] for s in stations], [s[2] for s in stations])
        unique = sorted(set(found))
        print(f"{len(stations)} stations fall in {len(unique)} CAMS grid squares")
        for lat, lon in unique:
            conn.execute(
                """
                insert into cams_cells (cell_id, location)
                values (coalesce((select max(cell_id) from cams_cells), 0) + 1,
                        ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography)
                on conflict (location) do nothing
                """,
                (lon, lat),
            )
        cell_ids = {
            (round(lat, 4), round(lon, 4)): cell_id
            for cell_id, lat, lon in conn.execute(
                "select cell_id, ST_Y(location::geometry), ST_X(location::geometry) from cams_cells"
            ).fetchall()
        }
        for (station_id, _, _), (lat, lon) in zip(stations, found):
            conn.execute(
                "update stations set cams_cell_id = %s where station_id = %s",
                (cell_ids[(round(lat, 4), round(lon, 4))], station_id),
            )
        conn.commit()

        # 2. Download and load each square's history.
        end = cams.recent_end()
        for lat, lon in unique:
            frame = cams.download_history(lat, lon, end)
            frame["cell_id"] = cell_ids[(round(lat, 4), round(lon, 4))]
            upsert_frame(conn, "cams_hourly", frame[COLUMNS], ["cell_id", "ts"])
            conn.commit()
            print(f"  cell {lat:.4f},{lon:.4f}: {len(frame):,} hours "
                  f"({frame.ts.min():%Y-%m-%d} to {frame.ts.max():%Y-%m-%d})")

        rows = conn.execute("select count(*) from cams_hourly").fetchone()[0]
        size = conn.execute("select pg_size_pretty(pg_total_relation_size('cams_hourly'))").fetchone()[0]
        total = conn.execute("select pg_size_pretty(pg_database_size(current_database()))").fetchone()[0]
        print(f"cams_hourly: {rows:,} rows, {size}. Whole database: {total} of 500 MB.")


if __name__ == "__main__":
    main()
