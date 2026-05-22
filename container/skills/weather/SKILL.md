---
name: weather
description: Get the current wind speed, gusts, and temperature for Rishon Lezion. Use when the user asks about weather, wind, or temperature.
allowed-tools: Bash
---

# Weather — Rishon Lezion

Data from Open-Meteo (free, no auth needed).

## Manual invocation

```bash
python3 /app/skills/weather/check.sh
```

Format the JSON output for WhatsApp:

```
🌬 *Wind Report — Rishon Lezion*

Now: 18 km/h · Gusts: 28 km/h
Today max: 25 km/h · Max gusts: 35 km/h
🌡 14°C → 22°C
```

- If `data.error` is set, report: "Could not fetch weather data"

## Scheduled morning report

Runs daily at 07:30. The script always returns `wakeAgent: true`.
Send the morning report using the format above.
