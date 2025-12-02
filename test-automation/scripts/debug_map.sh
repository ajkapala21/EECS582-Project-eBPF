#!/bin/bash
# Quick diagnostic script to check BPF map status
# Run this while the scheduler is running

echo "=== BPF Map Diagnostic ==="
echo ""

# Check if scheduler is loaded
if [ -f /sys/kernel/sched_ext/current ]; then
    CURRENT=$(cat /sys/kernel/sched_ext/current 2>/dev/null || echo "none")
    echo "Current scheduler: $CURRENT"
else
    echo "WARNING: /sys/kernel/sched_ext/current doesn't exist"
    echo "But checking maps anyway..."
fi

echo ""
echo "=== All BPF Maps ==="
bpftool map show 2>/dev/null | head -30

echo ""
echo "=== Searching for 'tasks' map ==="
bpftool map show 2>/dev/null | grep -i "tasks" || echo "No 'tasks' map found"

echo ""
echo "=== Searching for 'nest' related maps ==="
bpftool map show 2>/dev/null | grep -i "nest" || echo "No 'nest' related maps found"

echo ""
echo "=== Trying to find map for scx_nest ==="
MAP_ID=$(bpftool map show 2>/dev/null | grep -A 5 "nest" | grep "tasks" | head -1 | awk '{print $1}' | cut -d: -f1)

if [ -n "$MAP_ID" ]; then
    echo "Found map ID: $MAP_ID"
    echo ""
    echo "Map details:"
    bpftool map show id "$MAP_ID" 2>/dev/null
    echo ""
    echo "Map entry count:"
    ENTRY_COUNT=$(bpftool map dump id "$MAP_ID" 2>/dev/null | grep -c "key:" || echo "0")
    echo "  $ENTRY_COUNT entries"
    echo ""
    if [ "$ENTRY_COUNT" -gt 0 ]; then
        echo "First 5 entries:"
        bpftool map dump id "$MAP_ID" 2>/dev/null | head -20
    fi
else
    echo "Could not find map automatically"
    echo ""
    echo "Please manually check:"
    echo "  bpftool map show | grep -i tasks"
    echo "  bpftool map dump id <MAP_ID>"
fi

echo ""
echo "=== Checking for bpf_printk output ==="
if [ -r /sys/kernel/debug/tracing/trace_pipe ]; then
    echo "Reading trace_pipe (last 10 lines, timeout 1s):"
    timeout 1 cat /sys/kernel/debug/tracing/trace_pipe 2>/dev/null | tail -10 || echo "  (no output or error)"
else
    echo "  /sys/kernel/debug/tracing/trace_pipe not readable"
    echo "  Try: sudo cat /sys/kernel/debug/tracing/trace_pipe"
fi

