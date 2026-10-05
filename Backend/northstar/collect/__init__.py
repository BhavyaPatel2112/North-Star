"""Data collection.

Downloads raw data from outside sources:
- pollution station readings (OpenAQ, Central Pollution Control Board, World Air Quality Index)
- weather (Open-Meteo)
- city layout (OpenStreetMap through OSMnx)

Also holds the hourly live collector, which re-checks the last 24 to 48 hours
and upserts readings so late uploads and corrections are picked up.
"""
