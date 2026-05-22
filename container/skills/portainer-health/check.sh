#!/usr/bin/env python3
"""
Portainer health check.
Outputs JSON on last line: {"wakeAgent": false} or {"wakeAgent": true, "data": {...}}
Authentication is injected by OneCLI — no API key needed.
"""
import json, subprocess, sys

PORTAINER = "https://portainer.ashfamily.co.il"

def fetch(path):
    result = subprocess.run(
        ["curl", "-sf", f"{PORTAINER}{path}"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)

services = fetch("/api/endpoints/1/docker/services")
if services is None:
    print(json.dumps({"wakeAgent": True, "data": {"error": "Could not reach Portainer"}}))
    sys.exit(0)

tasks = fetch("/api/endpoints/1/docker/tasks?filters=%7B%22desired-state%22%3A%5B%22running%22%5D%7D") or []
nodes = fetch("/api/endpoints/1/docker/nodes") or []

node_count = len([n for n in nodes if n.get("Spec", {}).get("Availability") == "active"]) or 1

running = {}
for t in tasks:
    if t.get("Status", {}).get("State") == "running":
        sid = t.get("ServiceID", "")
        running[sid] = running.get(sid, 0) + 1

SKIP_STACKS = {"papertrail"}

up, down = [], []
for s in sorted(services, key=lambda x: x["Spec"]["Name"]):
    name = s["Spec"]["Name"]
    sid  = s["ID"]
    mode = s["Spec"].get("Mode", {})
    desired = node_count if "Global" in mode else mode.get("Replicated", {}).get("Replicas", 1)
    actual  = running.get(sid, 0)
    parts = name.split("_", 1)
    stack = parts[0] if len(parts) == 2 else ""
    label = f"{parts[1]} ({parts[0]})" if len(parts) == 2 else name
    if stack in SKIP_STACKS:
        continue
    if actual >= desired:
        up.append(label)
    else:
        down.append({"service": label, "running": actual, "desired": desired})

if down:
    print(json.dumps({"wakeAgent": True, "data": {"down": down, "up_count": len(up)}}))
else:
    print(json.dumps({"wakeAgent": False}))
