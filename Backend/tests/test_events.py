"""Tests for the festival calendar and festival features."""

from datetime import date

import pandas as pd

from northstar.collect.events import _classify, add_fixed_and_derived
from northstar.model.dataset import EVENT_WINDOW_DAYS, add_event_features


def test_classify_calendar_names():
    assert _classify("Diwali/Deepavali") == "diwali"
    assert _classify("Holika Dahana") == "holi"
    assert _classify("Ganesh Chaturthi/Vinayaka Chaturthi") == "ganesh_chaturthi"
    assert _classify("Christmas") is None


def test_visarjan_is_ten_days_after_chaturthi_and_new_years_eve_added():
    events = add_fixed_and_derived([(date(2026, 9, 14), "ganesh_chaturthi", "Ganesh Chaturthi")], range(2026, 2027))
    assert (date(2026, 9, 24), "ganesh_visarjan", "Ganesh Visarjan (Anant Chaturdashi)") in events
    assert (date(2026, 12, 31), "new_years_eve", "New Year's Eve") in events


def test_days_since_and_until_diwali():
    events = pd.DataFrame({"event_date": [date(2025, 10, 20), date(2026, 11, 8)], "event_type": "diwali"})
    # 06:30 UTC is 12:00 in India; check the day before, the day of, and three days after.
    ts = pd.to_datetime(["2025-10-19 06:30", "2025-10-20 06:30", "2025-10-23 06:30", "2026-06-01 06:30"], utc=True)
    out = add_event_features(pd.DataFrame({"ts": ts}), events)
    assert list(out.days_until_diwali[:2]) == [1, 0]
    assert list(out.days_since_diwali[1:3]) == [0, 3]
    # Far from any Diwali: both capped.
    assert out.days_since_diwali.iloc[3] == EVENT_WINDOW_DAYS and out.days_until_diwali.iloc[3] == EVENT_WINDOW_DAYS
