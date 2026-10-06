"""Rebuild the training table from the database and train all models.

Run from the Backend folder:
    .venv/bin/python -m scripts.train_models
"""

from northstar.db.connection import connect
from northstar.model.dataset import TRAINING_FILE, load_station_rows
from northstar.model.train import MODELS_DIR, train_all


def main() -> None:
    with connect() as conn:
        training = load_station_rows(conn)
        place_columns = list(conn.execute("select features from station_features limit 1").fetchone()[0])
    TRAINING_FILE.parent.mkdir(parents=True, exist_ok=True)
    training.to_parquet(TRAINING_FILE, index=False)
    print(f"Training table: {len(training):,} station-hours")
    for target, info in train_all(training, place_columns).items():
        size = (MODELS_DIR / f"{target}.joblib").stat().st_size / 1e6
        print(f"  {target}: {info['rows']:,} hours from {info['stations']} stations, "
              f"data until {info['data_until']:%Y-%m-%d}, file {size:.1f} MB")


if __name__ == "__main__":
    main()
