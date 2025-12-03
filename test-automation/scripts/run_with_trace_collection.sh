#!/bin/bash
# Run experiment with trace_pipe-based metrics collection
# Usage: run_with_trace_collection.sh <scheduler> <workload> <duration> [iterations]

set -e

SCHEDULER=$1
WORKLOAD=$2
DURATION=$3
ITERATIONS=${4:-3}

if [ -z "$SCHEDULER" ] || [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <scheduler> <workload> <duration> [iterations]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$BASE_DIR/results/$SCHEDULER"

mkdir -p "$RESULTS_DIR/control" "$RESULTS_DIR/test"

# Cleanup function
cleanup() {
    echo "Cleaning up trace capture..."
    sudo pkill -f "cat.*trace_pipe" 2>/dev/null || true
    sudo pkill -f "${SCHEDULER}_control" 2>/dev/null || true
    sudo pkill -f "${SCHEDULER}_test" 2>/dev/null || true
    sudo pkill -f stress-ng 2>/dev/null || true
    sudo pkill -f hackbench 2>/dev/null || true
}

trap cleanup EXIT

# Setup
echo "Setting up test environment..."
sudo dmesg -C
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true

for iter in $(seq 1 $ITERATIONS); do
    echo ""
    echo "=========================================="
    echo "Iteration $iter of $ITERATIONS"
    echo "=========================================="
    
    # CONTROL RUN
    echo ""
    echo "Running CONTROL version..."
    TRACE_FILE="$RESULTS_DIR/control/${WORKLOAD}_run${iter}_trace.txt"
    CSV_FILE="$RESULTS_DIR/control/${WORKLOAD}_run${iter}.csv"
    
    # Start trace capture
    sudo cat /sys/kernel/debug/tracing/trace_pipe > "$TRACE_FILE" 2>/dev/null &
    TRACE_PID=$!
    sleep 0.5
    
    # Run the experiment (use original script but capture trace)
    "$SCRIPT_DIR/run_experiment.sh" "$SCHEDULER" "$WORKLOAD" "$DURATION" 1
    
    # Stop trace capture
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Parse trace to CSV
    if [ -f "$TRACE_FILE" ]; then
        "$SCRIPT_DIR/parse_trace_for_metrics.sh" "$TRACE_FILE" "$CSV_FILE"
    fi
    
    # Clear trace for next run
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2
done

# Generate paper report
echo ""
echo "Generating paper-ready report..."
"$SCRIPT_DIR/generate_paper_report.sh" "$SCHEDULER" "$WORKLOAD"

echo ""
echo "=========================================="
echo "Experiment completed!"
echo "Results: $RESULTS_DIR"
echo "Paper report: results/paper_report_${SCHEDULER}_${WORKLOAD}.txt"
echo "=========================================="

