#!/bin/bash
# Stress-ng workload generator
# Usage: stress_ng_workload.sh <process_count> <duration_seconds>

set -e

PROCESS_COUNT=${1:-20}
DURATION=${2:-60}

if ! command -v stress-ng >/dev/null 2>&1; then
    echo "ERROR: stress-ng not found. Install with: sudo apt-get install stress-ng" >&2
    exit 1
fi

echo "[$(date +%H:%M:%S)] Starting stress-ng: --fork $PROCESS_COUNT --timeout ${DURATION}s"
stress-ng --fork "$PROCESS_COUNT" --timeout "${DURATION}s" >/dev/null 2>&1 &
WORKLOAD_PID=$!

echo "$WORKLOAD_PID"

