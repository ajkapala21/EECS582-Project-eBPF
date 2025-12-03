# Complete Workflow for scx_nest Scheduler Testing

## Overview

This guide provides the complete workflow for testing the `scx_nest` scheduler with memory cleanup functionality. Since `bpftool` cannot access BPF maps on your system, we use `trace_pipe` for metrics collection.

## Available Workloads

1. **hackbench** - IPC/scheduling benchmark (recommended for paper)
2. **stress-ng** - CPU stress test
3. **custom-churn** - Custom workload with high task churn

## Complete Testing Workflow

### Step 1: Build the Scheduler

```bash
cd test-automation
./scripts/build_schedulers.sh scx_nest
```

This builds both:
- `scx_nest_control` (no cleanup)
- `scx_nest_test` (with cleanup)

### Step 2: Run Tests with Trace Collection

Since `bpftool` doesn't work, we need to capture trace output manually. Here's the complete workflow:

#### Option A: Automated Script (Recommended)

Create a wrapper script that captures trace for each run:

```bash
#!/bin/bash
# run_nest_with_trace.sh <workload> <duration> <iterations>

WORKLOAD=$1
DURATION=$2
ITERATIONS=${3:-3}

cd test-automation
RESULTS_DIR="results/scx_nest"

# Build first
./scripts/build_schedulers.sh scx_nest

for iter in $(seq 1 $ITERATIONS); do
    echo "=========================================="
    echo "Iteration $iter: CONTROL"
    echo "=========================================="
    
    # Start trace capture
    sudo cat /sys/kernel/debug/tracing/trace_pipe > "$RESULTS_DIR/control/${WORKLOAD}_run${iter}_trace.txt" 2>/dev/null &
    TRACE_PID=$!
    sleep 0.5
    
    # Run control version
    ./scripts/run_experiment.sh scx_nest "$WORKLOAD" "$DURATION" 1
    
    # Stop trace
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Parse trace to CSV
    if [ -f "$RESULTS_DIR/control/${WORKLOAD}_run${iter}_trace.txt" ]; then
        ./scripts/parse_trace_for_metrics.sh \
            "$RESULTS_DIR/control/${WORKLOAD}_run${iter}_trace.txt" \
            "$RESULTS_DIR/control/${WORKLOAD}_run${iter}.csv"
    fi
    
    # Clear trace buffer
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2
    
    echo ""
    echo "=========================================="
    echo "Iteration $iter: TEST"
    echo "=========================================="
    
    # Start trace capture
    sudo cat /sys/kernel/debug/tracing/trace_pipe > "$RESULTS_DIR/test/${WORKLOAD}_run${iter}_trace.txt" 2>/dev/null &
    TRACE_PID=$!
    sleep 0.5
    
    # Run test version
    ./scripts/run_experiment.sh scx_nest "$WORKLOAD" "$DURATION" 1
    
    # Stop trace
    sudo kill $TRACE_PID 2>/dev/null || true
    wait $TRACE_PID 2>/dev/null || true
    
    # Parse trace to CSV
    if [ -f "$RESULTS_DIR/test/${WORKLOAD}_run${iter}_trace.txt" ]; then
        ./scripts/parse_trace_for_metrics.sh \
            "$RESULTS_DIR/test/${WORKLOAD}_run${iter}_trace.txt" \
            "$RESULTS_DIR/test/${WORKLOAD}_run${iter}.csv"
    fi
    
    # Clear trace buffer
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2
done

# Generate paper report
./scripts/generate_paper_report.sh scx_nest "$WORKLOAD"
```

#### Option B: Manual Step-by-Step

For each workload and iteration:

1. **Start trace capture:**
   ```bash
   sudo cat /sys/kernel/debug/tracing/trace_pipe > /tmp/trace_control.txt &
   TRACE_PID=$!
   ```

2. **Run control version:**
   ```bash
   ./scripts/run_experiment.sh scx_nest hackbench 60 1
   ```

3. **Stop trace and parse:**
   ```bash
   sudo kill $TRACE_PID
   ./scripts/parse_trace_for_metrics.sh /tmp/trace_control.txt \
       results/scx_nest/control/hackbench_run1.csv
   ```

4. **Repeat for test version:**
   ```bash
   sudo cat /sys/kernel/debug/tracing/trace_pipe > /tmp/trace_test.txt &
   TRACE_PID=$!
   ./scripts/run_experiment.sh scx_nest hackbench 60 1
   sudo kill $TRACE_PID
   ./scripts/parse_trace_for_metrics.sh /tmp/trace_test.txt \
       results/scx_nest/test/hackbench_run1.csv
   ```

### Step 3: Recommended Test Matrix

For your paper, run these combinations:

| Workload | Duration | Iterations | Purpose |
|----------|----------|------------|---------|
| hackbench | 60s | 3 | Primary benchmark (IPC/scheduling) |
| hackbench | 120s | 3 | Longer run to show sustained cleanup |
| stress-ng | 60s | 3 | CPU-intensive workload |
| custom-churn | 60s | 3 | High task churn (many short-lived tasks) |

**Commands:**
```bash
# Primary tests (recommended for paper)
./run_nest_with_trace.sh hackbench 60 3
./run_nest_with_trace.sh hackbench 120 3

# Additional tests
./run_nest_with_trace.sh stress-ng 60 3
./run_nest_with_trace.sh custom-churn 60 3
```

## Viewing Results

### 1. Individual Run CSVs

Location: `results/scx_nest/{control,test}/{workload}_run{N}.csv`

Format:
```csv
timestamp,estimated_map_entries,tasks_added,tasks_evicted,cleanup_operations,evictions_this_cleanup
0,0,0,0,0,0
2,5,5,0,0,0
4,12,12,0,0,0
...
```

### 2. Paper Report (Human-Readable)

Location: `results/paper_report_scx_nest_{workload}.txt`

View:
```bash
cat results/paper_report_scx_nest_hackbench.txt
```

Contains:
- Executive summary
- Control vs test comparison
- Memory savings metrics
- Percentage reductions
- Detailed per-run statistics
- Conclusion

### 3. Paper Report CSV (For Graphs)

Location: `results/paper_report_scx_nest_{workload}.csv`

Format:
```csv
version,run,max_entries,final_entries,total_evictions,cleanup_runs,avg_evictions_per_run
control,hackbench_run1,247,189,0,0,0
test,hackbench_run1,73,58,1247,180,6.9
...
```

Use this CSV to create graphs in your paper.

### 4. Raw Trace Files

Location: `results/scx_nest/{control,test}/{workload}_run{N}_trace.txt`

Contains all `bpf_printk` output. Useful for debugging.

### 5. dmesg Logs

Location: `results/scx_nest/{control,test}/{workload}_run{N}_dmesg.log`

Contains kernel messages and errors.

## Key Metrics to Extract for Paper

### From Paper Report CSV:

1. **Memory Savings:**
   - `max_entries` (control) vs `max_entries` (test)
   - `final_entries` (control) vs `final_entries` (test)
   - Difference = memory saved

2. **Cleanup Effectiveness:**
   - `total_evictions` - Total entries cleaned up
   - `avg_evictions_per_run` - Average per cleanup operation
   - `cleanup_runs` - Number of cleanup operations

3. **Percentage Reduction:**
   ```
   Reduction = (control_final - test_final) / control_final * 100
   ```

### Example Values to Report:

```
Control Version:
- Max map entries: 247
- Final map entries: 189
- Memory growth: Unbounded

Test Version:
- Max map entries: 73
- Final map entries: 58
- Total evictions: 1,247
- Average evictions per cleanup: 6.9

Memory Savings:
- Entries prevented: 131 (189 - 58)
- Percentage reduction: 69.3%
```

## File Organization

```
results/scx_nest/
├── control/
│   ├── hackbench_run1.csv          # Parsed metrics
│   ├── hackbench_run1_trace.txt     # Raw trace output
│   ├── hackbench_run1_dmesg.log     # Kernel messages
│   ├── hackbench_run2.csv
│   ├── hackbench_run2_trace.txt
│   └── ...
├── test/
│   ├── hackbench_run1.csv
│   ├── hackbench_run1_trace.txt
│   ├── hackbench_run1_dmesg.log
│   └── ...
└── paper_report_scx_nest_hackbench.txt    # Summary report
└── paper_report_scx_nest_hackbench.csv    # Summary CSV
```

## Quick Reference Commands

```bash
# Build
./scripts/build_schedulers.sh scx_nest

# Run single test (control + test)
./scripts/run_experiment.sh scx_nest hackbench 60 1

# Parse existing trace file
./scripts/parse_trace_for_metrics.sh trace.txt output.csv

# Generate paper report
./scripts/generate_paper_report.sh scx_nest hackbench

# View results
cat results/paper_report_scx_nest_hackbench.txt
cat results/paper_report_scx_nest_hackbench.csv

# Check trace output (while test is running)
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep -E "Map cleanup|nest_running"
```

## Troubleshooting

### No evictions in trace
- Check that scheduler loaded: `cat /sys/kernel/sched_ext/state`
- Verify cleanup is called: `grep "Starting cleanup scan" trace.txt`
- Check map entries are being added: `grep "Added new task" trace.txt`

### CSV shows all zeros
- Verify trace file was captured correctly
- Check trace file has content: `wc -l trace.txt`
- Re-run parse script: `./scripts/parse_trace_for_metrics.sh trace.txt output.csv`

### Scheduler won't load
- Check logs: `cat /tmp/scheduler_*.log`
- Check dmesg: `dmesg | tail -20`
- Rebuild: `./scripts/build_schedulers.sh scx_nest`

