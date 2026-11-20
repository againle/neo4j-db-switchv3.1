#!/bin/sh
set -e
# Personas are NOT seeded here: the memgraph backend syncs each profile into
# this graph from its profile.yaml when a session starts.
exec python -m uvicorn backend.main:app --host 0.0.0.0 --port 8021
