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

# Navigate to project root
PROJECT_ROOT="$BASE_DIR/.."
cd "$PROJECT_ROOT" || exit 1

# Navigate to scheds/c directory for source file copying
SCHEDS_C_DIR="$PROJECT_ROOT/scheds/c"

# Verify required tools
if ! command -v bpftool >/dev/null 2>&1; then
    echo "ERROR: bpftool not found. Please install it or add to PATH."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "ERROR: clang not found. Please install it or add to PATH."
    exit 1
fi

echo "Build environment check:"
echo "  bpftool: $(which bpftool)"
echo "  clang: $(which clang)"
echo ""

for sched in $SCHEDULERS_TO_BUILD; do
    echo "Building $sched..."
    
    # Build control version
    echo "  Building control version..."
    if [ -f "$BASE_DIR/schedulers/control/${sched}.bpf.c" ]; then
        cp "$BASE_DIR/schedulers/control/${sched}.bpf.c" "$SCHEDS_C_DIR/${sched}.bpf.c"
    else
        echo "    ERROR: Control source not found: $BASE_DIR/schedulers/control/${sched}.bpf.c"
        exit 1
    fi
    
    # Clean previous build artifacts for this scheduler
    rm -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.o" \
          "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.skel.h" \
          "$PROJECT_ROOT/build/scheds/c/${sched}" \
          "$PROJECT_ROOT/build/scheds/c/${sched}_control" \
          "$PROJECT_ROOT/build/scheds/c/${sched}_test" 2>/dev/null || true
    
    # Build from project root using top-level Makefile
    # First ensure lib is built
    make -C "$PROJECT_ROOT" lib >/tmp/build_lib.log 2>&1 || true
    
    if make -C "$PROJECT_ROOT" "${sched}" >/tmp/build_${sched}_control.log 2>&1; then
        # Copy binary to have _control suffix
        if [ -f "$PROJECT_ROOT/build/scheds/c/${sched}" ]; then
            cp "$PROJECT_ROOT/build/scheds/c/${sched}" "$PROJECT_ROOT/build/scheds/c/${sched}_control"
            echo "    Control version built successfully: build/scheds/c/${sched}_control"
        else
            echo "    WARNING: Binary not found at expected location"
            echo "    Build log tail:"
            tail -20 /tmp/build_${sched}_control.log
        fi
    else
        echo "    ERROR: Control build failed. Check /tmp/build_${sched}_control.log"
        echo "    Last 40 lines of build log:"
        tail -40 /tmp/build_${sched}_control.log
        exit 1
    fi
    
    # Build test version
    echo "  Building test version..."
    if [ -f "$BASE_DIR/schedulers/test/${sched}.bpf.c" ]; then
        cp "$BASE_DIR/schedulers/test/${sched}.bpf.c" "$SCHEDS_C_DIR/${sched}.bpf.c"
    else
        echo "    ERROR: Test source not found: $BASE_DIR/schedulers/test/${sched}.bpf.c"
        exit 1
    fi
    
    # Clean previous build artifacts for this scheduler (keep control version)
    rm -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.o" \
          "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.skel.h" \
          "$PROJECT_ROOT/build/scheds/c/${sched}" 2>/dev/null || true
    
    # Build from project root using top-level Makefile
    # First ensure lib is built
    make -C "$PROJECT_ROOT" lib >/tmp/build_lib.log 2>&1 || true
    
    if make -C "$PROJECT_ROOT" "${sched}" >/tmp/build_${sched}_test.log 2>&1; then
        # Copy binary to have _test suffix
        if [ -f "$PROJECT_ROOT/build/scheds/c/${sched}" ]; then
            cp "$PROJECT_ROOT/build/scheds/c/${sched}" "$PROJECT_ROOT/build/scheds/c/${sched}_test"
            echo "    Test version built successfully: build/scheds/c/${sched}_test"
        else
            echo "    WARNING: Binary not found at expected location"
            echo "    Build log tail:"
            tail -20 /tmp/build_${sched}_test.log
        fi
    else
        echo "    ERROR: Test build failed. Check /tmp/build_${sched}_test.log"
        echo "    Last 40 lines of build log:"
        tail -40 /tmp/build_${sched}_test.log
        exit 1
    fi
done

echo "All schedulers built successfully!"

