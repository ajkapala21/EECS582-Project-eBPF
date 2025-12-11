#!/bin/bash
# Test for map cleanup helper - 60 second test

set -e
SCHEDULER="./build/scheds/c/scx_simple"
TEST_DURATION=60
LOG_FILE="/tmp/mapcleanup_test.log"

# Output colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================"
echo "Map Cleanup Helper - 60s Test"
echo "================================"

log() {
	echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

# Check dependencies
log "Checking dependencies..."
if ! command_exists stress-ng; then
	log "${YELLOW}Installing stress-ng...${NC}"
	sudo apt-get update -qq
	sudo apt-get install -y stress-ng > /dev/null 2>&1
fi

# Clear dmesg
log "Clearing dmesg..."
sudo dmesg -C

# Start scheduler
log "Starting scheduler..."
sudo $SCHEDULER > /dev/null 2>&1 &
SCHED_PID=$!
sleep 2

# Start workload
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
sleep 1

# Check if cleanup occurred
echo ""
echo "================================"
echo "RESULTS"
echo "================================"

TOTAL_CLEANUPS=$(sudo dmesg | grep -c "Map cleanup:" || echo "0")

if [ "${TOTAL_CLEANUPS:-0}" -gt 0 ]; then
	echo -e "${GREEN}SUCCESS: Map cleanup helper is working!${NC}"
	echo ""
	echo "Recent cleanup messages:"
	sudo dmesg | grep "Map cleanup:" | tail -5
	exit 0
else
	echo -e "${YELLOW}No cleanup cycles detected${NC}"
	exit 1
fi


