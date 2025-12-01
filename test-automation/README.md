# eBPF Scheduler Cleanup Testing Automation

This directory contains automation scripts for testing the impact of the `scx_bpf_map_scan_timeout` helper function on eBPF scheduler performance.

## Overview

The test automation compares **control** (no cleanup) vs **test** (with cleanup) versions of schedulers under identical stress workloads to measure:
- Map entry accumulation (control should grow, test should stabilize)
- Memory usage trends
- Eviction activity (test only)
- Scheduler performance

## Directory Structure

```
test-automation/
├── schedulers/
│   ├── control/     # Control versions (no cleanup)
│   └── test/        # Test versions (with cleanup)
├── scripts/
│   ├── workloads/   # Workload generation scripts
│   ├── build_schedulers.sh
│   ├── run_experiment.sh
│   ├── collect_metrics.sh
│   ├── find_map_id.sh
│   └── aggregate_results.sh
├── config/
│   └── test_config.sh
├── results/         # Test results (CSV files, logs)
└── README.md
```

## Prerequisites

1. **Kernel with `scx_bpf_map_scan_timeout` helper** - The helper must be implemented in the kernel
2. **Required tools**:
   - `bpftool` - For map inspection
   - `stress-ng` - For fork workload: `sudo apt-get install stress-ng`
   - `hackbench` - For IPC workload: `sudo apt-get install rt-tests`
   - `perf` - For latency measurements (optional)
3. **Scheduler build environment** - Must be able to build schedulers from `scheds/c/`

## Quick Start

### 1. Build Schedulers

```bash
cd test-automation
./scripts/build_schedulers.sh
```

This builds both control and test versions of all schedulers.

### 2. Run a Single Experiment

```bash
# Test scx_simple with stress-ng for 60 seconds, 3 iterations
./scripts/run_experiment.sh scx_simple stress-ng 60 3
```

### 3. View Results

Results are saved in `results/<scheduler>/<control|test>/`:
- CSV files with metrics over time
- dmesg logs with eviction messages

Generate a summary:
```bash
./scripts/aggregate_results.sh scx_simple stress-ng
```

## Configuration

Edit `config/test_config.sh` to customize:
- Workload parameters (process counts, durations)
- Number of iterations
- Metrics collection interval
- Cleanup parameters (max age, timeout)

## Schedulers

Supported schedulers:
- `scx_simple` - Simple global vtime scheduler
- `scx_cfsish` - CFS-like scheduler
- `scx_flatcg` - Flattened cgroup hierarchy scheduler
- `scx_nest` - Nest algorithm scheduler

## Workloads

1. **stress-ng** - Fork stress test
   - Creates many short-lived processes
   - Parameters: process count, duration

2. **hackbench** - IPC stress test
   - Heavy inter-process communication
   - Parameters: processes, loops

3. **custom-churn** - Rapid task spawn/kill
   - Custom script for bursty load
   - Parameters: spawn count, duration

## Metrics Collected

Each test run collects:
- **Map entries** - Current count in tracking map (via bpftool)
- **Free memory** - System free memory (KB)
- **BPF slab cache** - BPF map element memory usage (KB)
- **Evictions** - Cumulative eviction count (test only)

Metrics are sampled every 2 seconds (configurable) and saved to CSV.

## Expected Results

### Control Version (No Cleanup)
- Map entries should **increase** over time as tasks exit
- Memory usage may drift upward
- No eviction messages in dmesg

### Test Version (With Cleanup)
- Map entries should **stabilize** after initial growth
- Periodic eviction messages in dmesg
- Memory usage should remain bounded
- Map size should plateau or oscillate around a fixed level

## Example Workflow

```bash
# 1. Build all schedulers
./scripts/build_schedulers.sh

# 2. Run full test suite for one scheduler
for workload in stress-ng hackbench custom-churn; do
    ./scripts/run_experiment.sh scx_simple $workload 60 3
done

# 3. Generate summaries
for workload in stress-ng hackbench custom-churn; do
    ./scripts/aggregate_results.sh scx_simple $workload
done

# 4. Compare results
# Control: results/scx_simple/control/
# Test:    results/scx_simple/test/
```

## Troubleshooting

### Scheduler fails to load
- Check `/tmp/scheduler_*.log` for errors
- Verify kernel has `scx_bpf_map_scan_timeout` helper
- Check dmesg for BPF verifier errors

### Map ID not found
- Ensure scheduler is running before metrics collection starts
- Check scheduler name matches exactly
- Verify map name in `config/test_config.sh`

### No evictions in test version
- Verify cleanup code is in dispatch hook
- Check cleanup interval (should be 1 second)
- Reduce max_age threshold if needed
- Increase workload intensity

### Build failures
- Check that scheduler source files exist in `schedulers/control/` and `schedulers/test/`
- Verify build environment is set up correctly
- Check build logs in `/tmp/build_*.log`

## File Locations

- **Scheduler binaries**: `../scheds/c/build/scheds/c/<scheduler>_{control,test}`
- **Results**: `results/<scheduler>/<control|test>/`
- **Logs**: `/tmp/scheduler_*.log`, `/tmp/build_*.log`
- **dmesg**: Saved in results directory for each run

## Notes

- All tests run in the VM environment
- Schedulers are loaded/unloaded between control and test runs
- System state is reset (dmesg cleared, caches dropped) before each run
- CPU governor is set to "performance" for consistent results

