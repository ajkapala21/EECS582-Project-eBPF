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
static index = 0;


UEI_DEFINE(uei);

struct random_sample_ctx {
    u64 start_ns;
    u64 window_ns;
    u64 best_vtime;
    int  best_key;
};

struct task_ctx {
    u32 pid;
    u64 vruntime;
    bool valid;
};

struct map_ctx {
    u64 size;
    struct bpf_spin_lock lock;
};

//int cpu = bpf_get_smp_processor_id();
//int nr = scx_bpf_nr_cpu_ids();
//bpf_map_lookup_percpu_elem(map, &key, cpu_id);

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, MAX_TASKS);
    __type(key, u32);
    __type(value, struct task_ctx);
} task_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct map_ctx);
} map_size SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u32);
} cpu_rr_idx SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 3);
} stats SEC(".maps");

private(rand) struct bpf_spin_lock cpu_lock;

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

    u64 vtime = p->scx.dsq_vtime;
    u32 pid = p->pid;

    if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
        vtime = vtime_now - SCX_SLICE_DFL;

    bpf_spin_lock(&cpu_lock);
    u32 cpu_id = index % scx_bpf_nr_cpu_ids();
    index = (index + 1) % scx_bpf_nr_cpu_ids();
    bpf_spin_unlock(&cpu_lock);

    u32 zero = 0;
    struct map_ctx *context = bpf_map_lookup_percpu_elem(map_size, &zero, cpu_id);
    if(!context){
        bpf_printk("NO CONTEXT FOUND\n");
        return;
    }

    u64 size = context->size;
    struct task_ctx *ti = bpf_map_lookup_percpu_elem(task_map, &size, cpu_id);
    if(!ti){
        bpf_printk("to large of size\n");
        return;
    }

    bpf_spin_lock(&context->lock);
    if(context->size != size){
        bpf_printk("RACE CONDITION: TASK LOST \n");
        return;
    }
    ti->vruntime = vtime;
    ti->pid = pid;
    ti->valid = valid;

    bpf_spin_unlock(&context->unlock);
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
    if (bpf_ktime_get_ns() - s->start_ns >= s->window_ns || idx >= map_size){
        //bpf_printk("Exited because of time: %llu\n", idx);
        return 1; // bpf_loop will stop early if callback returns 1
    }

    // may want to also add logic to cancel if you have sampled more than the size map_size
    // currently with the static window of 500ns it samples around 15 (on my pc)
    // this is overkill if the map_size is small, which it often will be, although maybe not
    // for benchmarks
        
    return 0; // continue
}

void BPF_STRUCT_OPS(rand2_dispatch, s32 cpu, struct task_struct *prev)
{


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