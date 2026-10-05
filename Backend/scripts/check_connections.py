"""Check that the secrets in .env work, without printing them.

Run from the Backend folder:
    .venv/bin/python -m scripts.check_connections
"""

import psycopg
import requests

from northstar import config


def check_database() -> bool:
    """Connect to Supabase, report the PostgreSQL version and whether PostGIS is available."""
    print("Database (Supabase):")
    try:
        url = config.require("DATABASE_URL")
        with psycopg.connect(url, connect_timeout=10) as conn:
            version = conn.execute("SHOW server_version").fetchone()[0]
            print(f"  OK, connected. PostgreSQL {version}")

            installed = conn.execute(
                "SELECT extversion FROM pg_extension WHERE extname = 'postgis'"
            ).fetchone()
            available = conn.execute(
                "SELECT 1 FROM pg_available_extensions WHERE name = 'postgis'"
            ).fetchone()
            if installed:
                print(f"  OK, PostGIS {installed[0]} is enabled")
            elif available:
                print("  PostGIS is available but not enabled yet (we will enable it)")
            else:
                print("  WARNING: PostGIS is not available on this database")
        return True
    except Exception as error:
        # Show only the error type and message; psycopg does not include the password.
        print(f"  FAILED: {type(error).__name__}: {error}")
        return False


def check_openaq() -> bool:
    """Ask OpenAQ for monitoring stations inside the Mumbai box."""
    print("OpenAQ:")
    try:
        key = config.require("OPENAQ_API_KEY")
        south, west, north, east = config.MUMBAI_BBOX
        response = requests.get(
            "https://api.openaq.org/v3/locations",
            params={"bbox": f"{west},{south},{east},{north}", "limit": 1000},
            headers={"X-API-Key": key},
            timeout=20,
        )
        if response.status_code == 401:
            print("  FAILED: OpenAQ rejected the API key (401 Unauthorized)")
            return False
        response.raise_for_status()
        stations = response.json()["results"]
        print(f"  OK, key accepted. {len(stations)} monitoring locations found in Mumbai")
        return True
    except Exception as error:
        print(f"  FAILED: {type(error).__name__}: {error}")
        return False


if __name__ == "__main__":
    results = [check_database(), check_openaq()]
    print("\nAll good." if all(results) else "\nSomething needs fixing (see above).")
