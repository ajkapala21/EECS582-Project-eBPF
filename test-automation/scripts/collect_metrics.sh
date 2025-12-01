#!/bin/bash
# Collect metrics during experiment
# Usage: collect_metrics.sh <scheduler_name> <map_name> <output_file> <duration>

set -e

SCHEDULER_NAME=$1
MAP_NAME=$2
OUTPUT_FILE=$3
DURATION=${4:-60}

if [ -z "$SCHEDULER_NAME" ] || [ -z "$MAP_NAME" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <scheduler_name> <map_name> <output_file> [duration]" >&2
    exit 1
fi

# Source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/test_config.sh"

INTERVAL=$METRICS_INTERVAL
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

# Write CSV header
echo "timestamp,map_entries,free_mem_kb,slab_bpf_kb,evictions" > "$OUTPUT_FILE"

# Try to find map ID (may not exist immediately)
MAP_ID=""
EVICTION_COUNT=0

while [ $(date +%s) -lt $END_TIME ]; do
    TIMESTAMP=$(date +%s)
    RELATIVE_TIME=$((TIMESTAMP - START_TIME))
    
    # Try to find map ID if not found yet
    if [ -z "$MAP_ID" ]; then
        MAP_ID=$("$SCRIPT_DIR/find_map_id.sh" "$SCHEDULER_NAME" "$MAP_NAME" 2>/dev/null || echo "")
    fi
    
    # Count map entries
    MAP_ENTRIES=0
    if [ -n "$MAP_ID" ]; then
        MAP_ENTRIES=$(bpftool map dump id "$MAP_ID" 2>/dev/null | grep -c "key:" || echo "0")
    fi
    
    # Get free memory (in KB)
    FREE_MEM=$(free -k | awk '/^Mem:/ {print $4}')
    
    # Get BPF slab cache size (in KB)
    SLAB_BPF=$(grep -E "bpf_map|bpf_map_elem" /proc/slabinfo 2>/dev/null | awk '{sum+=$2*$3} END {print sum/1024}' || echo "0")
    
    # Count evictions from dmesg
    NEW_EVICTIONS=$(dmesg | grep -c "Map cleanup: evicted" || echo "0")
    if [ "$NEW_EVICTIONS" -gt "$EVICTION_COUNT" ]; then
        EVICTION_COUNT=$NEW_EVICTIONS
    fi
    
    # Append to CSV
    echo "$RELATIVE_TIME,$MAP_ENTRIES,$FREE_MEM,$SLAB_BPF,$EVICTION_COUNT" >> "$OUTPUT_FILE"
    
    sleep "$INTERVAL"
done

