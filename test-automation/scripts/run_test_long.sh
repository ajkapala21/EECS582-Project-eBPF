#!/bin/bash
# Run test version with trace capture for longer duration
# Usage: run_test_long.sh [duration]

set -e

DURATION=${1:-120}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BASE_DIR"

source "$BASE_DIR/config/test_config.sh"

RESULTS_DIR="results/scx_nest/test"
mkdir -p "$RESULTS_DIR"

TRACE_FILE="$RESULTS_DIR/hackbench_long_trace.txt"
CSV_FILE="$RESULTS_DIR/hackbench_long.csv"

echo "=========================================="
echo "Running TEST version (LONG RUN)"
echo "Duration: $DURATION seconds"
echo "Trace file: $TRACE_FILE"
echo "=========================================="
echo ""

# Clear trace buffer
echo "Clearing trace buffer..."
echo | sudo tee /sys/kernel/debug/tracing/trace >/dev/null

# Start trace capture
echo "Starting trace capture..."
sudo cat /sys/kernel/debug/tracing/trace_pipe > "$TRACE_FILE" &
TRACE_PID=$!
sleep 1

if ! kill -0 $TRACE_PID 2>/dev/null; then
    echo "ERROR: Trace capture failed to start"
    exit 1
fi
echo "Trace capture running (PID: $TRACE_PID)"

# Start scheduler
echo "Starting scheduler..."
sudo ../build/scheds/c/scx_nest_test >/tmp/scheduler_test.log 2>&1 &
SCHED_PID=$!
sleep 2

# Check if loaded
echo "Checking scheduler state..."
if [ -f /sys/kernel/sched_ext/state ]; then
    STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
    echo "Scheduler state: $STATE"
    if [ "$STATE" = "disabled" ]; then
        echo "ERROR: Scheduler not loaded. Check /tmp/scheduler_test.log"
        sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
        exit 1
    fi
else
    echo "WARNING: Cannot check scheduler state"
fi

# Run workload - run hackbench multiple times to generate more activity
echo "Starting workload (will run hackbench multiple times)..."
WORKLOAD_PID=""

# Start first hackbench
./scripts/workloads/hackbench_workload.sh 10 100 &
WORKLOAD_PID=$!

# Wait for duration, restarting hackbench periodically
ELAPSED=0
ITERATION=1
while [ $ELAPSED -lt $DURATION ]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    
    # Check if hackbench finished, restart it
    if ! kill -0 $WORKLOAD_PID 2>/dev/null; then
        echo "[$ELAPSED/$DURATION] Restarting hackbench (iteration $ITERATION)..."
        ./scripts/workloads/hackbench_workload.sh 10 100 &
        WORKLOAD_PID=$!
        ITERATION=$((ITERATION + 1))
    fi
    
    # Show progress every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        echo "[$ELAPSED/$DURATION] Running... (trace: $(wc -l < "$TRACE_FILE" 2>/dev/null || echo 0) lines)"
    fi
done

# Stop workload
echo ""
echo "Stopping workload..."
kill $WORKLOAD_PID 2>/dev/null || true
wait $WORKLOAD_PID 2>/dev/null || true

# Stop scheduler
echo "Stopping scheduler..."
sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true

# Give trace a moment to flush, then stop it
echo "Stopping trace capture..."
sleep 2
sudo kill $TRACE_PID 2>/dev/null || true
wait $TRACE_PID 2>/dev/null || true

# Check trace file
if [ -f "$TRACE_FILE" ]; then
    LINES=$(wc -l < "$TRACE_FILE")
    SIZE=$(du -h "$TRACE_FILE" | cut -f1)
    echo ""
    echo "=========================================="
    echo "Trace captured successfully!"
    echo "File: $TRACE_FILE"
    echo "Lines: $LINES"
    echo "Size: $SIZE"
    echo "=========================================="
    
    # Show cleanup activity
    if [ "$LINES" -gt 0 ]; then
        echo ""
        echo "Cleanup activity:"
        echo "  Cleanup scans: $(grep -c 'Map cleanup: Starting cleanup scan' "$TRACE_FILE" 2>/dev/null || echo 0)"
        echo "  Eviction messages: $(grep -c 'timeout after evicted' "$TRACE_FILE" 2>/dev/null || echo 0)"
        echo "  Tasks added: $(grep -c 'Added new task' "$TRACE_FILE" 2>/dev/null || echo 0)"
        
        # Calculate total evictions
        TOTAL_EVICTIONS=$(grep "timeout after evicted" "$TRACE_FILE" 2>/dev/null | \
            sed 's/.*evicted \([0-9]*\) entries.*/\1/' | \
            awk '{sum+=$1} END {print sum+0}')
        echo "  Total entries evicted: $TOTAL_EVICTIONS"
        
        # Show sample evictions
        echo ""
        echo "Sample eviction messages:"
        grep "timeout after evicted" "$TRACE_FILE" 2>/dev/null | head -5 || echo "  (none found)"
    fi
    
    # Parse trace to CSV
    echo ""
    echo "Parsing trace to CSV..."
    ./scripts/parse_trace_for_metrics.sh "$TRACE_FILE" "$CSV_FILE" || true
    
    if [ -f "$CSV_FILE" ]; then
        CSV_LINES=$(wc -l < "$CSV_FILE")
        echo "CSV created: $CSV_FILE ($CSV_LINES lines)"
    fi
else
    echo "ERROR: Trace file not created: $TRACE_FILE"
    exit 1
fi

# Save dmesg
sudo dmesg > "$RESULTS_DIR/hackbench_long_dmesg.log"

echo ""
echo "=========================================="
echo "Long test completed!"
echo "Trace file: $TRACE_FILE"
echo "CSV file: $CSV_FILE"
echo "Ready to pull and analyze"
echo "=========================================="

