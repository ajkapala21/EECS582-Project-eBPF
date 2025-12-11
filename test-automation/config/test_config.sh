#!/bin/bash
# Test configuration for eBPF scheduler cleanup testing

# Schedulers to test
SCHEDULERS="scx_simple scx_cfsish scx_flatcg scx_nest"

# Workload parameters
STRESS_NG_PROCESSES=20
STRESS_NG_DURATION=60
HACKBENCH_PROCESSES=10
HACKBENCH_LOOPS=100
CUSTOM_CHURN_SPAWNS=1000
CUSTOM_CHURN_DURATION=30

# Test parameters
ITERATIONS=3
METRICS_INTERVAL=2  # seconds between metric samples
CLEANUP_INTERVAL=1  # seconds (in BPF code)
MAX_AGE=5           # seconds (stale threshold)
TIMEOUT_US=100      # microseconds (cleanup budget)

# Map names for each scheduler (for metrics collection)
declare -A MAP_NAMES
MAP_NAMES[scx_simple]="tasks"
MAP_NAMES[scx_cfsish]="task_info_map"
MAP_NAMES[scx_flatcg]="tasks"
MAP_NAMES[scx_nest]="tasks"

# Base directory (will be set by scripts)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${BASE_DIR}/results"
SCHEDULERS_DIR="${BASE_DIR}/schedulers"

