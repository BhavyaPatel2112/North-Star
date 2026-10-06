"""Create the database tables and load the station list.

Safe to run again: tables are only created if missing, and stations are
updated in place.

Run from the Backend folder:
    .venv/bin/python -m scripts.create_tables
"""

from pathlib import Path

import pandas as pd

from northstar.db.connection import connect

SCHEMA_FILE = Path(__file__).resolve().parent.parent / "northstar" / "db" / "schema.sql"
STATIONS_FILE = Path(__file__).resolve().parent.parent / "northstar" / "collect" / "stations.csv"
OPENAQ_SOURCE_ID = 1


def main() -> None:
    stations = pd.read_csv(STATIONS_FILE, dtype={"openaq_location_ids": str})

    with connect() as conn:
        conn.execute(SCHEMA_FILE.read_text())

        for row in stations.itertuples():
            # ST_MakePoint takes longitude first, then latitude.
            conn.execute(
                """
                insert into stations (station_id, name, operator, location, notes)
                values (%s, %s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
                on conflict (station_id) do update set
                    name = excluded.name,
                    operator = excluded.operator,
                    location = excluded.location,
                    notes = excluded.notes
                """,
                (row.station_id, row.name, row.operator, row.longitude, row.latitude,
                 None if pd.isna(row.notes) else row.notes),
            )
            for location_id in row.openaq_location_ids.split(";"):
                conn.execute(
                    """
                    insert into station_sources (source_id, source_location_id, station_id)
                    values (%s, %s, %s)
                    on conflict (source_id, source_location_id) do update
                        set station_id = excluded.station_id
                    """,
                    (OPENAQ_SOURCE_ID, location_id.strip(), row.station_id),
                )

        count = conn.execute("select count(*) from stations").fetchone()[0]
        links = conn.execute("select count(*) from station_sources where source_id = %s", (OPENAQ_SOURCE_ID,)).fetchone()[0]
        print(f"Tables ready. {count} stations, {links} OpenAQ ids linked.")


if __name__ == "__main__":
    main()
