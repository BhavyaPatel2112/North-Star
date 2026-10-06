"""Writing hourly pollution readings to the database.

Used by the historical load now and by the hourly collector later.
"""

import pandas as pd
import psycopg

from northstar.clean.openaq import POLLUTANTS
from northstar.db.upsert import upsert_frame

COLUMNS = ["station_id", "ts", *POLLUTANTS, "qc_flags", "source_id"]


def upsert_air_readings(conn: psycopg.Connection, frame: pd.DataFrame) -> int:
    """Insert station-hours, replacing any existing row for the same station and hour."""
    return upsert_frame(conn, "air_readings_hourly", frame.reindex(columns=COLUMNS), ["station_id", "ts"])


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
