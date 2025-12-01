#!/bin/bash
# Build control and test versions of schedulers
# Usage: build_schedulers.sh [scheduler_name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/config/test_config.sh"

# Get scheduler name if provided, otherwise build all
SCHEDULER=${1:-""}

if [ -z "$SCHEDULER" ]; then
    SCHEDULERS_TO_BUILD=$SCHEDULERS
else
    SCHEDULERS_TO_BUILD=$SCHEDULER
fi

# Navigate to scheds/c directory
cd "$BASE_DIR/../scheds/c" || exit 1

for sched in $SCHEDULERS_TO_BUILD; do
    echo "Building $sched..."
    
    # Build control version
    echo "  Building control version..."
    if [ -f "$BASE_DIR/schedulers/control/${sched}.bpf.c" ]; then
        cp "$BASE_DIR/schedulers/control/${sched}.bpf.c" "${sched}.bpf.c"
    else
        echo "    ERROR: Control source not found: $BASE_DIR/schedulers/control/${sched}.bpf.c"
        exit 1
    fi
    
    if make "${sched}" >/tmp/build_${sched}_control.log 2>&1; then
        # Move binary to have _control suffix
        if [ -f "build/scheds/c/${sched}" ]; then
            cp "build/scheds/c/${sched}" "build/scheds/c/${sched}_control"
        fi
        echo "    Control version built successfully"
    else
        echo "    ERROR: Control build failed. Check /tmp/build_${sched}_control.log"
        cat /tmp/build_${sched}_control.log | tail -20
        exit 1
    fi
    
    # Build test version
    echo "  Building test version..."
    if [ -f "$BASE_DIR/schedulers/test/${sched}.bpf.c" ]; then
        cp "$BASE_DIR/schedulers/test/${sched}.bpf.c" "${sched}.bpf.c"
    else
        echo "    ERROR: Test source not found: $BASE_DIR/schedulers/test/${sched}.bpf.c"
        exit 1
    fi
    
    if make "${sched}" >/tmp/build_${sched}_test.log 2>&1; then
        # Move binary to have _test suffix
        if [ -f "build/scheds/c/${sched}" ]; then
            cp "build/scheds/c/${sched}" "build/scheds/c/${sched}_test"
        fi
        echo "    Test version built successfully"
    else
        echo "    ERROR: Test build failed. Check /tmp/build_${sched}_test.log"
        cat /tmp/build_${sched}_test.log | tail -20
        exit 1
    fi
done

echo "All schedulers built successfully!"

