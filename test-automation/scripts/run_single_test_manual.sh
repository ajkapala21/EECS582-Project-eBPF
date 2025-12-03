#!/bin/bash
# Simple manual test runner - captures trace properly
# Usage: run_single_test_manual.sh <control|test> <workload> <duration>

set -e

VERSION=$1  # "control" or "test"
WORKLOAD=$2
DURATION=$3

if [ -z "$VERSION" ] || [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <control|test> <workload> <duration>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BASE_DIR"

source "$BASE_DIR/config/test_config.sh"

RESULTS_DIR="results/scx_nest/$VERSION"
mkdir -p "$RESULTS_DIR"

if [ "$VERSION" = "control" ]; then
    SCHED_BIN="../build/scheds/c/scx_nest_control"
else
    SCHED_BIN="../build/scheds/c/scx_nest_test"
fi

TRACE_FILE="$RESULTS_DIR/${WORKLOAD}_manual_trace.txt"
CSV_FILE="$RESULTS_DIR/${WORKLOAD}_manual.csv"

echo "=========================================="
echo "Running $VERSION version"
echo "Workload: $WORKLOAD"
echo "Duration: $DURATION seconds"
echo "=========================================="
echo ""

# Clear trace buffer
echo "Clearing trace buffer..."
echo | sudo tee /sys/kernel/debug/tracing/trace >/dev/null

# Start trace capture in background
echo "Starting trace capture to: $TRACE_FILE"
sudo cat /sys/kernel/debug/tracing/trace_pipe > "$TRACE_FILE" &
TRACE_PID=$!
sleep 1

# Verify trace is running
if ! kill -0 $TRACE_PID 2>/dev/null; then
    echo "ERROR: Trace capture failed to start"
    exit 1
fi
echo "Trace capture running (PID: $TRACE_PID)"

# Start scheduler
echo "Starting scheduler: $SCHED_BIN"
sudo "$SCHED_BIN" >/tmp/scheduler_${VERSION}.log 2>&1 &
SCHED_PID=$!
sleep 2

# Check if scheduler loaded
if [ -f /sys/kernel/sched_ext/state ]; then
    STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
    if [ "$STATE" = "disabled" ]; then
        echo "ERROR: Scheduler not loaded. Check /tmp/scheduler_${VERSION}.log"
        sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
        exit 1
    fi
    echo "Scheduler loaded: $STATE"
else
    echo "WARNING: Cannot check scheduler state"
fi

# Run workload
echo "Starting workload..."
case "$WORKLOAD" in
    stress-ng)
        "$SCRIPT_DIR/workloads/stress_ng_workload.sh" "$STRESS_NG_PROCESSES" "$DURATION" &
        WORKLOAD_PID=$!
        ;;
    hackbench)
        "$SCRIPT_DIR/workloads/hackbench_workload.sh" "$HACKBENCH_PROCESSES" "$HACKBENCH_LOOPS" &
        WORKLOAD_PID=$!
        ;;
    custom-churn)
        "$SCRIPT_DIR/workloads/custom_churn_workload.sh" "$CUSTOM_CHURN_SPAWNS" "$DURATION" &
        WORKLOAD_PID=$!
        ;;
    *)
        echo "ERROR: Unknown workload $WORKLOAD"
        sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
        exit 1
        ;;
esac

echo "Workload running. Waiting $DURATION seconds..."
echo "(Trace is being captured to $TRACE_FILE)"

# Wait for duration
sleep "$DURATION"

# Stop everything
echo ""
echo "Stopping workload and scheduler..."
kill $WORKLOAD_PID 2>/dev/null || true
wait $WORKLOAD_PID 2>/dev/null || true

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
    echo ""
    echo "=========================================="
    echo "Trace captured: $LINES lines"
    echo "File: $TRACE_FILE"
    echo "=========================================="
    
    if [ "$VERSION" = "test" ]; then
        echo ""
        echo "Cleanup activity:"
        echo "  Cleanup scans: $(grep -c 'Map cleanup: Starting cleanup scan' "$TRACE_FILE" 2>/dev/null || echo 0)"
        echo "  Eviction messages: $(grep -c 'timeout after evicted' "$TRACE_FILE" 2>/dev/null || echo 0)"
        echo "  Tasks added: $(grep -c 'Added new task' "$TRACE_FILE" 2>/dev/null || echo 0)"
        
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
        echo "CSV created: $CSV_FILE"
        echo "CSV lines: $(wc -l < "$CSV_FILE")"
    fi
else
    echo "ERROR: Trace file not created: $TRACE_FILE"
    exit 1
fi

# Save dmesg
sudo dmesg > "$RESULTS_DIR/${WORKLOAD}_manual_dmesg.log"

echo ""
echo "=========================================="
echo "Test completed!"
echo "Trace file: $TRACE_FILE"
echo "CSV file: $CSV_FILE"
echo "=========================================="

