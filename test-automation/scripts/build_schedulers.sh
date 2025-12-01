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
    
    # Save original file
    ORIGINAL_BACKUP="$SCHEDS_C_DIR/${sched}.bpf.c.orig"
    if [ ! -f "$ORIGINAL_BACKUP" ]; then
        cp "$SCHEDS_C_DIR/${sched}.bpf.c" "$ORIGINAL_BACKUP" 2>/dev/null || {
            echo "    WARNING: Could not backup original ${sched}.bpf.c"
        }
    fi
    
    # Build control version
    echo "  Building control version..."
    if [ -f "$BASE_DIR/schedulers/control/${sched}.bpf.c" ]; then
        cp "$BASE_DIR/schedulers/control/${sched}.bpf.c" "$SCHEDS_C_DIR/${sched}.bpf.c"
    else
        echo "    ERROR: Control source not found: $BASE_DIR/schedulers/control/${sched}.bpf.c"
        exit 1
    fi
    
    # Clean previous build artifacts for this scheduler
    echo "    Cleaning previous build artifacts..."
    rm -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.o" \
          "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.skel.h" \
          "$PROJECT_ROOT/build/scheds/c/${sched}" \
          "$PROJECT_ROOT/build/scheds/c/${sched}_control" \
          "$PROJECT_ROOT/build/scheds/c/${sched}_test" 2>/dev/null || true
    
    # Also clean from source directory (in case of stale files)
    rm -f "$SCHEDS_C_DIR/${sched}.bpf.o" \
          "$SCHEDS_C_DIR/${sched}.bpf.skel.h" 2>/dev/null || true
    
    # Build from project root using top-level Makefile
    # First ensure lib is built
    echo "    Building lib dependency..."
    make -C "$PROJECT_ROOT" lib >/tmp/build_lib.log 2>&1 || {
        echo "    WARNING: lib build had issues, continuing anyway..."
    }
    
    # Build the scheduler (this should generate .bpf.o, then .bpf.skel.h, then the binary)
    echo "    Running make ${sched}..."
    if make -C "$PROJECT_ROOT" "${sched}" >/tmp/build_${sched}_control.log 2>&1; then
        # Verify BPF object was created
        if [ ! -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.o" ]; then
            echo "    ERROR: BPF object file not created: ${sched}.bpf.o"
            echo "    BPF compilation may have failed. Build log:"
            grep -i "error\|fail" /tmp/build_${sched}_control.log | tail -10
            exit 1
        fi
        
        # Verify skeleton header was generated
        if [ ! -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.skel.h" ]; then
            echo "    ERROR: Skeleton header not generated: ${sched}.bpf.skel.h"
            echo "    BPF object exists but skeleton generation failed."
            echo "    Check if bpftool gen skeleton is working. Build log:"
            grep -i "skeleton\|bpftool" /tmp/build_${sched}_control.log | tail -10
            exit 1
        fi
        
        # Copy binary to have _control suffix
        if [ -f "$PROJECT_ROOT/build/scheds/c/${sched}" ]; then
            cp "$PROJECT_ROOT/build/scheds/c/${sched}" "$PROJECT_ROOT/build/scheds/c/${sched}_control"
            echo "    Control version built successfully: build/scheds/c/${sched}_control"
        else
            echo "    ERROR: Binary not found at expected location"
            echo "    Checking what was built:"
            ls -la "$PROJECT_ROOT/build/scheds/c/${sched}"* 2>/dev/null || echo "    No files found"
            echo "    Build log tail:"
            tail -30 /tmp/build_${sched}_control.log
            exit 1
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
    echo "    Building lib dependency..."
    make -C "$PROJECT_ROOT" lib >/tmp/build_lib.log 2>&1 || {
        echo "    WARNING: lib build had issues, continuing anyway..."
    }
    
    # Build the scheduler (this should generate .bpf.o, then .bpf.skel.h, then the binary)
    echo "    Running make ${sched}..."
    if make -C "$PROJECT_ROOT" "${sched}" >/tmp/build_${sched}_test.log 2>&1; then
        # Verify BPF object was created
        if [ ! -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.o" ]; then
            echo "    ERROR: BPF object file not created: ${sched}.bpf.o"
            echo "    BPF compilation may have failed. Build log:"
            grep -i "error\|fail" /tmp/build_${sched}_test.log | tail -10
            exit 1
        fi
        
        # Verify skeleton header was generated
        if [ ! -f "$PROJECT_ROOT/build/scheds/c/${sched}.bpf.skel.h" ]; then
            echo "    ERROR: Skeleton header not generated: ${sched}.bpf.skel.h"
            echo "    BPF object exists but skeleton generation failed."
            echo "    Check if bpftool gen skeleton is working. Build log:"
            grep -i "skeleton\|bpftool" /tmp/build_${sched}_test.log | tail -10
            exit 1
        fi
        
        # Copy binary to have _test suffix
        if [ -f "$PROJECT_ROOT/build/scheds/c/${sched}" ]; then
            cp "$PROJECT_ROOT/build/scheds/c/${sched}" "$PROJECT_ROOT/build/scheds/c/${sched}_test"
            echo "    Test version built successfully: build/scheds/c/${sched}_test"
        else
            echo "    ERROR: Binary not found at expected location"
            echo "    Checking what was built:"
            ls -la "$PROJECT_ROOT/build/scheds/c/${sched}"* 2>/dev/null || echo "    No files found"
            echo "    Build log tail:"
            tail -30 /tmp/build_${sched}_test.log
            exit 1
        fi
    else
        echo "    ERROR: Test build failed. Check /tmp/build_${sched}_test.log"
        echo "    Last 40 lines of build log:"
        tail -40 /tmp/build_${sched}_test.log
        exit 1
    fi
    
    # Restore original file for next iteration
    if [ -f "$ORIGINAL_BACKUP" ]; then
        cp "$ORIGINAL_BACKUP" "$SCHEDS_C_DIR/${sched}.bpf.c"
    fi
done

echo "All schedulers built successfully!"

