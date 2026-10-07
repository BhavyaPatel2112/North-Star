"""Good places to end a run with food: popular, well-rated restaurants and cafes.

For "End near food", the server asks Google Places (Nearby Search) for the 20
most popular restaurants, cafes and bakeries within reach of the start, and
keeps only those that are open for business and well rated (at least 4.0 stars
from at least 100 reviews), so runs end at places like a McDonald's or a
well-known local restaurant rather than an unknown stall.

Cost: asking for ratings puts each search in Google's "Enterprise" tier, which
has 1,000 free searches a month. Every search is counted in api_usage and
stops at 900 a month and 60 a day, so it stays inside the free tier. When the
limit is reached (or Google fails), the server uses the places the app found
in Apple Maps instead.
"""

import os
from dataclasses import dataclass
from datetime import datetime, timezone

import requests

from northstar import config

URL = "https://places.googleapis.com/v1/places:searchNearby"
API_NAME = "google_places"
MONTHLY_LIMIT = int(os.getenv("GOOGLE_PLACES_MONTHLY_LIMIT", "900"))
DAILY_LIMIT = int(os.getenv("GOOGLE_PLACES_DAILY_LIMIT", "60"))

MIN_RATING = 4.0
MIN_REVIEWS = 100
# Places that are rated well but are not somewhere to walk into after a run.
NOT_AFTER_A_RUN = ("banquet", "bar & lounge", "lounge", "pub", "wine", "hall")
# Only the fields we use; the rating fields set the price tier (Enterprise).
FIELDS = ",".join(f"places.{f}" for f in
                  ("id", "displayName", "location", "rating", "userRatingCount", "businessStatus", "primaryType"))


@dataclass
class FoodSearch:
    places: list[dict]      # [{name, lat, lon, rating, reviews}], best first
    source: str             # "google", or why Google was not used


def _used(conn, api: str, period) -> int:
    row = conn.execute("select coalesce(sum(requests), 0) from api_usage where api = %s and month = %s",
                       (api, period)).fetchone()
    return int(row[0])


def _count(conn, api: str, period) -> None:
    conn.execute(
        "insert into api_usage (api, month, requests) values (%s, %s, 1) "
        "on conflict (api, month) do update set requests = api_usage.requests + 1",
        (api, period))


def budget_left(conn) -> bool:
    """True while this month's and today's searches are under their limits
    (the day is stored as a row named google_places_day, like the Routes counter)."""
    today = datetime.now(timezone.utc).date()
    return (_used(conn, API_NAME, today.replace(day=1)) < MONTHLY_LIMIT
            and _used(conn, API_NAME + "_day", today) < DAILY_LIMIT)


def search(conn, lat: float, lon: float, radius_m: float) -> FoodSearch:
    """Popular, well-rated places to eat within `radius_m` of a point."""
    if not config.GOOGLE_AIR_QUALITY_KEY:
        return FoodSearch([], "no Google key")
    if not budget_left(conn):
        return FoodSearch([], "Google limit reached")

    today = datetime.now(timezone.utc).date()
    _count(conn, API_NAME, today.replace(day=1))
    _count(conn, API_NAME + "_day", today)
    conn.commit()  # counted before asking, so a failure cannot lose the count
    try:
        response = requests.post(URL, timeout=15, headers={
            "X-Goog-Api-Key": config.GOOGLE_AIR_QUALITY_KEY,
            "X-Goog-FieldMask": FIELDS,
        }, json={
            "includedTypes": ["restaurant", "cafe", "bakery", "fast_food_restaurant"],
            "maxResultCount": 20,
            "rankPreference": "POPULARITY",
            "locationRestriction": {"circle": {"center": {"latitude": lat, "longitude": lon},
                                               "radius": min(50_000.0, max(500.0, radius_m))}},
        })
    except requests.RequestException as error:
        return FoodSearch([], f"Google Places: {type(error).__name__}")
    if response.status_code != 200:
        # Only the status code: the response body could echo request details.
        return FoodSearch([], f"Google Places: HTTP {response.status_code}")

    places = []
    for place in response.json().get("places", []):
        rating, reviews = place.get("rating", 0), place.get("userRatingCount", 0)
        if place.get("businessStatus", "OPERATIONAL") != "OPERATIONAL":
            continue
        if rating < MIN_RATING or reviews < MIN_REVIEWS:
            continue
        name = place.get("displayName", {}).get("text", "")
        if any(word in name.lower() for word in NOT_AFTER_A_RUN):
            continue
        places.append({"name": place.get("displayName", {}).get("text", "Restaurant"),
                       "lat": place["location"]["latitude"], "lon": place["location"]["longitude"],
                       "rating": rating, "reviews": reviews})
    # Best first: high rating, with many reviews counting a little extra.
    places.sort(key=lambda p: p["rating"] + min(p["reviews"], 5000) / 10000, reverse=True)
    return FoodSearch(places, "google")
