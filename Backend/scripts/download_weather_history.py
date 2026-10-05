"""Match stations to Open-Meteo grid squares, download their weather history,
and load it into the database.

Run from the Backend folder (safe to re-run):
    .venv/bin/python -m scripts.download_weather_history
"""

from datetime import date

import pandas as pd

from northstar.collect.open_meteo import VARIABLES, cell_dir, download_cells, find_cells
from northstar.db.connection import connect

START_DATE = date(2019, 6, 1)
COLUMNS = ["cell_id", "ts", *VARIABLES.values()]


def main() -> None:
    with connect() as conn:
        stations = conn.execute(
            "select station_id, ST_Y(location::geometry), ST_X(location::geometry) "
            "from stations order by station_id"
        ).fetchall()

        # 1. Find each station's grid square and save the squares.
        found = find_cells([s[1] for s in stations], [s[2] for s in stations])
        unique = sorted({(lat, lon): elev for lat, lon, elev in found}.items())
        print(f"{len(stations)} stations fall in {len(unique)} weather grid squares")

        for (lat, lon), elevation in unique:
            conn.execute(
                """
                insert into weather_cells (cell_id, location, elevation_m)
                values (
                    coalesce((select max(cell_id) from weather_cells), 0) + 1,
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
                on conflict (location) do nothing
                """,
                (lon, lat, elevation),
            )
        cell_ids = {
            (round(lat, 4), round(lon, 4)): cell_id
            for cell_id, lat, lon in conn.execute(
                "select cell_id, ST_Y(location::geometry), ST_X(location::geometry) from weather_cells"
            ).fetchall()
        }
        for (station_id, _, _), (lat, lon, _) in zip(stations, found):
            conn.execute(
                "update stations set weather_cell_id = %s where station_id = %s",
                (cell_ids[(round(lat, 4), round(lon, 4))], station_id),
            )
        conn.commit()

        # 2. Download the weather files.
        download_cells([cell for cell, _ in unique], START_DATE)

        # 3. Load into weather_hourly. COPY into a temporary table, then upsert,
        #    so re-runs update existing hours instead of creating duplicates.
        for (lat, lon), _ in unique:
            frame = pd.concat(pd.read_parquet(p) for p in sorted(cell_dir(lat, lon).glob("*.parquet")))
            frame["cell_id"] = cell_ids[(round(lat, 4), round(lon, 4))]
            frame = frame[COLUMNS]
            conn.execute("create temporary table if not exists weather_load (like weather_hourly)")
            conn.execute("truncate weather_load")
            with conn.cursor().copy(f"copy weather_load ({', '.join(COLUMNS)}) from stdin") as copy:
                for row in frame.itertuples(index=False):
                    copy.write_row([None if pd.isna(v) else v for v in row])
            updates = ", ".join(f"{c} = excluded.{c}" for c in COLUMNS[2:])
            conn.execute(
                f"insert into weather_hourly select * from weather_load "
                f"on conflict (cell_id, ts) do update set {updates}"
            )
            conn.commit()
            print(f"  loaded {len(frame)} hours for cell {lat:.4f},{lon:.4f}")

        rows = conn.execute("select count(*) from weather_hourly").fetchone()[0]
        size = conn.execute("select pg_size_pretty(pg_total_relation_size('weather_hourly'))").fetchone()[0]
        print(f"weather_hourly: {rows} rows, {size}")


if __name__ == "__main__":
    main()
