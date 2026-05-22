---
name: portainer-health
description: Check the health of running services on the home server. Use when the user asks what's running, what's up/down, container health, or service status.
allowed-tools: Bash
---

# /health — Home Server Service Health

Check which services are up or down on the Portainer Swarm cluster.

Authentication is injected automatically — do not add any auth headers.

## Manual invocation (user asks for status)

Run the health script and report the result:

```bash
python3 /app/skills/portainer-health/check.sh
```

Parse the JSON output and format for WhatsApp:

```
*Home Server Status*

✅ *All N services running*

— or if something is down —

✅ *Running (N)*
• service (stack)
• ...

❌ *Down (N)*
• service (stack) — 0/1
• ...
```

- If all services are up, use the single-line summary
- If Portainer is unreachable, report: "Could not reach Portainer"

## Scheduled task script

The hourly health check uses `check.sh` directly (no agent invoked unless something is down).
The script outputs `{"wakeAgent": false}` when all is well, or `{"wakeAgent": true, "data": {...}}` when services are down.
When woken, send a message reporting the down services using the format above.
