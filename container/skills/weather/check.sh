#!/usr/bin/env python3
"""
Weather check for Rishon Lezion, Israel.
Outputs JSON on last line: {"wakeAgent": true, "data": {...}}
Uses Open-Meteo (free, no API key).
"""
import json, urllib.request, sys

URL = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude=31.97&longitude=34.79"
    "&current=windspeed_10m,windgusts_10m,temperature_2m"
    "&daily=windspeed_10m_max,windgusts_10m_max,temperature_2m_max,temperature_2m_min"
    "&timezone=Asia%2FJerusalem&forecast_days=1&wind_speed_unit=kmh"
)

try:
    with urllib.request.urlopen(URL, timeout=10) as r:
        data = json.load(r)
    current = data["current"]
    daily   = data["daily"]
    print(json.dumps({"wakeAgent": True, "data": {
        "wind_now":        current["windspeed_10m"],
        "gusts_now":       current["windgusts_10m"],
        "temp_now":        current["temperature_2m"],
        "wind_max_today":  daily["windspeed_10m_max"][0],
        "gusts_max_today": daily["windgusts_10m_max"][0],
        "temp_max":        daily["temperature_2m_max"][0],
        "temp_min":        daily["temperature_2m_min"][0],
    }}))
except Exception as e:
    print(json.dumps({"wakeAgent": True, "data": {"error": str(e)}}))
