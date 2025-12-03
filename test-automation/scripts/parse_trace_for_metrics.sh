#!/bin/bash
# Parse trace_pipe output to extract metrics for paper
# Usage: parse_trace_for_metrics.sh <trace_file> <output_csv>

set -e

TRACE_FILE=$1
OUTPUT_CSV=$2

if [ -z "$TRACE_FILE" ] || [ -z "$OUTPUT_CSV" ]; then
    echo "Usage: $0 <trace_file> <output_csv>" >&2
    exit 1
fi

if [ ! -f "$TRACE_FILE" ]; then
    echo "ERROR: Trace file not found: $TRACE_FILE" >&2
    exit 1
fi

# Extract timestamps and events
# Format: [PROCESS-PID] [CPU] TYPE TIMESTAMP: bpf_trace_printk: MESSAGE

# Write CSV header
echo "timestamp,estimated_map_entries,tasks_added,tasks_evicted,cleanup_operations,evictions_this_cleanup" > "$OUTPUT_CSV"

# Parse trace file
# Format: [PROCESS-PID] [CPU] TYPE TIMESTAMP: bpf_trace_printk: MESSAGE
# Example: gvfs-afc-volume-2242 [003] d..21 11058.988902: bpf_trace_printk: Map cleanup: Starting cleanup scan

grep -E "nest_running: (Added|Updated)|Map cleanup:" "$TRACE_FILE" | \
while IFS= read -r line; do
    # Extract timestamp (format: TIMESTAMP: bpf_trace_printk)
    timestamp=$(echo "$line" | sed -n 's/.* \([0-9]\+\.[0-9]\+\): bpf_trace_printk:.*/\1/p')
    
    if [ -z "$timestamp" ]; then
        continue
    fi
    
    # Check what type of event
    if echo "$line" | grep -q "Added new task"; then
        pid=$(echo "$line" | sed -n 's/.*pid=\([0-9]\+\).*/\1/p')
        echo "$timestamp,ADD,$pid"
    elif echo "$line" | grep -q "Starting cleanup scan"; then
        echo "$timestamp,CLEANUP_START,"
    elif echo "$line" | grep -q "timeout after evicted"; then
        evicted=$(echo "$line" | sed -n 's/.*evicted \([0-9]\+\) entries.*/\1/p')
        echo "$timestamp,EVICTED,$evicted"
    fi
done | sort -n | awk -F',' '
BEGIN {
    entries = 0
    total_added = 0
    total_evicted = 0
    cleanup_count = 0
    last_cleanup_evicted = 0
    start_time = 0
}
{
    ts = $1
    event = $2
    value = $3
    
    if (start_time == 0) {
        start_time = ts
    }
    
    rel_time = int(ts - start_time)
    
    if (event == "ADD") {
        entries++
        total_added++
    } else if (event == "CLEANUP_START") {
        cleanup_count++
        last_cleanup_evicted = 0
    } else if (event == "EVICTED") {
        evicted = int(value)
        entries -= evicted
        if (entries < 0) entries = 0
        total_evicted += evicted
        last_cleanup_evicted = evicted
        # Output row for this cleanup
        print rel_time "," entries "," total_added "," total_evicted "," cleanup_count "," evicted
    }
}
END {
    # Output final row
    print int(ts - start_time) "," entries "," total_added "," total_evicted "," cleanup_count "," last_cleanup_evicted
}' >> "$OUTPUT_CSV"

echo "Parsed trace file: $TRACE_FILE"
echo "Output CSV: $OUTPUT_CSV"
wc -l "$OUTPUT_CSV"

