/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A cfs-like scheduler.


    For now do not worry about load balancing, can worry about that later
    We I get to that point it should basically be done periodically when needed.
    Could be in cpu select and keep track of most loaded cpu globally, then if I notice the current cpu
    is like 25% less or whatever I could move some over or if mine it way above the least I could
    move some over.

    Can also make time slice dynamic
 */
#include <scx/common.bpf.h>
#include <scx/bpf_arena_common.bpf.h>
#include <lib/rbtree.h>

char _license[] SEC("license") = "GPL";

#define MAX_CPUS 256

#define DEFAULT_SLICE_NS 4000000ULL   // 4 ms

UEI_DEFINE(uei);


// per-CPU RBTree pointer

// load is used for load balancing across cpus and min vruntime is used to intialize new tasks
struct cpu_rq {
    u64 rbtree;
    u64 total_weight;
    u64 min_vruntime;
};

// map from cpu -> cpu_rq info
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(struct cpu_rq));
    __uint(max_entries, MAX_CPUS);
} cpu_map SEC(".maps");

struct task_info {
    u64 vruntime;
    u32 weight;
    u64 start;
    u64 end;
};

// task info map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(key_size, sizeof(u64));
    __uint(value_size, sizeof(struct task_info));
    __uint(max_entries, 65536);
} task_info_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 2);			/* [local, global] */
} stats SEC(".maps");

static void stat_inc(u32 idx)
{
	u64 *cnt_p = bpf_map_lookup_elem(&stats, &idx);
	if (cnt_p)
		(*cnt_p)++;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(cfslike_init) // return 0 on succes
{
    return 0;
}

s32 BPF_STRUCT_OPS(cfslike_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
    return prev_cpu;
}

void BPF_STRUCT_OPS_SLEEPABLE(cfslike_cpu_acquire, s32 cpu)
{
    struct cpu_rq init_rq = {};
        
    u64 rb_ptr = (u64)rb_create(RB_ALLOC, RB_DUPLICATE);
    if (!rb_ptr)
        return;
    
    init_rq.rbtree = rb_ptr;
    init_rq.total_weight = 0;
    init_rq.min_vruntime = 0;

    // update the map in place
    bpf_map_update_elem(&cpu_map, &cpu, &init_rq, BPF_ANY);
}

void BPF_STRUCT_OPS(cfslike_enqueue, struct task_struct *p, u64 enq_flags)
{
    //initialize task map if needed
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct cpu_rq *rq = bpf_map_lookup_elem(&cpu_map, &cpu);
    if (!rq){
        return;
    }

    struct task_info *ti = bpf_map_lookup_elem(&task_info_map, &pid);
    if(!ti){
        struct task_info new_info = {};
        new_info.vruntime = rq->min_vruntime;

        int nice = BPF_CORE_READ(p, static_prio) - 120;
        //new_info.weight = nice_to_weight(nice);
        new_info.weight = nice;

        bpf_map_update_elem(&task_info_map, &pid, &new_info, BPF_ANY);

        rq->total_weight += new_info.weight;
        ti = bpf_map_lookup_elem(&task_info_map, &pid);
    }
    if(!ti){
        return;
    }

    // insert into this cpu's rbTree
    rb_insert((rbtree_t *)rq->rbtree, ti->vruntime, (u64)p);
}

void BPF_STRUCT_OPS(cfslike_dispatch, s32 cpu, struct task_struct *prev)
{
	// look at this cpus rbtree and grab first task
    struct cpu_rq *rq = bpf_map_lookup_elem(&cpu_map, &cpu);
    if (!rq) return;

    u64 key, value;

    int ret = rb_pop((rbtree_t *)rq->rbtree, &key, &value);
    if (ret == 0) {
        scx_bpf_dsq_insert((struct task_struct *)value, SCX_DSQ_LOCAL, DEFAULT_SLICE_NS, 0);
    }
    stat_inc(0);
}

void BPF_STRUCT_OPS(cfslike_running, struct task_struct *p)
{
	// update this cpus min vruntime if necessary
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct cpu_rq *rq = bpf_map_lookup_elem(&cpu_map, &cpu);
    if (!rq){
        return;
    }

    struct task_info *info = bpf_map_lookup_elem(&task_info_map, &pid);
    if (!info) return;

    if (info->vruntime > rq->min_vruntime) {
        rq->min_vruntime = info->vruntime;
    }
    info->start = bpf_ktime_get_ns();
}

void BPF_STRUCT_OPS(cfslike_stopping, struct task_struct *p, bool runnable)
{
    u32 pid = p->pid;
	// update this tasks vruntime
    struct task_info *info = bpf_map_lookup_elem(&task_info_map, &pid);
    if (!info) return;

    // need to update this to change 100 to a real nice value/weight
    info->vruntime += (bpf_ktime_get_ns() - info->start) * 100 / info->weight;
    stat_inc(1);
}

void BPF_STRUCT_OPS(cfslike_enable, struct task_struct *p) // called when a task is about to start running on a cpu for first time under this scheduler
{
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct cpu_rq *rq = bpf_map_lookup_elem(&cpu_map, &cpu);
    if (!rq){
        return;
    }

	// update vruntime to this cpus min vruntime
    struct task_info *info = bpf_map_lookup_elem(&task_info_map, &pid);
    if (!info) return;

    info->vruntime = rq->min_vruntime;
}

void BPF_STRUCT_OPS(cfslike_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(cfslike_ops,
	       .select_cpu		= (void *)cfslike_select_cpu,
	       .enqueue			= (void *)cfslike_enqueue,
	       .dispatch		= (void *)cfslike_dispatch,
	       .running			= (void *)cfslike_running,
	       .stopping		= (void *)cfslike_stopping,
	       .enable			= (void *)cfslike_enable,
	       .init			= (void *)cfslike_init,
	       .exit			= (void *)cfslike_exit,
	       .name			= "cfslike");
