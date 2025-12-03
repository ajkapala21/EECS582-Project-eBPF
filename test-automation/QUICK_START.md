# Quick Start Guide - scx_nest Testing

## TL;DR - Complete Workflow

### 1. Build
```bash
cd test-automation
./scripts/build_schedulers.sh scx_nest
```

### 2. Run Tests (All Workloads)
```bash
# Primary test (recommended for paper)
./scripts/run_nest_with_trace.sh hackbench 60 3

# Longer test to show sustained cleanup
./scripts/run_nest_with_trace.sh hackbench 120 3

# Additional workloads
./scripts/run_nest_with_trace.sh stress-ng 60 3
./scripts/run_nest_with_trace.sh custom-churn 60 3
```

### 3. View Results
```bash
# Human-readable report
cat results/paper_report_scx_nest_hackbench.txt

# CSV for graphs
cat results/paper_report_scx_nest_hackbench.csv
```

## What Gets Tested

For each workload, the script automatically runs:
- **Control version** (no cleanup) - 3 iterations
- **Test version** (with cleanup) - 3 iterations

## Results Location

```
results/scx_nest/
├── control/
│   ├── hackbench_run1.csv          # Metrics (from trace)
│   ├── hackbench_run1_trace.txt    # Raw trace output
│   ├── hackbench_run1_dmesg.log    # Kernel messages
│   └── ... (runs 2-3)
├── test/
│   ├── hackbench_run1.csv
│   ├── hackbench_run1_trace.txt
│   ├── hackbench_run1_dmesg.log
│   └── ... (runs 2-3)
└── paper_report_scx_nest_hackbench.txt    # Summary report
└── paper_report_scx_nest_hackbench.csv    # Summary CSV
```

## Key Metrics for Paper

From `paper_report_scx_nest_hackbench.csv`:

| Version | Max Entries | Final Entries | Total Evictions |
|---------|-------------|---------------|-----------------|
| control | 247 | 189 | 0 |
| test | 73 | 58 | 1,247 |

**Memory Saved:** 189 - 58 = **131 entries**  
**Reduction:** (131/189) × 100 = **69.3%**

## Full Documentation

See `SCX_NEST_WORKFLOW.md` for detailed information.

