#!/bin/bash
# Simple script to run scx_nest with proper trace capture
# Runs control and test separately, capturing trace for each
# Usage: run_nest_trace_simple.sh <workload> <duration> [iterations]

set -e

WORKLOAD=$1
DURATION=$2
ITERATIONS=${3:-3}

if [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <workload> <duration> [iterations]" >&2
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

source "$BASE_DIR/config/test_config.sh"

CONTROL_BIN="../build/scheds/c/scx_nest_control"
TEST_BIN="../build/scheds/c/scx_nest_test"

# Cleanup function
cleanup() {
    sudo pkill -f "cat.*trace_pipe" 2>/dev/null || true
    sudo pkill -f "scx_nest_control" 2>/dev/null || true
    sudo pkill -f "scx_nest_test" 2>/dev/null || true
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
    
    # Clear trace buffer
    echo > /sys/kernel/debug/tracing/trace
    
    # Start trace capture
    echo "    Starting trace capture..."
    sudo bash -c "cat /sys/kernel/debug/tracing/trace_pipe > '$TRACE_FILE'" &
    TRACE_PID=$!
    sleep 1
    
    # Verify trace is running
    if ! kill -0 $TRACE_PID 2>/dev/null; then
        echo "    ERROR: Trace capture failed to start"
        continue
    fi
    
    # Start scheduler
    echo "    Starting scheduler..."
    sudo "$CONTROL_BIN" >/tmp/scheduler_control.log 2>&1 &
    SCHED_PID=$!
    sleep 2
    
    # Check if scheduler loaded
    if [ -f /sys/kernel/sched_ext/state ]; then
        STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
        if [ "$STATE" = "disabled" ]; then
            echo "    ERROR: Scheduler not loaded"
            sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
            continue
        fi
        echo "    Scheduler loaded: $STATE"
    fi
    
    # Run workload
    echo "    Running workload..."
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
    esac
    
    # Wait for duration
    sleep "$DURATION"
    
    # Stop everything
    echo "    Stopping..."
    sudo kill $SCHED_PID 2>/dev/null || true
    kill $WORKLOAD_PID 2>/dev/null || true
    wait $SCHED_PID 2>/dev/null || true
    wait $WORKLOAD_PID 2>/dev/null || true
    
    # Stop trace (give it a moment to flush)
    sleep 1
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Check trace file
    if [ -f "$TRACE_FILE" ] && [ -s "$TRACE_FILE" ]; then
        LINES=$(wc -l < "$TRACE_FILE")
        echo "    Trace captured: $LINES lines"
        
        # Parse trace
        echo "    Parsing trace..."
        ./scripts/parse_trace_for_metrics.sh "$TRACE_FILE" "$CSV_FILE" || true
    else
        echo "    WARNING: Trace file empty or missing"
    fi
    
    # Save dmesg
    sudo dmesg > "$RESULTS_DIR/control/${WORKLOAD}_run${iter}_dmesg.log"
    sudo dmesg -C
    
    sleep 2
    
    # TEST RUN
    echo ""
    echo "Running TEST version..."
    TRACE_FILE="$RESULTS_DIR/test/${WORKLOAD}_run${iter}_trace.txt"
    CSV_FILE="$RESULTS_DIR/test/${WORKLOAD}_run${iter}.csv"
    
    # Clear trace buffer
    echo > /sys/kernel/debug/tracing/trace
    
    # Start trace capture
    echo "    Starting trace capture..."
    sudo bash -c "cat /sys/kernel/debug/tracing/trace_pipe > '$TRACE_FILE'" &
    TRACE_PID=$!
    sleep 1
    
    # Verify trace is running
    if ! kill -0 $TRACE_PID 2>/dev/null; then
        echo "    ERROR: Trace capture failed to start"
        continue
    fi
    
    # Start scheduler
    echo "    Starting scheduler..."
    sudo "$TEST_BIN" >/tmp/scheduler_test.log 2>&1 &
    SCHED_PID=$!
    sleep 2
    
    # Check if scheduler loaded
    if [ -f /sys/kernel/sched_ext/state ]; then
        STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
        if [ "$STATE" = "disabled" ]; then
            echo "    ERROR: Scheduler not loaded"
            sudo kill $SCHED_PID $TRACE_PID 2>/dev/null || true
            continue
        fi
        echo "    Scheduler loaded: $STATE"
    fi
    
    # Run workload
    echo "    Running workload..."
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
    esac
    
    # Wait for duration
    sleep "$DURATION"
    
    # Stop everything
    echo "    Stopping..."
    sudo kill $SCHED_PID 2>/dev/null || true
    kill $WORKLOAD_PID 2>/dev/null || true
    wait $SCHED_PID 2>/dev/null || true
    wait $WORKLOAD_PID 2>/dev/null || true
    
    # Stop trace (give it a moment to flush)
    sleep 1
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Check trace file
    if [ -f "$TRACE_FILE" ] && [ -s "$TRACE_FILE" ]; then
        LINES=$(wc -l < "$TRACE_FILE")
        echo "    Trace captured: $LINES lines"
        
        # Quick check for cleanup messages
        CLEANUP_COUNT=$(grep -c "Map cleanup" "$TRACE_FILE" 2>/dev/null || echo "0")
        EVICT_COUNT=$(grep -c "evicted" "$TRACE_FILE" 2>/dev/null || echo "0")
        echo "    Cleanup messages: $CLEANUP_COUNT, Evictions: $EVICT_COUNT"
        
        # Parse trace
        echo "    Parsing trace..."
        ./scripts/parse_trace_for_metrics.sh "$TRACE_FILE" "$CSV_FILE" || true
    else
        echo "    WARNING: Trace file empty or missing"
    fi
    
    # Save dmesg
    sudo dmesg > "$RESULTS_DIR/test/${WORKLOAD}_run${iter}_dmesg.log"
    sudo dmesg -C
    
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
echo "Results: $RESULTS_DIR"
echo "Paper report: results/paper_report_scx_nest_${WORKLOAD}.txt"
echo ""
echo "View report:"
echo "  cat results/paper_report_scx_nest_${WORKLOAD}.txt"
echo ""

