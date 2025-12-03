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

# Refresh sudo timestamp to avoid multiple password prompts
echo "Authenticating with sudo (you may be prompted for password)..."
sudo -v

# Check if trace_pipe is already in use and kill any existing processes
echo "Checking for existing trace capture processes..."
sudo pkill -f "cat.*trace_pipe" 2>/dev/null || true
sleep 1

# Start trace capture
echo "Starting trace capture..."
sudo bash -c "cat /sys/kernel/debug/tracing/trace_pipe > '$TRACE_FILE' 2>&1" &
TRACE_PID=$!
sleep 2

if ! kill -0 $TRACE_PID 2>/dev/null; then
    echo "ERROR: Trace capture failed to start"
    echo "Check if trace_pipe is available: ls -l /sys/kernel/debug/tracing/trace_pipe"
    exit 1
fi
echo "Trace capture running (PID: $TRACE_PID)"

# Clear trace buffer
echo "Clearing trace buffer..."
sudo bash -c "echo > /sys/kernel/debug/tracing/trace"

# Start scheduler
echo "Starting scheduler..."
sudo bash -c "../build/scheds/c/scx_nest_control >/tmp/scheduler_control.log 2>&1" &
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

# Run workload continuously for the duration
echo "Starting workload (will run for $DURATION seconds)..."
# Run hackbench in a loop until duration expires
(
    START_TIME=$(date +%s)
    while [ $(($(date +%s) - START_TIME)) -lt $DURATION ]; do
        ./scripts/workloads/hackbench_workload.sh 10 100 >/dev/null 2>&1
        sleep 1  # Small delay between runs
    done
) &
WORKLOAD_PID=$!

# Wait for duration
echo "Waiting $DURATION seconds (trace is being captured)..."
sleep "$DURATION"

# Stop everything
echo ""
echo "Stopping workload and scheduler..."
kill $WORKLOAD_PID 2>/dev/null || true
wait $WORKLOAD_PID 2>/dev/null || true

# Use sudo -n to avoid password prompt (non-interactive)
sudo -n kill $SCHED_PID 2>/dev/null || sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true

# Give trace a moment to flush, then stop it
echo "Stopping trace capture..."
sleep 2
# Kill trace process and wait for it to fully terminate
sudo -n kill $TRACE_PID 2>/dev/null || sudo kill $TRACE_PID 2>/dev/null || true
# Wait up to 5 seconds for it to terminate
for i in {1..5}; do
    if ! kill -0 $TRACE_PID 2>/dev/null; then
        break
    fi
    sleep 1
done
# Force kill if still running
sudo -n kill -9 $TRACE_PID 2>/dev/null || sudo kill -9 $TRACE_PID 2>/dev/null || true
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
sudo -n dmesg > "$RESULTS_DIR/hackbench_manual_dmesg.log" 2>/dev/null || sudo dmesg > "$RESULTS_DIR/hackbench_manual_dmesg.log"

echo ""
echo "=========================================="
echo "Control test completed!"
echo "Trace file: $TRACE_FILE"
echo "Ready to pull and analyze"
echo "=========================================="

