#!/bin/bash
# Simple 60-second test for map cleanup helper
# View evictions with: sudo cat /sys/kernel/debug/tracing/trace_pipe

set -e
SCHEDULER="./build/scheds/c/scx_simple"
TEST_DURATION=60

echo "========================================"
echo "Map Cleanup Helper - 60s Test"
echo "========================================"
echo ""
echo "To view map cleanup evictions in real-time,"
echo "run this in ANOTHER terminal:"
echo ""
echo "  sudo cat /sys/kernel/debug/tracing/trace_pipe"
echo ""
echo "========================================"
echo ""
read -p "Press ENTER when trace_pipe is running..."

# Check dependencies
if ! command -v stress-ng >/dev/null 2>&1; then
    echo "Installing stress-ng..."
    sudo apt-get update -qq
    sudo apt-get install -y stress-ng > /dev/null 2>&1
fi

# Clear dmesg
sudo dmesg -C

# Start scheduler
echo ""
echo "[$(date +%H:%M:%S)] Starting scheduler..."
sudo $SCHEDULER > /dev/null 2>&1 &
SCHED_PID=$!
sleep 2

# Start workload
echo "[$(date +%H:%M:%S)] Starting workload (${TEST_DURATION}s)..."
echo ""
echo "(Watch trace_pipe in other terminal for eviction messages)"
echo ""
stress-ng --fork 8 --timeout ${TEST_DURATION}s > /dev/null 2>&1 &
STRESS_PID=$!

# Wait for test duration
sleep $TEST_DURATION

# Stop scheduler
echo "[$(date +%H:%M:%S)] Stopping scheduler..."
sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true

# Stop stress test
kill $STRESS_PID 2>/dev/null || true
sleep 1

echo ""
echo "========================================"
echo "Test completed!"
echo ""
echo "Check your trace_pipe terminal for output like:"
echo "  Map cleanup: evicted X stale entries"
echo "  Map cleanup: timeout after evicted X entries"
echo "========================================"
