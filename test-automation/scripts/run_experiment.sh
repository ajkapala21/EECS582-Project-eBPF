#!/bin/bash
# Simplified experiment runner for scx_nest with hackbench
# Usage: run_experiment.sh <scheduler> <workload> <duration> [iterations]
#
# To view map cleanup evictions in real-time, run in another terminal:
#   sudo cat /sys/kernel/debug/tracing/trace_pipe

set -e

SCHEDULER=$1
WORKLOAD=$2
DURATION=$3
ITERATIONS=${4:-1}

if [ -z "$SCHEDULER" ] || [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <scheduler> <workload> <duration> [iterations]" >&2
    echo "  scheduler: scx_simple, scx_cfsish, scx_flatcg, scx_nest" >&2
    echo "  workload: hackbench" >&2
    echo "  duration: test duration in seconds" >&2
    echo "" >&2
    echo "Example: $0 scx_nest hackbench 60 1" >&2
    echo "" >&2
    echo "To view evictions, run in another terminal:" >&2
    echo "  sudo cat /sys/kernel/debug/tracing/trace_pipe" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/test_config.sh"

# Build schedulers
echo "========================================"
echo "Building $SCHEDULER (control and test versions)..."
echo "========================================"
"$SCRIPT_DIR/build_schedulers.sh" "$SCHEDULER" || exit 1

SCHEDULER_BIN_DIR="$BASE_DIR/../build/scheds/c"
CONTROL_BIN="$SCHEDULER_BIN_DIR/${SCHEDULER}_control"
TEST_BIN="$SCHEDULER_BIN_DIR/${SCHEDULER}_test"

if [ ! -f "$CONTROL_BIN" ] || [ ! -f "$TEST_BIN" ]; then
    echo "ERROR: Scheduler binaries not found" >&2
    echo "Expected: $CONTROL_BIN and $TEST_BIN" >&2
    exit 1
fi

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    sudo pkill -f "${SCHEDULER}_control" 2>/dev/null || true
    sudo pkill -f "${SCHEDULER}_test" 2>/dev/null || true
    sudo pkill -f hackbench 2>/dev/null || true
}

trap cleanup EXIT

# Setup
echo ""
echo "========================================"
echo "Setting up test environment..."
echo "========================================"
sudo dmesg -C
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true

echo ""
echo "========================================"
echo "IMPORTANT: To view map cleanup evictions,"
echo "run this in ANOTHER terminal:"
echo ""
echo "  sudo cat /sys/kernel/debug/tracing/trace_pipe"
echo ""
echo "========================================"
echo ""
read -p "Press ENTER when trace_pipe is running in another terminal..."

for iter in $(seq 1 $ITERATIONS); do
    echo ""
    echo "=========================================="
    echo "Iteration $iter of $ITERATIONS"
    echo "=========================================="
    
    # TEST RUN (with map cleanup)
    echo ""
    echo "Running TEST version (with map cleanup helper)..."
    echo "Scheduler: $TEST_BIN"
    echo "Duration: ${DURATION}s"
    echo ""
    
    # Start scheduler
    sudo "$TEST_BIN" >/tmp/scheduler_test.log 2>&1 &
    SCHED_PID=$!
    sleep 2
    
    # Check if scheduler loaded
    if [ -f /sys/kernel/sched_ext/state ]; then
        SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
        echo "Scheduler state: $SCHED_STATE"
    fi
    
    # Run workload
    echo ""
    echo "Running hackbench workload for ${DURATION}s..."
    echo "(Watch trace_pipe in other terminal for eviction messages)"
    echo ""
    
    # Run hackbench in a loop for the duration
    END_TIME=$(($(date +%s) + DURATION))
    while [ $(date +%s) -lt $END_TIME ]; do
        "$SCRIPT_DIR/workloads/hackbench_workload.sh" "$HACKBENCH_PROCESSES" "$HACKBENCH_LOOPS" 2>/dev/null || true
    done
    
    # Stop scheduler
    echo ""
    echo "Stopping scheduler..."
    sudo kill $SCHED_PID 2>/dev/null || true
    wait $SCHED_PID 2>/dev/null || true
    
    echo ""
    echo "Iteration $iter completed."
    sleep 2
done

echo ""
echo "=========================================="
echo "Experiment completed!"
echo ""
echo "Check your trace_pipe terminal for output like:"
echo "  Map cleanup: evicted X stale entries"
echo "  Map cleanup: timeout after evicted X entries"
echo "=========================================="
