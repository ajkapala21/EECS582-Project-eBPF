#!/bin/bash
# Hackbench workload generator
# Usage: hackbench_workload.sh <processes> <loops>

set -e

PROCESSES=${1:-10}
LOOPS=${2:-100}

if ! command -v hackbench >/dev/null 2>&1; then
    echo "ERROR: hackbench not found. Install with: sudo apt-get install rt-tests" >&2
    exit 1
fi

echo "[$(date +%H:%M:%S)] Starting hackbench: -p $PROCESSES -l $LOOPS"
START_TIME=$(date +%s.%N)
hackbench -p "$PROCESSES" -l "$LOOPS" >/tmp/hackbench_output.log 2>&1
END_TIME=$(date +%s.%N)
DURATION=$(echo "$END_TIME - $START_TIME" | bc)

echo "[$(date +%H:%M:%S)] Hackbench completed in ${DURATION}s"
echo "DURATION:$DURATION"

