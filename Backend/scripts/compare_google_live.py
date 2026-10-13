"""A fair comparison: Google, our model and raw CAMS, as each stood live, against stations.

Every hour the collector saves Google's current PM2.5 at 19 station points next to
our own live forecast for that hexagon and hour (google_readings: pm25 = Google,
model_pm25 = ours). Station readings arrive days later (OpenAQ runs late), so once
they cover those hours we can score all three on exactly the same station-hours,
using only what each source said at the time. Nothing here was trained on those
hours, so unlike scripts.compare_google_history (which used back-tested
predictions) there is no leak. No Google requests are made.

Run from the Backend folder:
    .venv/bin/python -m scripts.compare_google_live
"""

import json

import numpy as np
import pandas as pd

from northstar import config
from northstar.db.connection import connect
from northstar.model.evaluate import ordering_accuracy, scores

OUT = config.PROCESSED_DIR / "google_comparison_live.json"


def main() -> None:
    with connect() as conn:
        rows = conn.execute(
            "select g.station_id, g.ts, a.pm25, g.pm25 as google, g.model_pm25 as ours, c.pm25 as cams "
            "from google_readings g "
            "join air_readings_hourly a on a.station_id = g.station_id and a.ts = g.ts "
            "join stations s on s.station_id = g.station_id "
            "join cams_hourly c on c.cell_id = s.cams_cell_id and c.ts = g.ts "
            "where g.station_id is not null and a.pm25 is not null and (a.qc_flags % 2) = 0"
        ).fetchall()
    data = pd.DataFrame(rows, columns=["station_id", "ts", "pm25", "google", "ours", "cams"]).dropna()
    data["ts"] = pd.to_datetime(data.ts, utc=True)
    data["day"] = data.ts.dt.tz_convert("Asia/Kolkata").dt.date
    if data.empty:
        print("No overlapping hours yet: station readings do not cover the live hours.")
        return

    print(f"{len(data):,} station-hours, {data.station_id.nunique()} stations, "
          f"{data.ts.min():%d %b %H:%M} to {data.ts.max():%d %b %H:%M} UTC (live values only)\n")
    actual = data.pm25.to_numpy()
    table = {}
    for name, column in (("Google", "google"), ("Our model", "ours"), ("Raw CAMS", "cams")):
        predicted = data[column].to_numpy(dtype=float)
        s = scores(actual, predicted, "pm25")
        table[name] = {
            "typical error": round(s["mae"], 1),
            "bias": round(s["bias"], 1),
            "right band": f"{s['band_exact']:.0%}",
            "within 1 band": f"{s['band_within_one']:.0%}",
            "follows ups and downs (corr.)": round(float(np.corrcoef(actual, predicted)[0, 1]), 2),
            "best hour": f"{ordering_accuracy(data, 'pm25', column, 'ts', ['station_id', 'day'], 10):.0%}",
            "cleaner place": f"{ordering_accuracy(data, 'pm25', column, 'station_id', ['ts'], 10):.0%}",
        }
    print(pd.DataFrame(table).T.to_string())
    print(f"\nAverage real PM2.5 in this window: {actual.mean():.0f}")
    OUT.write_text(json.dumps({"window": [str(data.ts.min()), str(data.ts.max())],
                               "station_hours": len(data), "table": table}, indent=1))


if __name__ == "__main__":
    main()
