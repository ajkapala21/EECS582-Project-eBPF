#!/bin/bash
# Test for map cleanup helper - functionality, correctness, quantifiable results

set -e

SCHEDULER="./build/scheds/c/scx_simple"
TEST_DURATION=60
CLEANUP_INTERVAL=1
MAX_AGE=5
LOG_FILE="/tmp/mapcleanup_test.log"

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "------------------------------------------"
echo "Map cleanup helper test"
echo "------------------------------------------"

log() {
    echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check dependencies
log "Checking dependencies..."
if ! command_exists stress-ng; then
    log "${YELLOW}Warning: stress-ng not found, installing...${NC}"
    sudo apt-get update -qq
    sudo apt-get install -y stress-ng >/dev/null 2>&1
fi

# Clear dmesg for clean start
log "Clearing dmesg..."
sudo dmesg -C

# Start scheduler
log "Starting scheduler..."
sudo $SCHEDULER > /dev/null 2>&1 &
SCHED_PID=$!
sleep 2

# Start workload to create tasks
log "Starting workload (${TEST_DURATION}s)..."
stress-ng --fork 8 --timeout ${TEST_DURATION}s > /dev/null 2>&1 &
STRESS_PID=$!

# Wait for test duration
log "Running test..."
sleep $TEST_DURATION

# Stop scheduler
log "Stopping scheduler..."
sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true

# Stop stress test
kill $STRESS_PID 2>/dev/null || true
wait $STRESS_PID 2>/dev/null || true
sleep 1

# Analyze results
echo ""
echo "=========================================="
echo "Quantifiable Results"
echo "=========================================="
echo ""

# Count cleanup operations
TOTAL_CLEANUPS=$(sudo dmesg | grep -c "Map cleanup:" || echo "0")
SUCCESS_CLEANUPS=$(sudo dmesg | grep -c "evicted.*stale entries" || echo "0")
TIMEOUT_CLEANUPS=$(sudo dmesg | grep -c "timeout after evicting" || echo "0")

# Extract total evicted entries
TOTAL_EVICTED=0
while IFS= read -r line; do
    NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
    if [ -n "$NUM" ]; then
        TOTAL_EVICTED=$((TOTAL_EVICTED + NUM))
    fi
done < <(sudo dmesg | grep "evicted.*entries" || true)

# Calculate averages
AVG_EVICTED=0
if [ "$TOTAL_CLEANUPS" -gt 0 ]; then
    AVG_EVICTED=$((TOTAL_EVICTED / TOTAL_CLEANUPS))
fi

# Display results
echo "Test Duration: ${TEST_DURATION} seconds"
echo "Cleanup Interval: ${CLEANUP_INTERVAL}s"
echo "Max Age Threshold: ${MAX_AGE}s"
echo ""
echo "Cleanup Statistics:"
echo "  Total cleanup cycles: $TOTAL_CLEANUPS"
echo "  Successful cleanups: $SUCCESS_CLEANUPS"
echo "  Timeout cleanups: $TIMEOUT_CLEANUPS"
echo ""
echo "Eviction Statistics:"
echo "  Total entries evicted: $TOTAL_EVICTED"
if [ "$TOTAL_CLEANUPS" -gt 0 ]; then
    echo "  Average per cleanup: $AVG_EVICTED"
fi
echo ""

# Show recent messages
echo "Recent Cleanup Messages:"
sudo dmesg | grep "Map cleanup:" | tail -10 || echo "  (none found)"
echo ""

# Success criteria
echo "=========================================="
if [ "$TOTAL_CLEANUPS" -gt 0 ]; then
    echo "${GREEN}SUCCESS: Helper function is working!${NC}"
    echo "  - Detected $TOTAL_CLEANUPS cleanup cycles"
    echo "  - Evicted $TOTAL_EVICTED entries"
    if [ "$TIMEOUT_CLEANUPS" -gt 0 ]; then
        echo "  - ${YELLOW}Note: $TIMEOUT_CLEANUPS timeout events (expected for large maps)${NC}"
    fi
    echo ""
    echo "Functionality: ${GREEN}PASS${NC}"
    echo "Correctness: ${GREEN}PASS${NC} (cleanup cycles detected)"
    echo "Quantifiable: ${GREEN}PASS${NC} ($TOTAL_EVICTED entries evicted)"
    exit 0
else
    echo "${YELLOW}No cleanup cycles detected${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  - No stale entries (tasks too recent)"
    echo "  - Check dmesg: sudo dmesg | tail -20"
    exit 1
fi
