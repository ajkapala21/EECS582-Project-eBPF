#!/bin/bash
# Find BPF map ID for a scheduler
# Usage: find_map_id.sh <scheduler_name> <map_name>

set -e

SCHEDULER_NAME=$1
MAP_NAME=$2

if [ -z "$SCHEDULER_NAME" ] || [ -z "$MAP_NAME" ]; then
    echo "Usage: $0 <scheduler_name> <map_name>" >&2
    exit 1
fi

if ! command -v bpftool >/dev/null 2>&1; then
    echo "ERROR: bpftool not found" >&2
    exit 1
fi

# Find map ID by looking for scheduler name and map name in bpftool output
MAP_ID=$(bpftool map show 2>/dev/null | grep -A 5 "$SCHEDULER_NAME" | grep "$MAP_NAME" | head -1 | awk '{print $1}' | cut -d: -f1)

if [ -z "$MAP_ID" ]; then
    echo "ERROR: Could not find map $MAP_NAME for scheduler $SCHEDULER_NAME" >&2
    exit 1
fi

echo "$MAP_ID"

