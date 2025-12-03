#!/bin/bash
# Collect metrics from trace_pipe (fallback when bpftool doesn't work)
# Usage: collect_metrics_trace.sh <scheduler_name> <output_file> <duration>

set -e

SCHEDULER_NAME=$1
OUTPUT_FILE=$2
DURATION=${3:-60}

if [ -z "$SCHEDULER_NAME" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <scheduler_name> <output_file> [duration]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/test_config.sh"

INTERVAL=$METRICS_INTERVAL
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

# Trace pipe file
TRACE_FILE="/tmp/trace_${SCHEDULER_NAME}_$$.txt"
TRACE_PID=""

# Start capturing trace_pipe in background
start_trace_capture() {
    if [ -r /sys/kernel/debug/tracing/trace_pipe ]; then
        sudo cat /sys/kernel/debug/tracing/trace_pipe > "$TRACE_FILE" 2>/dev/null &
        TRACE_PID=$!
        sleep 0.5  # Give it time to start
    else
        echo "WARNING: Cannot read trace_pipe, metrics will be limited" >&2
    fi
}

# Stop trace capture
stop_trace_capture() {
    if [ -n "$TRACE_PID" ] && kill -0 "$TRACE_PID" 2>/dev/null; then
        sudo kill "$TRACE_PID" 2>/dev/null || true
        wait "$TRACE_PID" 2>/dev/null || true
    fi
}

# Cleanup on exit
trap 'stop_trace_capture; rm -f "$TRACE_FILE"' EXIT

# Write CSV header
echo "timestamp,estimated_map_entries,total_tasks_added,total_evictions,eviction_rate_per_sec,free_mem_kb,slab_bpf_kb" > "$OUTPUT_FILE"

# Start trace capture
start_trace_capture

# Initialize counters
LAST_TASKS_ADDED=0
LAST_EVICTIONS=0
ESTIMATED_ENTRIES=0

while [ $(date +%s) -lt $END_TIME ]; do
    TIMESTAMP=$(date +%s)
    RELATIVE_TIME=$((TIMESTAMP - START_TIME))
    
    # Parse trace file for metrics
    if [ -f "$TRACE_FILE" ]; then
        # Count tasks added (from start of test)
        TOTAL_TASKS_ADDED=$(grep -c "nest_running: Added new task" "$TRACE_FILE" 2>/dev/null || echo "0")
        
        # Count total evictions (from start of test)
        TOTAL_EVICTIONS=$(grep "Map cleanup: timeout after evicted" "$TRACE_FILE" 2>/dev/null | \
            sed 's/.*evicted \([0-9]*\) entries.*/\1/' | \
            awk '{sum+=$1} END {print sum+0}' || echo "0")
        
        # Estimate current map entries: tasks added - tasks evicted
        ESTIMATED_ENTRIES=$((TOTAL_TASKS_ADDED - TOTAL_EVICTIONS))
        if [ "$ESTIMATED_ENTRIES" -lt 0 ]; then
            ESTIMATED_ENTRIES=0
        fi
        
        # Calculate eviction rate (evictions per second since last sample)
        EVICTIONS_DELTA=$((TOTAL_EVICTIONS - LAST_EVICTIONS))
        if [ $RELATIVE_TIME -gt 0 ]; then
            EVICTION_RATE=$(echo "scale=2; $EVICTIONS_DELTA / $INTERVAL" | bc 2>/dev/null || echo "0")
        else
            EVICTION_RATE=0
        fi
        LAST_EVICTIONS=$TOTAL_EVICTIONS
    else
        TOTAL_TASKS_ADDED=0
        TOTAL_EVICTIONS=0
        ESTIMATED_ENTRIES=0
        EVICTION_RATE=0
    fi
    
    # Get free memory (in KB)
    FREE_MEM=$(free -k 2>/dev/null | awk '/^Mem:/ {print $4}' || echo "0")
    FREE_MEM=$(echo "$FREE_MEM" | tr -d '[:space:]')
    if [ -z "$FREE_MEM" ] || ! [[ "$FREE_MEM" =~ ^[0-9]+$ ]]; then
        FREE_MEM=0
    fi
    
    # Get BPF slab cache size (in KB)
    SLAB_BPF=$(grep -E "bpf_map|bpf_map_elem" /proc/slabinfo 2>/dev/null | \
        awk '{sum+=$2*$3} END {if (sum>0) print sum/1024; else print 0}' || echo "0")
    SLAB_BPF=$(echo "$SLAB_BPF" | tr -d '[:space:]')
    if [ -z "$SLAB_BPF" ]; then
        SLAB_BPF=0
    fi
    
    # Append to CSV
    echo "$RELATIVE_TIME,$ESTIMATED_ENTRIES,$TOTAL_TASKS_ADDED,$TOTAL_EVICTIONS,$EVICTION_RATE,$FREE_MEM,$SLAB_BPF" >> "$OUTPUT_FILE"
    
    sleep "$INTERVAL"
done

# Stop trace capture
stop_trace_capture

