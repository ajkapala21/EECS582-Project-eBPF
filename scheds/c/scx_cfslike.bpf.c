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

char _license[] SEC("license") = "GPL";

#define MAX_CPUS 256

#define DEFAULT_SLICE_NS 4000000ULL   // 4 ms

UEI_DEFINE(uei);


// per-CPU RBTree pointer

// load is used for load balancing across cpus and min vruntime is used to intialize new tasks
struct cpu_rq {
    struct bpf_spin_lock lock;
    struct bpf_rb_root rbtree __contains(struct task_info, rb_node);
    u64 total_weight;
    u64 min_vruntime;
};

struct task_info {
    struct bpf_rb_node rb_node;
    u64 vruntime;
    u32 weight;
    u64 start;
    u32 pid;
};

// task info map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(struct task_info));
    __uint(max_entries, 65536);
} task_info_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 3);
} stats SEC(".maps");

static void stat_inc(u32 idx)
{
	u64 *cnt_p = bpf_map_lookup_elem(&stats, &idx);
	if (cnt_p)
		(*cnt_p)++;
}

static void stats_set(u64 time)
{
    u64 *min_vruntime = bpf_map_lookup_elem(&stats, &(u32){2});
    if(min_vruntime){
        if(time > (*min_vruntime)){
            (*min_vruntime) = time;
        }
    }
}

static bool node_less(struct bpf_rb_node *a, const struct bpf_rb_node *b)
{
	struct task_info *ti_a, *ti_b;

	ti_a = container_of(a, struct task_info, rb_node);
	ti_b = container_of(b, struct task_info, rb_node);

	return ti_a->vruntime < ti_b->vruntime;
}
// array of my cpu_rqs
private(PERCPU_RQ) struct cpu_rq cpu_rqs[MAX_CPUS];

s32 BPF_STRUCT_OPS_SLEEPABLE(cfslike_init) // return 0 on succes
{
    for (u32 cpu = 0; cpu < scx_bpf_nr_cpu_ids() && cpu < MAX_CPUS; cpu++) {
        struct cpu_rq *rq = &cpu_rqs[cpu];
        rq->total_weight = 0;
        rq->min_vruntime = 0;
        rq->start = 0;
    }
    return 0;
}

s32 BPF_STRUCT_OPS(cfslike_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
    return prev_cpu;
}

void BPF_STRUCT_OPS(cfslike_enqueue, struct task_struct *p, u64 enq_flags)
{
    //initialize task map if needed
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct cpu_rq *rq = &cpu_rqs[cpu];

    struct task_info new_info = {};
    new_info.vruntime = rq->min_vruntime;

    int nice = BPF_CORE_READ(p, static_prio) - 120;
    //new_info.weight = nice_to_weight(nice);
    new_info.weight = nice;
    new_info.pid = pid;

    bpf_map_update_elem(&task_info_map, &pid, &new_info, BPF_ANY);
    struct task_info *ti = bpf_map_lookup_elem(&task_info_map, &pid);
    if(!ti){
        return;
    }

    // insert into this cpu's rbTree
    bpf_spin_lock(&rq->lock);
    bpf_rbtree_add(&rq->rbtree, &ti->rb_node, node_less);
    rq->total_weight += ti->weight;
    bpf_spin_unlock(&rq->lock);
}

void BPF_STRUCT_OPS(cfslike_dispatch, s32 cpu, struct task_struct *prev)
{
    struct bpf_rb_node *rb_node;
	struct task_info *ti;

	// look at this cpus rbtree and grab first task
    struct cpu_rq *rq = &cpu_rqs[cpu];

    bpf_spin_lock(&rq->lock);

	rb_node = bpf_rbtree_first(&rq->rbtree);
	if (!rb_node) {
		bpf_spin_unlock(&rq->lock);
        // no nodes in RBTree
		return;
	}

	rb_node = bpf_rbtree_remove(&rq->rbtree, rb_node);
	bpf_spin_unlock(&rq->lock);

	if (!rb_node) {
		/*
		 * This should never happen. bpf_rbtree_first() was called
		 * above while the tree lock was held, so the node should
		 * always be present.
		 */
		scx_bpf_error("node could not be removed");
		return;
	}

	ti = container_of(rb_node, struct task_info, rb_node);
   
    struct task_struct *p = bpf_task_from_pid(ti->pid);
    if (!p)
        return;  // task died, ignore and continue

    scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, DEFAULT_SLICE_NS, 0);
    
    stat_inc(0);
}

void BPF_STRUCT_OPS(cfslike_running, struct task_struct *p)
{
	// update this cpus min vruntime if necessary
    u32 cpu = bpf_get_smp_processor_id();
    u32 pid = p->pid;
    struct cpu_rq *rq = &cpu_rqs[cpu];

    struct task_info *info = bpf_map_lookup_elem(&task_info_map, &pid);
    if (!info) return;

    if (info->vruntime > rq->min_vruntime) {
        rq->min_vruntime = info->vruntime;
        stats_set(info->vruntime);
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
    struct cpu_rq *rq = &cpu_rqs[cpu];

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
