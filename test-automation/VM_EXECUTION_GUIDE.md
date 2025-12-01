# VM Execution Guide and Expected Results

## What Running Tests in the VM Looks Like

### Initial Setup

1. **SSH into your VM** (or use console)
2. **Navigate to test directory**:
   ```bash
   cd ~/EECS582-Project-eBPF/test-automation
   ```

3. **Build schedulers** (first time):
   ```bash
   ./scripts/build_schedulers.sh
   ```
   
   **Expected output**:
   ```
   Building scx_simple...
     Building control version...
       Control version built successfully
     Building test version...
       Test version built successfully
   Building scx_cfsish...
     ...
   ```

### Running a Single Test

```bash
./scripts/run_experiment.sh scx_simple stress-ng 60 3
```

**What happens**:
1. Script builds schedulers (if needed)
2. Sets up environment (clears dmesg, drops caches, sets CPU governor)
3. For each iteration:
   - **Control run**: Loads control scheduler → starts metrics → runs workload → stops → saves results
   - **Test run**: Loads test scheduler → starts metrics → runs workload → stops → saves results
4. Generates summary

**Console output**:
```
Building schedulers...
Setting up test environment...

==========================================
Iteration 1 of 3
==========================================

Running CONTROL version...
[12:34:56] Starting stress-ng: --fork 20 --timeout 60s
Control run 1 completed. Results: results/scx_simple/control/stress-ng_run1.csv

Running TEST version...
[12:36:15] Starting stress-ng: --fork 20 --timeout 60s
Map cleanup: evicted 5 stale entries
Map cleanup: evicted 12 stale entries
Test run 1 completed. Results: results/scx_simple/test/stress-ng_run1.csv

==========================================
Iteration 2 of 3
...
==========================================
All iterations completed!
Results saved in: results/scx_simple
```

## Expected Results

### Control Version (No Cleanup)

**Map Size Over Time** (from CSV):
```
timestamp,map_entries,free_mem_kb,slab_bpf_kb,evictions
0,0,2048000,0,0
2,15,2045000,120,0
4,32,2042000,240,0
6,48,2039000,360,0
...
60,450,2020000,3600,0
```

**Characteristics**:
- Map entries **increase steadily** (0 → 450+ entries)
- No evictions (always 0)
- Memory usage may drift upward
- dmesg shows no cleanup messages

**dmesg output** (control):
```
[  123.456] sched_ext: BPF scheduler "simple" enabled
[  124.567] stress-ng: started 20 processes
[  180.123] stress-ng: completed
```

### Test Version (With Cleanup)

**Map Size Over Time** (from CSV):
```
timestamp,map_entries,free_mem_kb,slab_bpf_kb,evictions
0,0,2048000,0,0
2,18,2045000,140,0
4,35,2042000,280,0
6,42,2039000,320,0
8,38,2038000,300,5    <- First cleanup
10,40,2037000,310,12  <- Second cleanup
...
60,45,2035000,360,125
```

**Characteristics**:
- Map entries **stabilize** after initial growth (plateaus around 40-50)
- Evictions **increase** over time (0 → 125+)
- Memory usage remains **bounded**
- dmesg shows periodic cleanup messages

**dmesg output** (test):
```
[  123.456] sched_ext: BPF scheduler "simple" enabled
[  124.567] stress-ng: started 20 processes
[  125.678] Map cleanup: evicted 5 stale entries
[  126.789] Map cleanup: evicted 12 stale entries
[  127.890] Map cleanup: timeout after evicted 8 entries
[  180.123] stress-ng: completed
```

## Visual Comparison

### Map Size Over Time

**Control**: Steady upward line
```
Map Entries
  500 |                                    *
      |                              *
  400 |                        *
      |                  *
  300 |            *
      |      *
  200 |*
      |_____________________________
       0    20   40   60   Time (s)
```

**Test**: Plateaus after initial growth
```
Map Entries
   50 |      *  *  *  *  *  *  *  *
      |   *  *  *  *  *  *  *  *  *
   40 |*  *  *  *  *  *  *  *  *  *
      |_____________________________
       0    20   40   60   Time (s)
```

## Summary Output

After running `aggregate_results.sh scx_simple stress-ng`:

```
========================================
Summary: scx_simple - stress-ng
Generated: Mon Jan 15 12:40:00 UTC 2024
========================================

CONTROL VERSION:
  Files found: 3
  Max map entries: 487
  Avg map entries: 342

TEST VERSION:
  Files found: 3
  Max map entries: 52
  Avg map entries: 38
  Total evictions: 387
```

## Key Metrics to Compare

1. **Max Map Entries**: Control should be 5-10x higher than test
2. **Average Map Entries**: Control steadily increases, test stabilizes
3. **Evictions**: Only test version has non-zero evictions
4. **Memory**: Test version should show bounded memory growth

## Troubleshooting Expected Issues

### Issue: Map entries not growing in control
- **Check**: Are tasks actually being added to map in enqueue hook?
- **Fix**: Verify control version has map tracking code (should have it)

### Issue: No evictions in test version
- **Check**: Is cleanup code in dispatch hook?
- **Check**: Are tasks exiting? (need short-lived tasks)
- **Fix**: Reduce max_age threshold or increase workload intensity

### Issue: Scheduler fails to load
- **Check**: Kernel has `scx_bpf_map_scan_timeout` helper
- **Check**: BPF program compiles without verifier errors
- **Fix**: Check dmesg for specific error messages

## File Locations in VM

- **Results**: `~/EECS582-Project-eBPF/test-automation/results/`
- **Logs**: `/tmp/scheduler_*.log`, `/tmp/build_*.log`
- **CSV files**: `results/<scheduler>/<control|test>/<workload>_run<N>.csv`
- **dmesg logs**: `results/<scheduler>/<control|test>/<workload>_run<N>_dmesg.log`

## Typical Test Duration

- **Single iteration**: ~2-3 minutes (60s workload + overhead)
- **3 iterations**: ~8-10 minutes
- **Full suite** (4 schedulers × 3 workloads × 3 iterations): ~2-3 hours

## Success Criteria

✅ **Test passes if**:
- Control version shows map growth
- Test version shows map stabilization
- Test version shows eviction messages in dmesg
- Test version has lower max/average map entries than control
- No scheduler crashes or BPF errors

