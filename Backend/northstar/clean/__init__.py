"""Data cleaning.

Turns raw downloads into a tidy hourly table: removes impossible values,
flags or fills gaps, aligns every station and weather series to the same
hourly clock, and handles stations that started at different dates.
"""
