"""Writing hourly pollution readings to the database.

Used by the historical load now and by the hourly collector later.
"""

import pandas as pd
import psycopg

from northstar.clean.openaq import POLLUTANTS

COLUMNS = ["station_id", "ts", *POLLUTANTS, "qc_flags", "source_id"]


def upsert_air_readings(conn: psycopg.Connection, frame: pd.DataFrame) -> int:
    """Insert station-hours, replacing any existing row for the same station and hour.

    The rows are first streamed into a temporary table with COPY (much faster
    than one insert per row), then merged into air_readings_hourly in one
    statement. Re-running with the same data changes nothing, so there are
    never duplicates.
    """
    frame = frame.reindex(columns=COLUMNS)
    conn.execute("create temporary table if not exists air_load (like air_readings_hourly)")
    conn.execute("truncate air_load")
    with conn.cursor().copy(f"copy air_load ({', '.join(COLUMNS)}) from stdin") as copy:
        for row in frame.itertuples(index=False):
            copy.write_row([None if pd.isna(v) else v for v in row])

    updates = ", ".join(f"{c} = excluded.{c}" for c in COLUMNS[2:])
    conn.execute(
        f"insert into air_readings_hourly ({', '.join(COLUMNS)}) "
        f"select {', '.join(COLUMNS)} from air_load "
        f"on conflict (station_id, ts) do update set {updates}"
    )
    return len(frame)


def refresh_station_dates(conn: psycopg.Connection, active_within_days: int = 7) -> None:
    """Update each station's first and last reading, and mark stations that
    have not reported for `active_within_days` days as inactive."""
    conn.execute(
        """
        update stations s set
            first_reading = r.first_ts,
            last_reading = r.last_ts,
            is_active = r.last_ts > now() - make_interval(days => %s)
        from (
            select station_id, min(ts) as first_ts, max(ts) as last_ts
            from air_readings_hourly group by station_id
        ) r
        where s.station_id = r.station_id
        """,
        (active_within_days,),
    )
