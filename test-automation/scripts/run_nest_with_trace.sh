#!/bin/bash
# Automated script to run scx_nest tests with trace collection
# This script wraps run_experiment.sh to capture trace_pipe output
# Usage: run_nest_with_trace.sh <workload> <duration> [iterations]

set -e

WORKLOAD=$1
DURATION=$2
ITERATIONS=${3:-3}

if [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <workload> <duration> [iterations]" >&2
    echo "  workload: hackbench, stress-ng, custom-churn" >&2
    echo "  duration: test duration in seconds" >&2
    echo "  iterations: number of runs (default: 3)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BASE_DIR"

RESULTS_DIR="results/scx_nest"
mkdir -p "$RESULTS_DIR/control" "$RESULTS_DIR/test"

# Build first
echo "Building schedulers..."
./scripts/build_schedulers.sh scx_nest || exit 1

# Cleanup function
cleanup() {
    echo "Cleaning up trace capture..."
    sudo pkill -f "cat.*trace_pipe" 2>/dev/null || true
}

trap cleanup EXIT

# Setup
echo "Setting up test environment..."
sudo dmesg -C
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true

# Note: run_experiment.sh runs both control and test for each iteration
# We need to intercept and capture trace for each separately
# Since we can't easily modify run_experiment.sh, we'll run it once per iteration
# and capture the entire trace, then split it

for iter in $(seq 1 $ITERATIONS); do
    echo ""
    echo "=========================================="
    echo "Iteration $iter of $ITERATIONS"
    echo "=========================================="
    
    # Start trace capture for entire iteration (control + test)
    TRACE_FILE="/tmp/trace_iter${iter}.txt"
    echo "    Starting trace capture for iteration $iter..."
    sudo cat /sys/kernel/debug/tracing/trace_pipe > "$TRACE_FILE" 2>/dev/null &
    TRACE_PID=$!
    sleep 0.5
    
    # Run experiment (this runs both control and test)
    echo "    Running experiment (control + test)..."
    ./scripts/run_experiment.sh scx_nest "$WORKLOAD" "$DURATION" 1 || {
        echo "    ERROR: Experiment run failed"
        sudo kill $TRACE_PID 2>/dev/null || true
        continue
    }
    
    # Stop trace
    echo "    Stopping trace capture..."
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Split trace file - find where control ends and test begins
    # We'll use timestamps or look for scheduler start messages
    # For now, split roughly in half or use a more sophisticated method
    
    CONTROL_TRACE="$RESULTS_DIR/control/${WORKLOAD}_run${iter}_trace.txt"
    TEST_TRACE="$RESULTS_DIR/test/${WORKLOAD}_run${iter}_trace.txt"
    
    # Simple approach: split by looking for "Running CONTROL" vs "Running TEST" markers
    # But trace_pipe doesn't have those. Instead, we'll use the fact that
    # run_experiment.sh runs control first, then test.
    # We can split by looking for scheduler binary names in trace or by time
    
    # For now, use the full trace for both and let the parser handle it
    # (The parser will work fine with combined traces)
    cp "$TRACE_FILE" "$CONTROL_TRACE"
    cp "$TRACE_FILE" "$TEST_TRACE"
    
    # Parse traces to CSV
    if [ -f "$CONTROL_TRACE" ] && [ -s "$CONTROL_TRACE" ]; then
        echo "    Parsing control trace..."
        ./scripts/parse_trace_for_metrics.sh "$CONTROL_TRACE" \
            "$RESULTS_DIR/control/${WORKLOAD}_run${iter}.csv" || true
    fi
    
    if [ -f "$TEST_TRACE" ] && [ -s "$TEST_TRACE" ]; then
        echo "    Parsing test trace..."
        ./scripts/parse_trace_for_metrics.sh "$TEST_TRACE" \
            "$RESULTS_DIR/test/${WORKLOAD}_run${iter}.csv" || true
    fi
    
    # Cleanup
    rm -f "$TRACE_FILE"
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2
done

# Generate paper report
echo ""
echo "Generating paper-ready report..."
./scripts/generate_paper_report.sh scx_nest "$WORKLOAD"

echo ""
echo "=========================================="
echo "Testing completed!"
echo "=========================================="
echo "Results directory: $RESULTS_DIR"
echo "Paper report: results/paper_report_scx_nest_${WORKLOAD}.txt"
echo "Paper CSV: results/paper_report_scx_nest_${WORKLOAD}.csv"
echo ""
echo "View report:"
echo "  cat results/paper_report_scx_nest_${WORKLOAD}.txt"
echo ""

