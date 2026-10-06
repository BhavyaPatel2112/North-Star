"""Fast insert-or-update of a pandas table into any database table."""

import pandas as pd
import psycopg


def upsert_frame(conn: psycopg.Connection, table: str, frame: pd.DataFrame, key: list[str]) -> int:
    """Write `frame` into `table`, replacing rows that have the same `key`.

    Rows are streamed into a temporary copy of the table with COPY (much
    faster than one insert per row), then merged in one statement. Running
    it twice with the same data changes nothing, so there are no duplicates.
    The frame's column names must match the table's column names.
    """
    columns = list(frame.columns)
    staging = f"{table}_staging"
    # "including defaults" so columns we do not send (such as fetched_at) get their default value.
    conn.execute(f"create temporary table if not exists {staging} (like {table} including defaults)")
    conn.execute(f"truncate {staging}")
    with conn.cursor().copy(f"copy {staging} ({', '.join(columns)}) from stdin") as copy:
        for row in frame.itertuples(index=False):
            copy.write_row([None if pd.isna(v) else v for v in row])

    updates = ", ".join(f"{c} = excluded.{c}" for c in columns if c not in key)
    conn.execute(
        f"insert into {table} ({', '.join(columns)}) "
        f"select {', '.join(columns)} from {staging} "
        f"on conflict ({', '.join(key)}) do update set {updates}"
    )
    return len(frame)
