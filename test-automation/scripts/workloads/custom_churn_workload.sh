#!/bin/bash
# Custom task churn workload generator
# Usage: custom_churn_workload.sh <spawn_count> <duration_seconds>

set -e

SPAWN_COUNT=${1:-1000}
DURATION=${2:-30}

echo "[$(date +%H:%M:%S)] Starting custom churn: $SPAWN_COUNT spawns over ${DURATION}s"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))
SPAWNED=0

while [ $(date +%s) -lt $END_TIME ] && [ $SPAWNED -lt $SPAWN_COUNT ]; do
    # Spawn a short-lived task
    (sleep 0.1 &)
    SPAWNED=$((SPAWNED + 1))
    
    # Small delay to avoid overwhelming the system
    sleep 0.01
done

echo "[$(date +%H:%M:%S)] Custom churn completed: spawned $SPAWNED tasks"

