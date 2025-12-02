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

# Try multiple approaches to find the map
# 1. Try with full scheduler name (e.g., "scx_nest")
MAP_ID=$(bpftool map show 2>/dev/null | grep -A 5 "$SCHEDULER_NAME" | grep "$MAP_NAME" | head -1 | awk '{print $1}' | cut -d: -f1)

# 2. If not found, try with short name (e.g., "nest" for "scx_nest")
if [ -z "$MAP_ID" ]; then
    SHORT_NAME=$(echo "$SCHEDULER_NAME" | sed 's/^scx_//')
    MAP_ID=$(bpftool map show 2>/dev/null | grep -A 5 "$SHORT_NAME" | grep "$MAP_NAME" | head -1 | awk '{print $1}' | cut -d: -f1)
fi

# 3. If still not found, try searching by map name directly (less precise but more robust)
if [ -z "$MAP_ID" ]; then
    # Get all maps with the matching name, then try to find one associated with a scheduler
    MAP_ID=$(bpftool map show 2>/dev/null | grep -B 2 -A 2 "$MAP_NAME" | grep -E "^[0-9]+:" | head -1 | cut -d: -f1)
fi

if [ -z "$MAP_ID" ]; then
    # Don't exit with error - let the calling script handle it gracefully
    # This allows metrics collection to continue even if map isn't found initially
    exit 0
fi

echo "$MAP_ID"

