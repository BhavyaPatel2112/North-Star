"""Compare Google, our model and raw CAMS against real station readings.

Google's Air Quality API keeps 30 days of hourly history. For the comparison
stations we fetch that history (counted by the spending guard), then line it
up with:
- what each station really measured (air_readings_hourly)
- our model's honest predictions for that station (from grouped station
  cross-validation: made by models that never saw the station)
- raw CAMS for the station's grid square

Run from the Backend folder:
    .venv/bin/python -m scripts.compare_google_history
"""

import json

import numpy as np
import pandas as pd
import requests

from northstar import config
from northstar.collect import google_aq
from northstar.db.connection import connect
from northstar.model.evaluate import band, ordering_accuracy, scores

HISTORY_URL = "https://airquality.googleapis.com/v1/history:lookup"
CACHE = config.RAW_DIR / "google_history.parquet"
OUR_PREDICTIONS = config.PROCESSED_DIR / "pm25_calibrated_predictions.parquet"


def fetch_history(conn, latitude: float, longitude: float, start: pd.Timestamp, end: pd.Timestamp) -> list[dict]:
    """Hourly PM2.5 and PM10 from Google between start and end, following pages."""
    rows, token = [], None
    while True:
        body = {
            "period": {"startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"), "endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ")},
            "location": {"latitude": latitude, "longitude": longitude},
            "extraComputations": ["POLLUTANT_CONCENTRATION"],
            "pageSize": 168,
        }
        if token:
            body["pageToken"] = token
        if google_aq.requests_this_month(conn) + 1 > google_aq.MONTHLY_LIMIT:
            raise RuntimeError("Monthly Google limit reached; stopping.")
        response = requests.post(HISTORY_URL, params={"key": config.GOOGLE_AIR_QUALITY_KEY}, json=body, timeout=60)
        google_aq._count(conn, 1)
        conn.commit()
        if response.status_code != 200:
            raise RuntimeError(f"Google history: HTTP {response.status_code}: {response.text[:150]}")
        data = response.json()
        for hour in data.get("hoursInfo", []):
            values = {p["code"]: p["concentration"]["value"] for p in hour.get("pollutants", [])}
            rows.append({"ts": pd.Timestamp(hour["dateTime"]), "google_pm25": values.get("pm25"),
                         "google_pm10": values.get("pm10")})
        token = data.get("nextPageToken")
        if not token:
            return rows


def main() -> None:
    with connect() as conn:
        stations = conn.execute(
            "select station_id, name, ST_Y(location::geometry), ST_X(location::geometry) from stations "
            "where station_id = any(%s)", (google_aq.STATION_POINTS,)
        ).fetchall()
        real_until = pd.Timestamp(conn.execute("select max(ts) from air_readings_hourly").fetchone()[0])
        start = (pd.Timestamp.now(tz="UTC") - pd.Timedelta(days=29, hours=20)).floor("h")

        if CACHE.exists():
            google = pd.read_parquet(CACHE)
        else:
            pieces = []
            for station_id, name, lat, lon in stations:
                rows = fetch_history(conn, lat, lon, start, real_until)
                frame = pd.DataFrame(rows)
                frame["station_id"] = station_id
                pieces.append(frame)
                print(f"  {name}: {len(frame)} hours from Google")
            google = pd.concat(pieces, ignore_index=True)
            google.to_parquet(CACHE, index=False)

        real = pd.DataFrame(conn.execute(
            "select a.station_id, a.ts, a.pm25, c.pm25 as cams from air_readings_hourly a "
            "join stations s using (station_id) join cams_hourly c on c.cell_id = s.cams_cell_id and c.ts = a.ts "
            "where a.ts >= %s and a.pm25 is not null and (a.qc_flags %% 2) = 0", (start,)
        ).fetchall(), columns=["station_id", "ts", "pm25", "cams"])
        used = google_aq.requests_this_month(conn)

    ours = pd.read_parquet(OUR_PREDICTIONS)[["station_id", "ts", "cal"]].rename(columns={"cal": "ours"})
    for frame in (google, real, ours):
        frame["ts"] = pd.to_datetime(frame.ts, utc=True)
        frame["station_id"] = frame.station_id.astype(int)
    data = real.merge(google, on=["station_id", "ts"]).merge(ours, on=["station_id", "ts"], how="left")
    data = data.dropna(subset=["pm25", "google_pm25", "cams"])
    data["day"] = data.ts.dt.tz_convert("Asia/Kolkata").dt.date
    data["hour_ist"] = data.ts.dt.tz_convert("Asia/Kolkata").dt.hour
    both = data.dropna(subset=["ours"])

    print(f"\n{len(both):,} station-hours with real readings, Google, CAMS and our model "
          f"({both.ts.min():%d %b} to {both.ts.max():%d %b}, {both.station_id.nunique()} stations). "
          f"Google requests this month: {used:,}")
    actual = both.pm25.to_numpy()
    table = {}
    for name, column in (("Google", "google_pm25"), ("Our model", "ours"), ("Raw CAMS", "cams")):
        predicted = both[column].to_numpy()
        s = scores(actual, predicted, "pm25")
        table[name] = {
            "typical error": round(s["mae"], 1), "bias": round(s["bias"], 1),
            "right band": f"{s['band_exact']:.0%}", "within 1 band": f"{s['band_within_one']:.0%}",
            "follows ups and downs (corr.)": round(float(np.corrcoef(actual, predicted)[0, 1]), 2),
            "best hour": f"{ordering_accuracy(both, 'pm25', column, 'ts', ['station_id', 'day'], 10):.0%}",
            "cleaner place": f"{ordering_accuracy(both, 'pm25', column, 'station_id', ['ts'], 10):.0%}",
        }
    print(pd.DataFrame(table).T.to_string())

    print("\nAverage by hour of day (India time), all stations:")
    profile = both.groupby("hour_ist")[["pm25", "google_pm25", "ours", "cams"]].mean().round(0)
    profile.columns = ["real", "Google", "ours", "CAMS"]
    print(profile.loc[[0, 3, 6, 9, 12, 15, 18, 21]].to_string())

    blend = (both.google_pm25 + both.ours) / 2
    s = scores(actual, blend.to_numpy(), "pm25")
    print(f"\nAverage of Google and ours: typical error {s['mae']:.1f}, right band {s['band_exact']:.0%}")
    (config.PROCESSED_DIR / "google_comparison.json").write_text(json.dumps(table, indent=1))


if __name__ == "__main__":
    main()
