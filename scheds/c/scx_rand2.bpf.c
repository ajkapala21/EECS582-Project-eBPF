/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A Rand scheduler.
 *
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define MAX_TASKS 65536
#define SAMPLE_WINDOW_NS 500
#define SAMPLE_COUNT 500

static u64 vtime_now;
static u32 map_size = 0;

UEI_DEFINE(uei);
#define SHARED_DSQ 0

struct task_ctx {
    u32 pid;
    u64 vruntime;
    bool valid;
};

private(rand) struct bpf_spin_lock map_lock;

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_TASKS);
    __type(key, u32);
    __type(value, struct task_ctx);
} task_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} map_info SEC(".maps");

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

s32 BPF_STRUCT_OPS(rand2_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
	bool is_idle = false;
	s32 cpu;

	cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
	if (is_idle) {
		stat_inc(0);	/* count local queueing */
		scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
	}

	return cpu;
}

void BPF_STRUCT_OPS(rand2_enqueue, struct task_struct *p, u64 enq_flags)
{
	stat_inc(1);	/* count global queueing */

    scx_bpf_random_enqueue(&task_map, &map_info, p, &vtime_now);

    //bpf_printk("Enqueue: map_size = %llu\n", map_size);
}


void BPF_STRUCT_OPS(rand2_dispatch, s32 cpu, struct task_struct *prev)
{

    int res = scx_bpf_random_sample(task_map, map_info, SAMPLE_WINDOW_NS);
    if(res == -1){
        return;
    }
    struct task_struct *task = bpf_task_from_pid(pid);
    if (!task){
        //bpf_printk("task struct null\n");
        return;
    }
    scx_bpf_dsq_insert(task, SHARED_DSQ, SCX_SLICE_DFL, 0);
    bpf_task_release(task);
    //bpf_printk("Successful Dispatch\n");
    stat_inc(2);
    scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(rand2_running, struct task_struct *p)
{
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(rand2_stopping, struct task_struct *p, bool runnable)
{
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}

void BPF_STRUCT_OPS(rand2_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(rand2_init)
{
	return scx_bpf_create_dsq(SHARED_DSQ, -1);
}

void BPF_STRUCT_OPS(rand2_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(rand2_ops,
	       .select_cpu		= (void *)rand2_select_cpu,
	       .enqueue			= (void *)rand2_enqueue,
	       .dispatch		= (void *)rand2_dispatch,
	       .running			= (void *)rand2_running,
	       .stopping		= (void *)rand2_stopping,
	       .enable			= (void *)rand2_enable,
	       .exit			= (void *)rand2_exit,
           .init			= (void *)rand2_init,
	       .name			= "rand2");