"""Predict every hexagon for the coming hours and save to the database.

Run from the Backend folder (needs trained models in Backend/models):
    .venv/bin/python -m scripts.predict_grid
"""

from northstar.db.connection import connect
from northstar.model.predict import predict_grid


def main() -> None:
    with connect() as conn:
        print(predict_grid(conn))


if __name__ == "__main__":
    main()
