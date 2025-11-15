// scx_cfs.bpf.c
// SPDX-License-Identifier: GPL-2.0
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <scx/common.bpf.h>   // sched_ext helpers / prototypes

char LICENSE[] SEC("license") = "GPL";

/* per-task info */
struct task_info {
    __u64 vruntime;      /* monotonic virtual runtime */
    __u64 weight;        /* weight derived from nice */
    __u64 last_start;    /* ns timestamp when task was scheduled */
};

/* pid -> task_info */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __type(key, __u32);           // pid
    __type(value, struct task_info);
} tasks SEC(".maps");

/* cpu -> chosen pid (user-space writes chosen pid here) */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);           // cpu index (we'll use index 0 and per-cpu semantics)
    __type(value, __u32);         // pid
} chosen_task SEC(".maps");

/* ring buffer to notify user-space about events */
struct cfs_event {
    __u32 type;   // 1=enq, 2=deq, 3=running_update
    __u32 pid;
    __u64 vruntime;
};
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // adjust
} events SEC(".maps");

/* helpers to publish event */
static __always_inline void push_event(__u32 type, __u32 pid, __u64 vruntime) {
    struct cfs_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return;
    e->type = type; e->pid = pid; e->vruntime = vruntime;
    bpf_ringbuf_submit(e, 0);
}

/* Called when task becomes runnable */
SEC("sched_ext/enqueue")
int BPF_PROG(on_enqueue, struct task_struct *p, u64 flags)
{
    __u32 pid = p->pid;
    struct task_info info = {};
    /* initialize vruntime, weight (simplified) */
    info.vruntime = 0; /* user-space may set better baseline on first event */
    info.weight = 1024; /* default; more accurate weight can be computed in userspace */
    info.last_start = 0;
    bpf_map_update_elem(&tasks, &pid, &info, BPF_ANY);
    push_event(1, pid, info.vruntime);
    return 0;
}

/* Called when task stops being runnable */
SEC("sched_ext/dequeue")
int BPF_PROG(on_dequeue, struct task_struct *p, int flags)
{
    __u32 pid = p->pid;
    /* remove from map; userspace will also be notified */
    bpf_map_delete_elem(&tasks, &pid);
    push_event(2, pid, 0);
    return 0;
}

/* pick_next_task: return task pointer chosen by userspace */
SEC("sched_ext/pick_next_task")
struct task_struct *BPF_PROG(pick_next, int cpu, struct task_struct *prev)
{
    __u32 key = 0;
    __u32 *pidp = bpf_map_lookup_elem(&chosen_task, &key);
    if (!pidp || *pidp == 0)
        return NULL;

    /* convert pid -> task_struct*; helper available in sched_ext helper set */
    struct task_struct *next = bpf_task_from_pid(*pidp);
    if (!next)
        return NULL;

    /* clear chosen slot to indicate it's consumed (optional) */
    __u32 zero = 0;
    bpf_map_update_elem(&chosen_task, &key, &zero, BPF_ANY);

    /* update last_start in the tasks map */
    struct task_info *info = bpf_map_lookup_elem(&tasks, pidp);
    if (info)
        info->last_start = bpf_ktime_get_ns();

    return next;
}

/* Optionally track running -> update vruntime stats (simple) */
SEC("sched_ext/running")
int BPF_PROG(on_running, struct task_struct *p)
{
    /* This hook can be used to update bookkeeping or sample runtime. However,
       more accurate accounting often occurs on dequeue or via tick hooks. */
    return 0;
}