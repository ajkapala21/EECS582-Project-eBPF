/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A Rand scheduler.
 *
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define MAX_TASKS 65536
#define SAMPLE_WINDOW_NS 2000
#define SAMPLE_COUNT 2000

static u64 vtime_now;
static u32 map_size = 0;

UEI_DEFINE(uei);
#define SHARED_DSQ 0

struct random_sample_ctx {
    u64 start_ns;
    u64 window_ns;
    u64 best_vtime;
    int  best_key;
};

struct task_ctx {
    struct bpf_spin_lock lock;
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

    u64 vtime = p->scx.dsq_vtime;
    u32 pid = p->pid;

    if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
        vtime = vtime_now - SCX_SLICE_DFL;

    bpf_spin_lock(&map_lock);
    u32 sz = map_size;
    map_size++;
    bpf_spin_unlock(&map_lock);

    struct task_ctx *ti = bpf_map_lookup_elem(&task_map, &sz);
    if (!ti) return;

    bpf_spin_lock(&map_lock);
    ti->vruntime += vtime;
    ti->pid = pid;
    ti->valid = true;
    bpf_spin_unlock(&map_lock);

    bpf_printk("Enqueue: map_size = %llu\n", map_size);
}

static long sample_cb(u64 idx, struct random_sample_ctx *rand_cxt)
{
    struct random_sample_ctx *s = (struct random_sample_ctx *)rand_cxt;

    // use bpf_get_prandom_u32() inside callback
    u32 r = bpf_get_prandom_u32();
    bpf_spin_lock(&map_lock);
    u32 key = r % map_size;
    bpf_spin_unlock(&map_lock);
    struct task_ctx *ti = bpf_map_lookup_elem(&task_map, &key);
    if (!ti || !ti->valid) return 0; // continue

    if (ti->vruntime < s->best_vtime) {
        s->best_vtime = ti->vruntime;
        s->best_key = key;
    }

    // Optional early exit if time exceeded:
    if (bpf_ktime_get_ns() - s->start_ns >= s->window_ns)
        return 1; // bpf_loop will stop early if callback returns 1

    return 0; // continue
}

void BPF_STRUCT_OPS(rand_dispatch, s32 cpu, struct task_struct *prev)
{
    bpf_printk("Dispatch Started: map_size = %llu\n", map_size);
	// my custom rand logic to choose task
    struct random_sample_ctx s = {
        .start_ns = bpf_ktime_get_ns(),
        .window_ns = SAMPLE_WINDOW_NS,
        .best_vtime = (u64)-1,
        .best_key = -1,
    };

    long ret = bpf_loop(SAMPLE_COUNT, sample_cb, &s, 0);
    
    u32 pid;
    // dispatch
    if (s.best_key >= 0) {
        bpf_printk("Key Found\n");
        struct task_ctx *ti_dis = bpf_map_lookup_elem(&task_map, &s.best_key);
            if (!ti_dis) return; // continue
        u32 key = map_size - 1;
        struct task_ctx *ti_last = bpf_map_lookup_elem(&task_map, &key);
            if (!ti_last) return; // continue
        //invalidate first to ensure only one cpu can dispatch this task
        bpf_spin_lock(&map_lock);
        if(!ti_dis->valid || !ti_last->valid){
            bpf_spin_unlock(&map_lock);
            return;
        }
        // invalidate last task in array and decrement map size
        map_size--;
        ti_last->valid = false;

        pid = ti_dis->pid;

        // then move that tasks info to the index of our one about to be dispatched
        ti_dis->pid = ti_last->pid;
        ti_dis->vruntime = ti_last->vruntime;
        bpf_spin_unlock(&map_lock);
        //convert pid to task struct and dispatch that
        struct task_struct *task = bpf_task_from_pid(pid);
        if (!task)
            return;

        //scx_bpf_dsq_insert(task, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
        scx_bpf_dsq_insert(task, SHARED_DSQ, SCX_SLICE_DFL, 0);
        bpf_task_release(task);
        bpf_printk("Successful Dispatch\n");
        stat_inc(2);
    }
    else{
        bpf_printk("Nothing decided: map_size = %llu\n", map_size);
    }
    scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(rand_running, struct task_struct *p)
{
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(rand_stopping, struct task_struct *p, bool runnable)
{
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
           .init			= (void *)rand_init,
	       .name			= "rand");
