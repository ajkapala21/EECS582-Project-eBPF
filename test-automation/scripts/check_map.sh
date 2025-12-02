#!/bin/bash
# Check if BPF map exists and has entries
# Usage: check_map.sh <scheduler_name> <map_name>

set -e

SCHEDULER_NAME=$1
MAP_NAME=$2

if [ -z "$SCHEDULER_NAME" ] || [ -z "$MAP_NAME" ]; then
    echo "Usage: $0 <scheduler_name> <map_name>" >&2
    exit 1
fi

echo "Checking for map '$MAP_NAME' for scheduler '$SCHEDULER_NAME'..."
echo ""

# List all maps
echo "All BPF maps:"
bpftool map show 2>/dev/null | head -20
echo ""

# Try to find the map
SHORT_NAME=$(echo "$SCHEDULER_NAME" | sed 's/^scx_//')

echo "Searching for maps containing '$MAP_NAME' or '$SCHEDULER_NAME' or '$SHORT_NAME':"
bpftool map show 2>/dev/null | grep -iE "$MAP_NAME|$SCHEDULER_NAME|$SHORT_NAME" || echo "No matching maps found"
echo ""

# Try to find map ID using the find_map_id script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_ID=$("$SCRIPT_DIR/find_map_id.sh" "$SCHEDULER_NAME" "$MAP_NAME" 2>/dev/null || echo "")

if [ -n "$MAP_ID" ]; then
    echo "Found map ID: $MAP_ID"
    echo ""
    echo "Map details:"
    bpftool map show id "$MAP_ID" 2>/dev/null
    echo ""
    echo "Map entries (first 10):"
    bpftool map dump id "$MAP_ID" 2>/dev/null | head -30
    echo ""
    echo "Total entries:"
    ENTRY_COUNT=$(bpftool map dump id "$MAP_ID" 2>/dev/null | grep -c "key:" || echo "0")
    echo "  $ENTRY_COUNT entries found"
else
    echo "ERROR: Could not find map '$MAP_NAME' for scheduler '$SCHEDULER_NAME'"
    echo ""
    echo "Available maps:"
    bpftool map show 2>/dev/null
fi

