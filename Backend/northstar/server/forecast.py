"""The latest map forecast, kept in memory for fast route planning.

The hourly job (scripts.predict_grid) writes PM2.5 for every hexagon for the
next 36 hours into grid_predictions. Here we load those rows once, turn them
into "PM2.5 a runner breathes on each street, for each hour" (hexagon value
times the near-road uplift), and reload only when a newer prediction run has
been written. Checking for a new run costs one tiny query, at most every few
minutes.
"""

import threading
import time
from datetime import datetime, timedelta, timezone

import numpy as np

from northstar.db.connection import connect
from northstar.routing.comfort import feels_like_c, run_score
from northstar.routing.planner import Planner

RECHECK_SECONDS = 300
INDIA = timezone(timedelta(hours=5, minutes=30))  # India has no daylight saving


class ForecastCache:
    def __init__(self, planner: Planner):
        self.planner = planner
        self.lock = threading.Lock()
        self.run_at: datetime | None = None
        self.hours: list[datetime] = []          # UTC hour starts
        self.exposure = np.zeros((0, len(planner.net.edge_cell)), dtype=np.float32)  # hours x streets
        self.checked_at = 0.0
        # Weather for "feels like": the weather squares, and (temperature, humidity) per square and hour.
        self.weather_cells: list[tuple[int, float, float]] = []   # (cell_id, lat, lon)
        self.weather: dict[tuple[int, datetime], tuple[float, float]] = {}

    def refresh(self, force: bool = False) -> None:
        """Reload the forecast if a newer prediction run exists."""
        if not force and time.monotonic() - self.checked_at < RECHECK_SECONDS and self.hours:
            return
        with self.lock:
            if not force and time.monotonic() - self.checked_at < RECHECK_SECONDS and self.hours:
                return
            with connect() as conn:
                latest = conn.execute("select max(run_at) from prediction_runs").fetchone()[0]
                if latest is not None and latest != self.run_at:
                    rows = conn.execute(
                        "select ts, h3, pm25 from grid_predictions "
                        "where ts >= date_trunc('hour', now()) - interval '1 hour' and pm25 is not null "
                        "order by ts").fetchall()
                    self._build(rows)
                    self._load_weather(conn)
                    self.run_at = latest
            self.checked_at = time.monotonic()

    def _build(self, rows: list) -> None:
        net_cells = self.planner.net.edge_cell
        hours = sorted({r[0] for r in rows})
        matrix = np.zeros((len(hours), len(net_cells)), dtype=np.float32)
        by_hour: dict = {h: {} for h in hours}
        for ts, h3, pm25 in rows:
            by_hour[ts][int(h3)] = float(pm25)
        for i, hour in enumerate(hours):
            cells = by_hour[hour]
            default = float(np.median(list(cells.values())))
            matrix[i] = self.planner.edge_exposure(cells, default)
        self.hours, self.exposure = hours, matrix

    def _load_weather(self, conn) -> None:
        """Temperature and humidity for the forecast hours, for every weather square."""
        self.weather_cells = [(int(c), float(lat), float(lon)) for c, lat, lon in conn.execute(
            "select cell_id, ST_Y(location::geometry), ST_X(location::geometry) from weather_cells").fetchall()]
        rows = conn.execute(
            "select cell_id, ts, temperature_c, relative_humidity from weather_hourly "
            "where ts >= date_trunc('hour', now()) - interval '1 hour' "
            "and temperature_c is not null and relative_humidity is not null").fetchall()
        self.weather = {(int(c), ts): (float(t), float(h)) for c, ts, t, h in rows}

    def _weather_cell(self, lat: float, lon: float) -> int | None:
        if not self.weather_cells:
            return None
        return min(self.weather_cells, key=lambda c: (c[1] - lat) ** 2 + (c[2] - lon) ** 2)[0]

    def hour_index(self, when: datetime) -> int:
        """Index of the forecast hour containing `when` (nearest one if outside the forecast)."""
        if not self.hours:
            raise LookupError("No forecast loaded yet.")
        target = when.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
        gaps = [abs((h - target).total_seconds()) for h in self.hours]
        return int(np.argmin(gaps))

    def route_by_hour(self, edges: list[int], lengths: np.ndarray, hours_ahead: int = 24,
                      near: tuple[float, float] | None = None) -> list[dict]:
        """The route's average PM2.5 for each forecast hour from now, with "feels like"
        and humidity from the weather square nearest `near` (the start) when known."""
        now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
        cell = self._weather_cell(*near) if near else None
        result = []
        for i, hour in enumerate(self.hours):
            if now <= hour < now + timedelta(hours=hours_ahead):
                pm25 = float(np.average(self.exposure[i, edges], weights=lengths))
                entry = {"time": hour.astimezone(INDIA).isoformat(), "pm25": round(pm25, 1)}
                weather = self.weather.get((cell, hour)) if cell is not None else None
                if weather:
                    entry["feels_like_c"] = feels_like_c(*weather)
                    entry["humidity"] = round(weather[1])
                result.append(entry)
        return result


def best_start(by_hour: list[dict]) -> dict | None:
    """The cleanest start between 5 am and 10 pm India time (air only; kept for older apps)."""
    daytime = [h for h in by_hour if 5 <= datetime.fromisoformat(h["time"]).hour < 22]
    return min(daytime, key=lambda h: h["pm25"]) if daytime else None


def best_window(by_hour: list[dict]) -> dict | None:
    """The best start between 5 am and 10 pm India time, balancing air and heat
    (see northstar.routing.comfort.run_score)."""
    daytime = [h for h in by_hour if 5 <= datetime.fromisoformat(h["time"]).hour < 22]
    return min(daytime, key=lambda h: run_score(h["pm25"], h.get("feels_like_c"))) if daytime else None
