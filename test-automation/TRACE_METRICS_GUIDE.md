# Trace-Based Metrics Collection Guide

Since `bpftool` cannot access BPF maps on your system, we use `trace_pipe` to collect metrics from the debug output.

## Quick Start

### Step 1: Run Test and Capture Trace

In one terminal, start trace capture:
```bash
cd test-automation
sudo cat /sys/kernel/debug/tracing/trace_pipe > /tmp/trace_output.txt &
TRACE_PID=$!
```

In another terminal, run your test:
```bash
cd test-automation
./scripts/run_experiment.sh scx_nest hackbench 60 3
```

After test completes, stop trace capture:
```bash
sudo kill $TRACE_PID
```

### Step 2: Parse Trace to CSV

```bash
# Parse trace for control version (if you have separate trace files)
./scripts/parse_trace_for_metrics.sh /tmp/trace_output.txt results/scx_nest/test/hackbench_run1.csv

# Or parse multiple runs
for i in 1 2 3; do
    ./scripts/parse_trace_for_metrics.sh /tmp/trace_control_run${i}.txt results/scx_nest/control/hackbench_run${i}.csv
    ./scripts/parse_trace_for_metrics.sh /tmp/trace_test_run${i}.txt results/scx_nest/test/hackbench_run${i}.csv
done
```

### Step 3: Generate Paper Report

```bash
./scripts/generate_paper_report.sh scx_nest hackbench
```

This creates:
- `results/paper_report_scx_nest_hackbench.txt` - Human-readable report
- `results/paper_report_scx_nest_hackbench.csv` - CSV for graphs/tables

## Report Format

The paper report includes:

1. **Executive Summary**
   - Control version: Shows unbounded growth
   - Test version: Shows bounded growth with cleanup

2. **Comparison Metrics**
   - Memory saved (map entries)
   - Percentage reduction
   - Total evictions

3. **Detailed Metrics**
   - Per-run statistics
   - Max vs final entries
   - Eviction counts

4. **Conclusion**
   - Evidence of memory savings
   - Cleanup effectiveness

## Example Output

```
==================================================================================
Memory Cleanup Effectiveness Report
Scheduler: scx_nest | Workload: hackbench
Generated: Tue Dec 2 13:30:00 EST 2025
==================================================================================

EXECUTIVE SUMMARY
-----------------

CONTROL VERSION (No Cleanup):
  - Map entries accumulate over time (no cleanup)
  - Memory usage may grow unbounded
  
  Max map entries observed: 247
  Final map entries: 189

TEST VERSION (With Cleanup):
  - Map entries are actively cleaned up
  - Memory usage remains bounded
  
  Max map entries observed: 73
  Final map entries: 58
  Total entries evicted: 1247
  Cleanup operations: 180
  Average evictions per cleanup: 6.9

COMPARISON
----------
  Memory saved (map entries): 131 entries
  Memory reduction: 69.3%
  
  Control version accumulated 189 entries
  Test version stabilized at 58 entries
  Difference: 131 entries prevented from accumulating
```

## For Your Paper

The report provides:
- **Clear evidence** that cleanup prevents memory growth
- **Quantitative metrics** (entries saved, percentage reduction)
- **Comparison data** suitable for tables and graphs
- **Professional formatting** ready for inclusion

Use the CSV file to create graphs showing:
- Map entries over time (control vs test)
- Eviction rate
- Memory savings

