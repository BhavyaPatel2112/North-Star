# North Star backend

Python code that collects Mumbai air quality and weather data, cleans it, trains the pollution model, and serves predictions to the app.

## Setup

```bash
cd Backend
/opt/homebrew/bin/python3.13 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env    # then fill in the values
.venv/bin/pytest
```

## Layout

| Folder | Purpose |
| --- | --- |
| `northstar/config.py` | Settings and secrets, read from `.env` |
| `northstar/collect/` | Download station, weather and map data; hourly live collector |
| `northstar/clean/` | Remove bad values, fill gaps, align everything hourly |
| `northstar/db/` | Supabase PostgreSQL connection and tables |
| `northstar/model/` | Hexagon grid, baseline, LightGBM model, forecast, evaluation |
| `northstar/server/` | FastAPI endpoints for the app |
| `scripts/` | Commands you run by hand or on a schedule |
| `tests/` | Automated checks (`pytest`) |
| `notebooks/` | Jupyter notebooks for exploring data |
| `data/` | Local downloads, not committed to Git |
