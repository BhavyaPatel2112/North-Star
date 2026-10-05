"""Opening a connection to the Supabase PostgreSQL database."""

import psycopg

from northstar import config


def connect() -> psycopg.Connection:
    """Return a new database connection using DATABASE_URL from .env.

    Use it in a "with" block so the connection is committed and closed
    automatically:

        with connect() as conn:
            conn.execute("select 1")
    """
    return psycopg.connect(config.require("DATABASE_URL"), connect_timeout=10)
