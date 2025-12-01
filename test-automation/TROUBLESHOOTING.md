# Troubleshooting Guide: Scheduler Not Loading

## Problem: Scheduler Shows "Current: none"

When running `./scripts/run_experiment.sh`, you see:
```
WARNING: Scheduler may not have loaded properly.
    Expected: simple or scx_simple
    Current: none
```

This means the scheduler binary is running, but the BPF program failed to load into the kernel.

### Critical Diagnostic: Check if `/sys/kernel/sched_ext/current` exists

**If the file doesn't exist:**
```bash
$ cat /sys/kernel/sched_ext/current
cat: /sys/kernel/sched_ext/current: No such file or directory
```

This means the scheduler **never successfully attached**. The file is only created when a scheduler is loaded.

**If the file exists but shows "none":**
```bash
$ cat /sys/kernel/sched_ext/current
none
```

This means sched_ext is enabled but no scheduler is currently loaded.

**If scheduler loaded successfully:**
```bash
$ cat /sys/kernel/sched_ext/current
simple
```

### Common Symptom: Stats Output but No Load

If you see:
- Scheduler logs showing `local=XXX global=XXXXX` repeatedly
- Final line: `EXIT: unregistered from user space`
- `/sys/kernel/sched_ext/current` doesn't exist or shows "none"

This indicates the scheduler binary ran, but the BPF program **never attached to the kernel**. The stats are likely reading from an uninitialized map (all zeros).

## Immediate Diagnostic Steps

### 1. Check Scheduler Logs

The scheduler output is redirected to log files. Check them:

```bash
# Check control version log
cat /tmp/scheduler_control.log

# Check test version log  
cat /tmp/scheduler_test.log
```

**Look for:**
- BPF verifier errors
- "Failed to load" messages
- "Permission denied" errors
- Missing helper function errors

### 2. Check Kernel Messages

```bash
# Check recent dmesg output
sudo dmesg | tail -50

# Or check the saved dmesg logs from the test
cat results/scx_simple/control/stress-ng_run1_dmesg.log
```

**Look for:**
- BPF verifier errors
- "sched_ext" related errors
- Helper function errors (especially `scx_bpf_map_scan_timeout`)

### 3. Verify Kernel Has sched_ext Support

```bash
# Check if sched_ext is enabled
ls -la /sys/kernel/sched_ext/

# Check current scheduler (should show "none" if nothing loaded)
cat /sys/kernel/sched_ext/current

# Check if CONFIG_SCHED_CLASS_EXT is enabled
zcat /proc/config.gz | grep CONFIG_SCHED_CLASS_EXT
# OR
grep CONFIG_SCHED_CLASS_EXT /boot/config-$(uname -r)
```

**Expected:** Should show `CONFIG_SCHED_CLASS_EXT=y`

### 4. Verify BPF Support

```bash
# Check BPF syscall
ls -la /sys/fs/bpf/

# Check if BPF helpers are available
bpftool feature probe | grep -i "sched\|map_scan"

# Check kernel version (should be 6.17+ with sched_ext patches)
uname -r
```

### 5. Test Manual Scheduler Load

Try loading the scheduler manually to see the exact error:

```bash
# Try loading control version manually
sudo ./build/scheds/c/scx_simple_control

# In another terminal, check if it loaded
cat /sys/kernel/sched_ext/current
```

## Common Issues and Fixes

### Issue 1: Kernel Doesn't Have sched_ext

**Symptoms:**
- `/sys/kernel/sched_ext/` doesn't exist
- `CONFIG_SCHED_CLASS_EXT` is not set

**Fix:**
- Rebuild kernel with `CONFIG_SCHED_CLASS_EXT=y`
- Or use a kernel that has sched_ext support (6.17+ with patches)

### Issue 2: Missing Helper Function

**Symptoms:**
- Log shows: "unknown func scx_bpf_map_scan_timeout"
- BPF verifier error about missing helper

**Fix:**
- Ensure kernel has the `scx_bpf_map_scan_timeout` helper implemented
- Check kernel source for helper registration
- Rebuild kernel if helper is missing

### Issue 3: BPF Verifier Errors

**Symptoms:**
- Log shows verifier errors
- "invalid access" or "R0 invalid" errors

**Fix:**
- Check the BPF code for verifier issues
- Ensure all memory accesses are bounds-checked
- Check for uninitialized variables
- Review verifier log in dmesg

### Issue 4: Permission Denied

**Symptoms:**
- "Permission denied" in logs
- Scheduler exits immediately

**Fix:**
- Ensure running with `sudo`
- Check SELinux/AppArmor policies
- Verify user has CAP_BPF capability

### Issue 5: Scheduler Binary Crashes

**Symptoms:**
- Process dies immediately
- No output in logs

**Fix:**
- Check if binary is built correctly
- Verify all dependencies are present (libbpf, etc.)
- Run with `strace` to see system calls:
  ```bash
  sudo strace -e trace=open,openat,read,write ./build/scheds/c/scx_simple_control
  ```

## Expected vs Actual Behavior

### Expected (Working)
```
$ cat /sys/kernel/sched_ext/current
simple
```

### Actual (Broken)
```
$ cat /sys/kernel/sched_ext/current
none
```

## Debugging Workflow

1. **Check logs first** (`/tmp/scheduler_*.log`)
2. **Check dmesg** for kernel errors
3. **Verify kernel support** (`/sys/kernel/sched_ext/`)
4. **Test manual load** to see exact error
5. **Check BPF verifier** output in dmesg
6. **Verify helper functions** are available

## Getting More Verbose Output

To get more detailed error messages, you can modify the scheduler to run with verbose output:

```bash
# Run scheduler with verbose flag
sudo ./build/scheds/c/scx_simple_control -v
```

Or check the libbpf debug output by setting:
```bash
export LIBBPF_LOG_LEVEL=4  # Maximum verbosity
sudo ./build/scheds/c/scx_simple_control
```

## Using the Diagnostic Script

A diagnostic script is available to help identify the issue:

```bash
./scripts/diagnose_scheduler.sh scx_simple
```

This script will:
1. Check kernel sched_ext support
2. Verify scheduler binary exists
3. Check recent dmesg messages
4. Attempt to load the scheduler manually
5. Check if it successfully loaded
6. Show relevant log output and errors

## Next Steps

Once you identify the issue:
1. Fix the root cause (kernel config, code issue, etc.)
2. Rebuild if necessary
3. Test manual load again
4. Re-run the experiment script

## Example: Checking Logs

```bash
# After a failed run, check what happened
echo "=== Control Log ==="
cat /tmp/scheduler_control.log

echo "=== Test Log ==="
cat /tmp/scheduler_test.log

echo "=== Recent dmesg ==="
sudo dmesg | tail -30

echo "=== Current Scheduler ==="
cat /sys/kernel/sched_ext/current
```

