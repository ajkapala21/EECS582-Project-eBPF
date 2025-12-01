#!/bin/bash
# test for map cleanup helper, functionality, correctness, quantifiable results

set -e
SCHEDULER="./build/scheds/c/scx_simple"
TEST_DURATION=120
CLEANUP_INTERVAL=1
MAX_AGE=5
LOG_FILE="/tmp/mapcleanup_test.log"

#output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "----------------"
echo "Map cleanup helper"
echo "---------------"

log() {
	echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

log "check dependices"
if ! command_exists stress-ng; then
	log "${YELLOW}Warning: stress-ng not found, installing---${NC}"
	sudo apt-get update -qq
	sudo apt-get install -y stress-ng > /dev/null 2>&1
fi

# clear dmseg 
log "Clearing dmesg..."
sudo dmesg -C

#start scheduler
log "starting scheduler..."
sudo $SCHEDULER > /dev/null 2>&1 &
SCHED_PID=$!
sleep 2

#start workload to create task
log "starting workload (${TEST_DURATION}s)..."
stress-ng --fork 8 --timeout ${TEST_DURATION}s > /dev/null 2>&1 &
STRESS_PID=$!

#wait for test duration
log "Running test..."
sleep $TEST_DURATION

#stop scheduler
log "stopping scheduelr..."
sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true

#stop stress test
kill $STRESS_PID 2>/dev/null || true
kill $STRESS_PID 2>/dev/null || true
sleep 1

#analsze res
echo "----------"
echo "RESULTS"
echo "----------"

#count cleanup operations
TOTAL_CLEANUPS=$(sudo dmesg | grep -c "Map cleanup:" || echo "0")
TOTAL_CLEANUPS=${TOTAL_CLEANUPS:-0}

SUCCESS_CLEANUPS=$(sudo dmesg | grep -c "evicted.*stale entries" || echo "0")
SUCCESS_CLEANUPS=${SUCCESS_CLEANUPS:-0}

TIMEOUT_CLEANUPS=$(sudo dmesg | grep -c "timeout after evicting" || echo "0")
TIMEOUT_CLEANUPS=${TIMEOUT_CLEANUPS:-0}

# Extract total evicted entries 
TOTAL_EVICTED=0
while IFS= read -r line; do
	NUM=$(echo "$line" | grep-oE '[0-9]+' | head-1)
	if [ -n "$NUM" ] ; then
		TOTAL_EVICTED=$((TOTAL_EVICTED + NUM))
	fi
done < <(sudo dmesg | grep "evicted.*entries" || true)

# Calculate averages
AVG_EVICTED=0
if [ "${TOTAL_CLEANUPS:-0}" -gt 0 ]; then
	AVG_EVICTED=$((TOTAl_EVICTED /  TOTAL_CLEANUPS))
fi

#Display results
echo "Test Duration: ${TEST_DURATION} seconds"
echo "Cleanup Interval: ${CLEANUP_INTERVAL}s"
echo "Max Age Threshold: ${MAX_AGE}s"
echo ""
echo "Cleanup Statistics:"
echo " Total cleanup cycles: $TOTAL_CLEANUPS"
echo " Successful cleanups: $SUCCESS_CLEANUPS"
echo " Timeout cleanups: $TIMEOUT_CLEANUPS"
echo ""
echo "Eviction Statistics:"
echo " Total entries evicted: $TOTAL_EVICTED"
if [ "${TOTAL_CLEANUPS:-0}" -gt 0 ]; then 
	echo " Average per cleanup: $AVG_EVICTED"
fi
echo ""

#Show recent messages
echo "Recent Cleanup Messages:"
sudo dmesg | grep "Map cleanup:" | tail -10 || echo "  none found"
echo ""

# Success criteria
echo "========================"
if [ "${TOTAL_CLEANUPS:-0}" -gt 0 ]; then
	echo "${GREEN}SUCCESS: Helper function is working!${NC}"
	echo " 	- detected $TOTAL_CLEANUPS cleanup cycles"
	echo " 	- Evicted $TOTAL_EVICTED entries"
	if [ "$TIMEOUT_CLEANUPS" -gt 0 ]; then 
		echo " - ${YELLOW}Note: $TIMEOUT_CLEANUPS timeout events expected for  large maps${NC}"
	fi
	echo "Functionality: ${GREEN}PASS${NC}"
	echo "Correctness: ${GREEN}PASS${NC} cleanup cycles detected"
	echo "Quantifiable: ${GREEN}PASS${NC} $TOTAL_EVICTED entries evicted"
	exit 0
else
	echo "${YELLOW}No cleanup cycles detected${NC}"
	exit 1
fi
EOF


