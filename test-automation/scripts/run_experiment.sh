#!/bin/bash
# Main experiment runner
# Usage: run_experiment.sh <scheduler> <workload> <duration> [iterations]

set -e

SCHEDULER=$1
WORKLOAD=$2
DURATION=$3
ITERATIONS=${4:-3}

if [ -z "$SCHEDULER" ] || [ -z "$WORKLOAD" ] || [ -z "$DURATION" ]; then
    echo "Usage: $0 <scheduler> <workload> <duration> [iterations]" >&2
    echo "  scheduler: scx_simple, scx_cfsish, scx_flatcg, scx_nest" >&2
    echo "  workload: stress-ng, hackbench, custom-churn" >&2
    echo "  duration: test duration in seconds" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/test_config.sh"

RESULTS_DIR="$BASE_DIR/results/$SCHEDULER"
mkdir -p "$RESULTS_DIR/control" "$RESULTS_DIR/test"

MAP_NAME=${MAP_NAMES[$SCHEDULER]}
if [ -z "$MAP_NAME" ]; then
    echo "ERROR: Unknown scheduler $SCHEDULER" >&2
    exit 1
fi

# Build schedulers
echo "Building schedulers..."
"$SCRIPT_DIR/build_schedulers.sh" "$SCHEDULER" || exit 1

SCHEDULER_BIN_DIR="$BASE_DIR/../build/scheds/c"
CONTROL_BIN="$SCHEDULER_BIN_DIR/${SCHEDULER}_control"
TEST_BIN="$SCHEDULER_BIN_DIR/${SCHEDULER}_test"

if [ ! -f "$CONTROL_BIN" ] || [ ! -f "$TEST_BIN" ]; then
    echo "ERROR: Scheduler binaries not found" >&2
    exit 1
fi

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    sudo pkill -f "${SCHEDULER}_control" 2>/dev/null || true
    sudo pkill -f "${SCHEDULER}_test" 2>/dev/null || true
    sudo pkill -f stress-ng 2>/dev/null || true
    sudo pkill -f hackbench 2>/dev/null || true
    sudo pkill -f collect_metrics 2>/dev/null || true
}

trap cleanup EXIT

# Setup: clear dmesg, drop caches, set CPU governor
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
    METRICS_FILE="$RESULTS_DIR/control/${WORKLOAD}_run${iter}.csv"
    DMESG_FILE="$RESULTS_DIR/control/${WORKLOAD}_run${iter}_dmesg.log"
    
    # Verify binary exists and is executable
    if [ ! -f "$CONTROL_BIN" ]; then
        echo "ERROR: Scheduler binary not found: $CONTROL_BIN"
        echo "Please run: ./scripts/build_schedulers.sh $SCHEDULER"
        exit 1
    fi
    
    if [ ! -x "$CONTROL_BIN" ]; then
        echo "ERROR: Scheduler binary is not executable: $CONTROL_BIN"
        exit 1
    fi
    
    # Clear previous log
    > /tmp/scheduler_control.log
    
    # Start scheduler
    echo "    Starting scheduler: $CONTROL_BIN"
    sudo "$CONTROL_BIN" >/tmp/scheduler_control.log 2>&1 &
    SCHED_PID=$!
    
    # Give it a moment to start
    sleep 0.5
    
    # Check if process started successfully
    if ! kill -0 $SCHED_PID 2>/dev/null; then
        echo "    ERROR: Scheduler process died immediately after starting!"
        echo "    Log output:"
        cat /tmp/scheduler_control.log
        exit 1
    fi
    
    # Wait for scheduler to load and verify it's actually running
    SCHED_NAME=$(echo "$SCHEDULER" | sed 's/^scx_//')
    MAX_WAIT=10
    WAITED=0
    LOADED=false
    
    while [ $WAITED -lt $MAX_WAIT ]; do
        sleep 1
        WAITED=$((WAITED + 1))
        
        # Check if process died
        if ! kill -0 $SCHED_PID 2>/dev/null; then
            echo "    ERROR: Scheduler process died after ${WAITED}s. Log:"
            tail -30 /tmp/scheduler_control.log
            exit 1
        fi
        
        # Check if scheduler loaded
        # Try /sys/kernel/sched_ext/state first (newer kernels)
        if [ -f /sys/kernel/sched_ext/state ]; then
            SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
            if [ "$SCHED_STATE" != "disabled" ] && [ -n "$SCHED_STATE" ]; then
                # State might be "enabled" or contain scheduler name
                if echo "$SCHED_STATE" | grep -qE "$SCHED_NAME|$SCHEDULER|enabled|simple"; then
                    echo "    Scheduler loaded: state=$SCHED_STATE (after ${WAITED}s)"
                    LOADED=true
                    break
                fi
            fi
        # Fallback to /sys/kernel/sched_ext/current (older kernels)
        elif [ -f /sys/kernel/sched_ext/current ]; then
            CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "")
            if [ -n "$CURRENT_SCHED" ] && [ "$CURRENT_SCHED" != "none" ]; then
                if echo "$CURRENT_SCHED" | grep -qE "$SCHED_NAME|$SCHEDULER|simple"; then
                    echo "    Scheduler loaded: $CURRENT_SCHED (after ${WAITED}s)"
                    LOADED=true
                    break
                fi
            fi
        fi
    done
    
    if [ "$LOADED" = false ]; then
        echo "WARNING: Scheduler may not have loaded properly after ${MAX_WAIT}s."
        echo "    Expected: $SCHED_NAME or $SCHEDULER"
        
        # Check if the sched_ext directory exists
        if [ ! -d /sys/kernel/sched_ext ]; then
            echo "    ERROR: /sys/kernel/sched_ext directory doesn't exist!"
            echo "    This means sched_ext is not enabled in the kernel."
            echo "    Please ensure CONFIG_SCHED_CLASS_EXT=y is set."
        else
            # Check state file (newer kernels)
            if [ -f /sys/kernel/sched_ext/state ]; then
                SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "unknown")
                echo "    State: $SCHED_STATE"
                if [ "$SCHED_STATE" = "disabled" ]; then
                    CURRENT_SCHED="none"
                else
                    CURRENT_SCHED="$SCHED_STATE"
                fi
            # Fallback to current file (older kernels)
            elif [ -f /sys/kernel/sched_ext/current ]; then
                CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "none")
                echo "    Current: $CURRENT_SCHED"
            else
                echo "    WARNING: Neither state nor current file found in /sys/kernel/sched_ext/"
                CURRENT_SCHED="none"
            fi
        fi
        
        echo ""
        echo "    Full scheduler log (/tmp/scheduler_control.log):"
        echo "    ========================================="
        if [ -f /tmp/scheduler_control.log ]; then
            cat /tmp/scheduler_control.log
        else
            echo "    Log file not found!"
        fi
        echo "    ========================================="
        echo ""
        echo "    Process still running: $(kill -0 $SCHED_PID 2>/dev/null && echo 'yes' || echo 'no')"
        
        # Check for BPF verifier errors in dmesg
        echo ""
        echo "    Recent BPF/dmesg errors:"
        dmesg | tail -20 | grep -iE "bpf|sched_ext|verifier|error" || echo "    (no recent BPF errors in dmesg)"
        
        # Try to check if map exists
        echo ""
        echo "    Checking for BPF maps:"
        "$SCRIPT_DIR/check_map.sh" "$SCHEDULER" "${MAP_NAME}" 2>&1 | head -30 || echo "    (could not check maps)"
        
        # Don't exit - continue to see if it works anyway
    fi
    
    # Verify scheduler is still loaded before starting metrics
    if [ -f /sys/kernel/sched_ext/state ]; then
        SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
        if [ "$SCHED_STATE" = "disabled" ] || [ -z "$SCHED_STATE" ]; then
            echo "    ERROR: Scheduler not loaded before starting metrics collection"
            echo "    State: ${SCHED_STATE:-disabled}"
            sudo kill $SCHED_PID 2>/dev/null || true
            exit 1
        fi
    elif [ -f /sys/kernel/sched_ext/current ]; then
        CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "")
        if [ -z "$CURRENT_SCHED" ] || [ "$CURRENT_SCHED" = "none" ]; then
            echo "    ERROR: Scheduler not loaded before starting metrics collection"
            echo "    Current: ${CURRENT_SCHED:-none}"
            sudo kill $SCHED_PID 2>/dev/null || true
            exit 1
        fi
    else
        echo "    WARNING: /sys/kernel/sched_ext/state and /sys/kernel/sched_ext/current don't exist"
        echo "    Scheduler may not be loaded, but continuing anyway..."
    fi
    
    # Start metrics collection
    "$SCRIPT_DIR/collect_metrics.sh" "$SCHEDULER" "$MAP_NAME" "$METRICS_FILE" "$DURATION" &
    METRICS_PID=$!
    
    # Run workload
    case "$WORKLOAD" in
        stress-ng)
            WORKLOAD_PID=$("$SCRIPT_DIR/workloads/stress_ng_workload.sh" "$STRESS_NG_PROCESSES" "$DURATION")
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
            echo "ERROR: Unknown workload $WORKLOAD" >&2
            exit 1
            ;;
    esac
    
    # Wait for workload
    sleep "$DURATION"
    wait $WORKLOAD_PID 2>/dev/null || true
    
    # Stop scheduler and metrics
    sudo kill $SCHED_PID 2>/dev/null || true
    kill $METRICS_PID 2>/dev/null || true
    wait $SCHED_PID 2>/dev/null || true
    wait $METRICS_PID 2>/dev/null || true
    
    # Save dmesg
    sudo dmesg > "$DMESG_FILE"
    sudo dmesg -C
    
    echo "Control run $iter completed. Results: $METRICS_FILE"
    
    # TEST RUN
    echo ""
    echo "Running TEST version..."
    METRICS_FILE="$RESULTS_DIR/test/${WORKLOAD}_run${iter}.csv"
    DMESG_FILE="$RESULTS_DIR/test/${WORKLOAD}_run${iter}_dmesg.log"
    
    # Verify binary exists and is executable
    if [ ! -f "$TEST_BIN" ]; then
        echo "ERROR: Scheduler binary not found: $TEST_BIN"
        echo "Please run: ./scripts/build_schedulers.sh $SCHEDULER"
        exit 1
    fi
    
    if [ ! -x "$TEST_BIN" ]; then
        echo "ERROR: Scheduler binary is not executable: $TEST_BIN"
        exit 1
    fi
    
    # Clear previous log
    > /tmp/scheduler_test.log
    
    # Start scheduler
    echo "    Starting scheduler: $TEST_BIN"
    sudo "$TEST_BIN" >/tmp/scheduler_test.log 2>&1 &
    SCHED_PID=$!
    
    # Give it a moment to start
    sleep 0.5
    
    # Check if process started successfully
    if ! kill -0 $SCHED_PID 2>/dev/null; then
        echo "    ERROR: Scheduler process died immediately after starting!"
        echo "    Log output:"
        cat /tmp/scheduler_test.log
        exit 1
    fi
    
    # Wait for scheduler to load and verify it's actually running
    SCHED_NAME=$(echo "$SCHEDULER" | sed 's/^scx_//')
    MAX_WAIT=10
    WAITED=0
    LOADED=false
    
    while [ $WAITED -lt $MAX_WAIT ]; do
        sleep 1
        WAITED=$((WAITED + 1))
        
        # Check if process died
        if ! kill -0 $SCHED_PID 2>/dev/null; then
            echo "    ERROR: Scheduler process died after ${WAITED}s. Log:"
            tail -30 /tmp/scheduler_test.log
            exit 1
        fi
        
        # Check if scheduler loaded
        # Try /sys/kernel/sched_ext/state first (newer kernels)
        if [ -f /sys/kernel/sched_ext/state ]; then
            SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
            if [ "$SCHED_STATE" != "disabled" ] && [ -n "$SCHED_STATE" ]; then
                # State might be "enabled" or contain scheduler name
                if echo "$SCHED_STATE" | grep -qE "$SCHED_NAME|$SCHEDULER|enabled|simple"; then
                    echo "    Scheduler loaded: state=$SCHED_STATE (after ${WAITED}s)"
                    LOADED=true
                    break
                fi
            fi
        # Fallback to /sys/kernel/sched_ext/current (older kernels)
        elif [ -f /sys/kernel/sched_ext/current ]; then
            CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "")
            if [ -n "$CURRENT_SCHED" ] && [ "$CURRENT_SCHED" != "none" ]; then
                if echo "$CURRENT_SCHED" | grep -qE "$SCHED_NAME|$SCHEDULER|simple"; then
                    echo "    Scheduler loaded: $CURRENT_SCHED (after ${WAITED}s)"
                    LOADED=true
                    break
                fi
            fi
        fi
    done
    
    if [ "$LOADED" = false ]; then
        echo "WARNING: Scheduler may not have loaded properly after ${MAX_WAIT}s."
        echo "    Expected: $SCHED_NAME or $SCHEDULER"
        
        # Check if the sched_ext directory exists
        if [ ! -d /sys/kernel/sched_ext ]; then
            echo "    ERROR: /sys/kernel/sched_ext directory doesn't exist!"
            echo "    This means sched_ext is not enabled in the kernel."
            echo "    Please ensure CONFIG_SCHED_CLASS_EXT=y is set."
        else
            # Check state file (newer kernels)
            if [ -f /sys/kernel/sched_ext/state ]; then
                SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "unknown")
                echo "    State: $SCHED_STATE"
                if [ "$SCHED_STATE" = "disabled" ]; then
                    CURRENT_SCHED="none"
                else
                    CURRENT_SCHED="$SCHED_STATE"
                fi
            # Fallback to current file (older kernels)
            elif [ -f /sys/kernel/sched_ext/current ]; then
                CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "none")
                echo "    Current: $CURRENT_SCHED"
            else
                echo "    WARNING: Neither state nor current file found in /sys/kernel/sched_ext/"
                CURRENT_SCHED="none"
            fi
        fi
        
        echo ""
        echo "    Full scheduler log (/tmp/scheduler_test.log):"
        echo "    ========================================="
        if [ -f /tmp/scheduler_test.log ]; then
            cat /tmp/scheduler_test.log
        else
            echo "    Log file not found!"
        fi
        echo "    ========================================="
        echo ""
        echo "    Process still running: $(kill -0 $SCHED_PID 2>/dev/null && echo 'yes' || echo 'no')"
        
        # Check for BPF verifier errors in dmesg
        echo ""
        echo "    Recent BPF/dmesg errors:"
        dmesg | tail -20 | grep -iE "bpf|sched_ext|verifier|error" || echo "    (no recent BPF errors in dmesg)"
        
        # Try to check if map exists
        echo ""
        echo "    Checking for BPF maps:"
        "$SCRIPT_DIR/check_map.sh" "$SCHEDULER" "${MAP_NAME}" 2>&1 | head -30 || echo "    (could not check maps)"
        
        # Don't exit - continue to see if it works anyway
    fi
    
    # Verify scheduler is still loaded before starting metrics
    if [ -f /sys/kernel/sched_ext/state ]; then
        SCHED_STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "disabled")
        if [ "$SCHED_STATE" = "disabled" ] || [ -z "$SCHED_STATE" ]; then
            echo "    ERROR: Scheduler not loaded before starting metrics collection"
            echo "    State: ${SCHED_STATE:-disabled}"
            sudo kill $SCHED_PID 2>/dev/null || true
            exit 1
        fi
    elif [ -f /sys/kernel/sched_ext/current ]; then
        CURRENT_SCHED=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "")
        if [ -z "$CURRENT_SCHED" ] || [ "$CURRENT_SCHED" = "none" ]; then
            echo "    ERROR: Scheduler not loaded before starting metrics collection"
            echo "    Current: ${CURRENT_SCHED:-none}"
            sudo kill $SCHED_PID 2>/dev/null || true
            exit 1
        fi
    else
        echo "    WARNING: /sys/kernel/sched_ext/state and /sys/kernel/sched_ext/current don't exist"
        echo "    Scheduler may not be loaded, but continuing anyway..."
    fi
    
    # Start metrics collection
    "$SCRIPT_DIR/collect_metrics.sh" "$SCHEDULER" "$MAP_NAME" "$METRICS_FILE" "$DURATION" &
    METRICS_PID=$!
    
    # Run workload
    case "$WORKLOAD" in
        stress-ng)
            WORKLOAD_PID=$("$SCRIPT_DIR/workloads/stress_ng_workload.sh" "$STRESS_NG_PROCESSES" "$DURATION")
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
    
    # Wait for workload
    sleep "$DURATION"
    wait $WORKLOAD_PID 2>/dev/null || true
    
    # Stop scheduler and metrics
    sudo kill $SCHED_PID 2>/dev/null || true
    kill $METRICS_PID 2>/dev/null || true
    wait $SCHED_PID 2>/dev/null || true
    wait $METRICS_PID 2>/dev/null || true
    
    # Save dmesg
    sudo dmesg > "$DMESG_FILE"
    sudo dmesg -C
    
    echo "Test run $iter completed. Results: $METRICS_FILE"
    
    # Brief pause between iterations
    sleep 2
done

echo ""
echo "=========================================="
echo "All iterations completed!"
echo "Results saved in: $RESULTS_DIR"
echo "=========================================="

# Generate summary
"$SCRIPT_DIR/aggregate_results.sh" "$SCHEDULER" "$WORKLOAD"

