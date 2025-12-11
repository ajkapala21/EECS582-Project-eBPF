# Map Cleanup Helper - Test Guide

This guide explains how to run the scx_nest scheduler with the map cleanup helper and observe eviction events in real-time.

## Prerequisites

- Linux VM with sched_ext kernel support
- Build tools: `clang`, `bpftool`, `libbpf`, `make`
- `hackbench` (install with `sudo apt-get install rt-tests`)

## Step-by-Step Instructions

### Step 1: Clone and Navigate to the Repository

```bash
cd ~/EECS582-Project-eBPF
git pull origin main
```

### Step 2: Open Two Terminal Windows

You will need two terminals:
- **Terminal 1**: Run the experiment
- **Terminal 2**: View eviction output

### Step 3: Start Trace Pipe (Terminal 2)

In Terminal 2, run:

```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep -E "Map cleanup|evict"
```

Leave this running. This will display map cleanup eviction messages in real-time.

### Step 4: Run the Experiment (Terminal 1)

In Terminal 1, run:

```bash
cd ~/EECS582-Project-eBPF/test-automation/scripts
./run_experiment.sh scx_nest hackbench 60 1
```

**Parameters:**
- `scx_nest` - The scheduler to test
- `hackbench` - The workload to run
- `60` - Duration in seconds
- `1` - Number of iterations

The script will:
1. Build the scx_nest scheduler (control and test versions)
2. Prompt you to confirm trace_pipe is running
3. Run hackbench workload for 60 seconds
4. Stop the scheduler

### Step 5: Observe Output

In Terminal 2 (trace_pipe), you should see messages like:

```
Map cleanup: evicted 5 stale entries
Map cleanup: timeout after evicted 12 entries
```

These indicate the map cleanup helper is working correctly.

## Expected Output

When the map cleanup helper is functioning:
- Eviction messages appear in trace_pipe every ~1 second
- The number of evicted entries varies based on workload intensity
- Timeout messages indicate the cleanup budget was reached (normal for large maps)

## Troubleshooting

**No output in trace_pipe:**
- Ensure the scheduler loaded: `cat /sys/kernel/sched_ext/state`
- Check for errors: `dmesg | tail -20`

**hackbench not found:**
```bash
sudo apt-get install rt-tests
```

**Build fails:**
- Ensure libbpf is installed: `sudo apt-get install libbpf-dev`
- Ensure clang is installed: `sudo apt-get install clang`

