"""Settings shared by the whole backend.

Secrets (database password, API keys) are never written in the code.
They live in a file called .env next to this project, which Git ignores.
This module reads that file once and exposes the values as constants.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

# Backend/ folder (this file is Backend/northstar/config.py).
BACKEND_DIR = Path(__file__).resolve().parent.parent

# Load Backend/.env into environment variables. Values already set in the
# environment (for example on a cloud server) take priority over the file.
load_dotenv(BACKEND_DIR / ".env")

# Local folder for downloaded and intermediate files. Ignored by Git
# because it will grow to gigabytes; the cleaned data lives in the database.
DATA_DIR = BACKEND_DIR / "data"
RAW_DIR = DATA_DIR / "raw"
PROCESSED_DIR = DATA_DIR / "processed"

# Secrets. They are None if missing, so code that does not need them still runs.
DATABASE_URL = os.getenv("DATABASE_URL")
OPENAQ_API_KEY = os.getenv("OPENAQ_API_KEY")
DATAGOVIN_API_KEY = os.getenv("DATAGOVIN_API_KEY")
WAQI_TOKEN = os.getenv("WAQI_TOKEN")

# Rough box around Mumbai (south, west, north, east) in degrees, used to
# limit downloads to the city.
MUMBAI_BBOX = (18.85, 72.75, 19.35, 73.10)


def require(name: str) -> str:
    """Return a secret by name, or stop with a clear message if it is not set."""
    value = os.getenv(name)
    if not value:
        raise RuntimeError(
            f"{name} is not set. Copy Backend/.env.example to Backend/.env and fill it in."
        )
    return value
