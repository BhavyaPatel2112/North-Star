"""Festival and event calendar, kept up to date automatically.

Festivals with fireworks, bonfires or huge crowds (Diwali, Ganesh Chaturthi,
Holi, Dussehra, New Year's Eve) cause the worst air of the year, and the
effect lasts for days. Hindu festivals follow the lunar calendar, so their
dates change every year.

Dates come from Google's public "Holidays in India" calendar, which lists
festivals about five years ahead and is maintained by Google, so when a new
year's dates are published they flow in on the next refresh. The Python
`holidays` library is a backup if Google cannot be reached.
"""

import re
from datetime import date, timedelta

import holidays
import pandas as pd
import psycopg
import requests

GOOGLE_CALENDAR_URL = (
    "https://calendar.google.com/calendar/ical/"
    "en.indian%23holiday%40group.v.calendar.google.com/public/basic.ics"
)

# Calendar name (lower case, partial match) -> our event type.
NAME_TO_TYPE = {
    "naraka chaturdashi": "diwali",  # first big firework night of Diwali
    "diwali": "diwali",
    "deepavali": "diwali",
    "ganesh chaturthi": "ganesh_chaturthi",
    "holi": "holi",
    "dussehra": "dussehra",
}
EVENT_TYPES = ["diwali", "ganesh_chaturthi", "ganesh_visarjan", "holi", "dussehra", "new_years_eve"]

# Ganesh Visarjan (immersion day, Anant Chaturdashi) is 10 days after Ganesh Chaturthi.
VISARJAN_AFTER_DAYS = 10


def _classify(name: str) -> str | None:
    lowered = name.lower()
    if "holika" in lowered:  # Holika Dahan bonfires: count with Holi
        return "holi"
    for key, event_type in NAME_TO_TYPE.items():
        if key in lowered:
            return event_type
    return None


def fetch_google() -> list[tuple[date, str, str]]:
    """(date, event type, original name) for every relevant event in Google's calendar."""
    text = requests.get(GOOGLE_CALENDAR_URL, timeout=60).text
    events = []
    for block in text.split("BEGIN:VEVENT")[1:]:
        start = re.search(r"DTSTART;VALUE=DATE:(\d{8})", block)
        summary = re.search(r"SUMMARY:([^\r\n]+)", block)
        if not (start and summary):
            continue
        event_type = _classify(summary.group(1))
        if event_type:
            day = date(int(start.group(1)[:4]), int(start.group(1)[4:6]), int(start.group(1)[6:]))
            events.append((day, event_type, summary.group(1).strip()))
    return events


def fetch_backup(years: range) -> list[tuple[date, str, str]]:
    """Diwali, Holi and Dussehra from the `holidays` library (no Ganesh Chaturthi there)."""
    events = []
    for day, name in holidays.India(years=years).items():
        event_type = _classify(name)
        if event_type:
            events.append((day, event_type, name))
    return events


def add_fixed_and_derived(events: list[tuple[date, str, str]], years: range) -> list[tuple[date, str, str]]:
    """Add New Year's Eve (fixed date) and Ganesh Visarjan (10 days after Chaturthi)."""
    events = list(events)
    events += [(date(y, 12, 31), "new_years_eve", "New Year's Eve") for y in years]
    events += [
        (day + timedelta(days=VISARJAN_AFTER_DAYS), "ganesh_visarjan", "Ganesh Visarjan (Anant Chaturdashi)")
        for day, event_type, _ in events if event_type == "ganesh_chaturthi"
    ]
    return events


def refresh_events(conn: psycopg.Connection, max_age_hours: int = 24) -> str:
    """Re-download the calendar if the saved copy is older than `max_age_hours`."""
    last = conn.execute("select max(fetched_at) from events").fetchone()[0]
    if last is not None:
        age = conn.execute("select extract(epoch from now() - %s) / 3600", (last,)).fetchone()[0]
        if age < max_age_hours:
            return f"Events: up to date (refreshed {age:.0f} h ago)"

    years = range(2019, date.today().year + 6)
    try:
        events, source = fetch_google(), "google"
    except requests.RequestException:
        events, source = fetch_backup(years), "holidays-library"
    events = add_fixed_and_derived(events, years)

    with conn.cursor() as cursor:
        cursor.executemany(
            "insert into events (event_date, event_type, name, source) values (%s, %s, %s, %s) "
            "on conflict (event_date, event_type) do update set name = excluded.name, "
            "source = excluded.source, fetched_at = now()",
            [(day, event_type, name, source) for day, event_type, name in events],
        )
    latest = max(day for day, _, _ in events)
    return f"Events: {len(events)} saved from {source}, known up to {latest}"


def load_events(conn: psycopg.Connection) -> pd.DataFrame:
    rows = conn.execute("select event_date, event_type from events order by event_date").fetchall()
    return pd.DataFrame(rows, columns=["event_date", "event_type"])
