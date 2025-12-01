#!/bin/bash
# Diagnostic script to check why scheduler isn't loading
# Usage: ./scripts/diagnose_scheduler.sh [scheduler_name]

set -e

SCHEDULER=${1:-scx_simple}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$BASE_DIR/.."

echo "=========================================="
echo "Scheduler Diagnostic: $SCHEDULER"
echo "=========================================="
echo ""

# 1. Check kernel support
echo "1. Checking kernel sched_ext support..."
if [ -d "/sys/kernel/sched_ext" ]; then
    echo "   ✓ /sys/kernel/sched_ext/ exists"
    STATE=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo "unknown")
    echo "   State: $STATE"
    
    if [ -f "/sys/kernel/sched_ext/current" ]; then
        CURRENT=$(cat /sys/kernel/sched_ext/current)
        echo "   Current scheduler: $CURRENT"
    else
        echo "   ✗ /sys/kernel/sched_ext/current does not exist"
        echo "     (This file is created when a scheduler is loaded)"
    fi
else
    echo "   ✗ /sys/kernel/sched_ext/ does not exist"
    echo "     Kernel does not have sched_ext support!"
    exit 1
fi
echo ""

# 2. Check if scheduler binary exists
echo "2. Checking scheduler binary..."
CONTROL_BIN="$PROJECT_ROOT/build/scheds/c/${SCHEDULER}_control"
TEST_BIN="$PROJECT_ROOT/build/scheds/c/${SCHEDULER}_test"

if [ -f "$CONTROL_BIN" ]; then
    echo "   ✓ Control binary exists: $CONTROL_BIN"
    ls -lh "$CONTROL_BIN"
else
    echo "   ✗ Control binary not found: $CONTROL_BIN"
    echo "     Run: ./scripts/build_schedulers.sh $SCHEDULER"
    exit 1
fi
echo ""

# 3. Check recent dmesg for errors
echo "3. Checking recent kernel messages..."
echo "   Recent dmesg (last 20 lines):"
sudo dmesg | tail -20 | sed 's/^/   /'
echo ""

# 4. Try to load scheduler manually and capture output
echo "4. Attempting to load scheduler manually..."
echo "   This will run for 5 seconds, then check if it loaded"
echo ""

# Clear previous logs
rm -f /tmp/scheduler_diagnostic.log

# Start scheduler in background
sudo "$CONTROL_BIN" >/tmp/scheduler_diagnostic.log 2>&1 &
SCHED_PID=$!

# Wait a bit for it to load
sleep 5

# Check if process is still running
if kill -0 $SCHED_PID 2>/dev/null; then
    echo "   ✓ Scheduler process is running (PID: $SCHED_PID)"
else
    echo "   ✗ Scheduler process died immediately"
    echo ""
    echo "   Log output:"
    cat /tmp/scheduler_diagnostic.log | sed 's/^/   /'
    kill $SCHED_PID 2>/dev/null || true
    exit 1
fi

# Check if scheduler loaded
if [ -f "/sys/kernel/sched_ext/current" ]; then
    CURRENT=$(cat /sys/kernel/sched_ext/current)
    if [ "$CURRENT" != "none" ] && [ -n "$CURRENT" ]; then
        echo "   ✓ Scheduler loaded: $CURRENT"
        STATE=$(cat /sys/kernel/sched_ext/state)
        echo "   State: $STATE"
    else
        echo "   ✗ Scheduler not loaded (current: '$CURRENT')"
    fi
else
    echo "   ✗ /sys/kernel/sched_ext/current still doesn't exist"
fi

# Check log for errors
echo ""
echo "   Scheduler log output:"
if [ -f /tmp/scheduler_diagnostic.log ]; then
    tail -30 /tmp/scheduler_diagnostic.log | sed 's/^/   /'
    
    # Check for specific error patterns
    if grep -q "Failed to load" /tmp/scheduler_diagnostic.log; then
        echo ""
        echo "   ⚠ Found 'Failed to load' in log"
    fi
    if grep -q "Failed to attach" /tmp/scheduler_diagnostic.log; then
        echo ""
        echo "   ⚠ Found 'Failed to attach' in log"
    fi
    if grep -q "Permission denied" /tmp/scheduler_diagnostic.log; then
        echo ""
        echo "   ⚠ Found 'Permission denied' in log"
    fi
    if grep -q "verifier" /tmp/scheduler_diagnostic.log; then
        echo ""
        echo "   ⚠ Found 'verifier' in log (BPF verifier error)"
    fi
fi

# Stop scheduler
echo ""
echo "   Stopping scheduler..."
sudo kill $SCHED_PID 2>/dev/null || true
wait $SCHED_PID 2>/dev/null || true
sleep 1

# Check dmesg for scheduler-related messages
echo ""
echo "5. Checking dmesg for scheduler messages..."
echo "   Recent scheduler-related messages:"
sudo dmesg | grep -i "sched_ext\|simple\|scx" | tail -20 | sed 's/^/   /' || echo "   (no scheduler messages found)"
echo ""

# 6. Check BPF maps
echo "6. Checking BPF maps..."
if command -v bpftool >/dev/null 2>&1; then
    echo "   BPF maps:"
    sudo bpftool map list | grep -i "simple\|scx" | head -10 | sed 's/^/   /' || echo "   (no scheduler maps found)"
else
    echo "   bpftool not found, skipping map check"
fi
echo ""

echo "=========================================="
echo "Diagnostic complete"
echo "=========================================="
echo ""
echo "If scheduler didn't load, check:"
echo "  1. Full log: cat /tmp/scheduler_diagnostic.log"
echo "  2. dmesg: sudo dmesg | grep -i 'sched\|bpf' | tail -50"
echo "  3. Kernel config: grep CONFIG_SCHED_CLASS_EXT /boot/config-\$(uname -r)"

