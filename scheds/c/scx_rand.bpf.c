/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A Rand scheduler.
 *
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define MAX_TASKS 65536

static u64 vtime_now;
UEI_DEFINE(uei);

struct task_ctx {
    u32 pid;
    u64 vruntime;
};

#define SHARED_DSQ 0
const volatile bool fifo_sched;

private(rand) struct bpf_spin_lock global_lock;

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_TASKS);
    __type(key, u32);
    __type(value, struct task_ctx);
} task_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 2);
} stats SEC(".maps");

static void stat_inc(u32 idx)
{
	u64 *cnt_p = bpf_map_lookup_elem(&stats, &idx);
	if (cnt_p)
		(*cnt_p)++;
}

s32 BPF_STRUCT_OPS(rand_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
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

void BPF_STRUCT_OPS(rand_enqueue, struct task_struct *p, u64 enq_flags)
{
	stat_inc(1);	/* count global queueing */

	if (fifo_sched) {
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	} else {
		u64 vtime = p->scx.dsq_vtime;

		/*
		 * Limit the amount of budget that an idling task can accumulate
		 * to one slice.
		 */
		if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
			vtime = vtime_now - SCX_SLICE_DFL;

		scx_bpf_dsq_insert_vtime(p, SHARED_DSQ, SCX_SLICE_DFL, vtime,
					 enq_flags);
	}
}

void BPF_STRUCT_OPS(rand_dispatch, s32 cpu, struct task_struct *prev)
{
	// my custom rand logic

    // dispatch

    // remove task from rq array 

    scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(rand_running, struct task_struct *p)
{
	if (fifo_sched)
		return;

	/*
	 * Global vtime always progresses forward as tasks start executing. The
	 * test and update can be performed concurrently from multiple CPUs and
	 * thus racy. Any error should be contained and temporary. Let's just
	 * live with it.
	 */
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(rand_stopping, struct task_struct *p, bool runnable)
{
	if (fifo_sched)
		return;

	/*
	 * Scale the execution time by the inverse of the weight and charge.
	 *
	 * Note that the default yield implementation yields by setting
	 * @p->scx.slice to zero and the following would treat the yielding task
	 * as if it has consumed all its slice. If this penalizes yielding tasks
	 * too much, determine the execution time by taking explicit timestamps
	 * instead of depending on @p->scx.slice.
	 */
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}

void BPF_STRUCT_OPS(rand_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(rand_init)
{
	return scx_bpf_create_dsq(SHARED_DSQ, -1);
}

void BPF_STRUCT_OPS(rand_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(rand_ops,
	       .select_cpu		= (void *)rand_select_cpu,
	       .enqueue			= (void *)rand_enqueue,
	       .dispatch		= (void *)rand_dispatch,
	       .running			= (void *)rand_running,
	       .stopping		= (void *)rand_stopping,
	       .enable			= (void *)rand_enable,
	       .exit			= (void *)rand_exit,
	       .name			= "rand");
