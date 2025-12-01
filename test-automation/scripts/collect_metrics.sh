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
        MAP_ENTRIES=$(bpftool map dump id "$MAP_ID" 2>/dev/null | grep -c "key:" 2>/dev/null || echo "0")
        # Ensure it's a valid integer
        MAP_ENTRIES=$(echo "$MAP_ENTRIES" | tr -d '[:space:]')
        if [ -z "$MAP_ENTRIES" ] || ! [[ "$MAP_ENTRIES" =~ ^[0-9]+$ ]]; then
            MAP_ENTRIES=0
        fi
    fi
    
    # Get free memory (in KB)
    FREE_MEM=$(free -k 2>/dev/null | awk '/^Mem:/ {print $4}' || echo "0")
    # Ensure it's a valid integer
    FREE_MEM=$(echo "$FREE_MEM" | tr -d '[:space:]')
    if [ -z "$FREE_MEM" ] || ! [[ "$FREE_MEM" =~ ^[0-9]+$ ]]; then
        FREE_MEM=0
    fi
    
    # Get BPF slab cache size (in KB)
    SLAB_BPF=$(grep -E "bpf_map|bpf_map_elem" /proc/slabinfo 2>/dev/null | awk '{sum+=$2*$3} END {if (sum>0) print sum/1024; else print 0}' || echo "0")
    # Ensure it's a valid number (can be decimal)
    SLAB_BPF=$(echo "$SLAB_BPF" | tr -d '[:space:]')
    if [ -z "$SLAB_BPF" ]; then
        SLAB_BPF=0
    fi
    
    # Count evictions from dmesg
    NEW_EVICTIONS=$(dmesg | grep -c "Map cleanup: evicted" 2>/dev/null || echo "0")
    # Ensure it's a valid integer (remove any whitespace)
    NEW_EVICTIONS=$(echo "$NEW_EVICTIONS" | tr -d '[:space:]')
    # Default to 0 if empty or not a number
    if [ -z "$NEW_EVICTIONS" ] || ! [[ "$NEW_EVICTIONS" =~ ^[0-9]+$ ]]; then
        NEW_EVICTIONS=0
    fi
    # Compare as integers
    if [ "$NEW_EVICTIONS" -gt "$EVICTION_COUNT" ] 2>/dev/null; then
        EVICTION_COUNT=$NEW_EVICTIONS
    fi
    
    # Append to CSV
    echo "$RELATIVE_TIME,$MAP_ENTRIES,$FREE_MEM,$SLAB_BPF,$EVICTION_COUNT" >> "$OUTPUT_FILE"
    
    sleep "$INTERVAL"
done

