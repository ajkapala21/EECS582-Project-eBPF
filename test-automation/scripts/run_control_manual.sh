#!/bin/bash
# Run control version with trace capture
# Usage: run_control_manual.sh [duration]

set -e

DURATION=${1:-60}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BASE_DIR"

RESULTS_DIR="results/scx_nest/control"
mkdir -p "$RESULTS_DIR"

TRACE_FILE="$RESULTS_DIR/hackbench_manual_trace.txt"

echo "=========================================="
echo "Running CONTROL version"
echo "Duration: $DURATION seconds"
echo "Trace file: $TRACE_FILE"
echo "=========================================="
echo ""

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

# Clear trace buffer
echo "Clearing trace buffer..."
echo | sudo tee /sys/kernel/debug/tracing/trace >/dev/null

# Start scheduler
echo "Starting scheduler..."
sudo ../build/scheds/c/scx_nest_control >/tmp/scheduler_control.log 2>&1 &
SCHED_PID=$!
sleep 2

# Check if loaded
echo "Checking scheduler state..."
if [ -f /sys/kernel/sched_ext/state ]; then
    STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
    echo "Scheduler state: $STATE"
    if [ "$STATE" = "disabled" ]; then
        echo "ERROR: Scheduler not loaded. Check /tmp/scheduler_control.log"
        sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
        exit 1
    fi
else
    echo "WARNING: Cannot check scheduler state"
fi

# Run workload (run it longer or multiple times to generate more activity)
echo "Starting workload..."
./scripts/workloads/hackbench_workload.sh 10 100 &
WORKLOAD_PID=$!

# Wait for duration
echo "Waiting $DURATION seconds (trace is being captured)..."
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
    SIZE=$(du -h "$TRACE_FILE" | cut -f1)
    echo ""
    echo "=========================================="
    echo "Trace captured successfully!"
    echo "File: $TRACE_FILE"
    echo "Lines: $LINES"
    echo "Size: $SIZE"
    echo "=========================================="
    
    # Show sample of trace
    echo ""
    echo "Sample (first 5 lines):"
    head -5 "$TRACE_FILE"
    echo ""
    echo "Sample (last 5 lines):"
    tail -5 "$TRACE_FILE"
else
    echo "ERROR: Trace file not created: $TRACE_FILE"
    exit 1
fi

# Save dmesg
sudo dmesg > "$RESULTS_DIR/hackbench_manual_dmesg.log"

echo ""
echo "=========================================="
echo "Control test completed!"
echo "Trace file: $TRACE_FILE"
echo "Ready to pull and analyze"
echo "=========================================="

