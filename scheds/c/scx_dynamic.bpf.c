/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A dynamically time bounded random scheduler.
 *
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define MAX_TASKS 65536
#define SAMPLE_WINDOW_MIN 500
#define SAMPLE_WINDOW_MAX 50000
#define SAMPLE_WINDOW_NS 500
#define SAMPLE_COUNT 500

static u64 vtime_now;
static u32 map_size = 0;
static u64 sampling_bound_ns = 500;
static u64 avg_slice_used = 20000000; //20ms = SCX_SLICE_DFL

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

private(dynamic) struct bpf_spin_lock map_lock;

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

s32 BPF_STRUCT_OPS(dynamic_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
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

void BPF_STRUCT_OPS(dynamic_enqueue, struct task_struct *p, u64 enq_flags)
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

    //bpf_printk("Enqueue: map_size = %llu\n", map_size);
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

void BPF_STRUCT_OPS(dynamic_dispatch, s32 cpu, struct task_struct *prev)
{
    //bpf_printk("Dispatch Started: map_size = %llu\n", map_size);
	// my custom rand logic to choose task
    struct random_sample_ctx s = {
        .start_ns = bpf_ktime_get_ns(),
        .window_ns = SAMPLE_WINDOW_NS,
        .best_vtime = (u64)-1,
        .best_key = -1,
    };

    if(map_size > 1){
        long ret = bpf_loop(SAMPLE_COUNT, sample_cb, &s, 0);
        
        // dispatch
        if (s.best_key >= 0) {
            //bpf_printk("Key Found\n");
            struct task_ctx *ti_dis = bpf_map_lookup_elem(&task_map, &s.best_key);
            if (!ti_dis) {
                //bpf_printk("TI_DIS null\n");
                return; 
            }
            bpf_spin_lock(&map_lock);
            u32 key = map_size - 1;
            bpf_spin_unlock(&map_lock);
            struct task_ctx *ti_last = bpf_map_lookup_elem(&task_map, &key);
            if (!ti_last){
                //bpf_printk("TI_LAST null\n");
                return;
            }
            //invalidate first to ensure only one cpu can dispatch this task
            bpf_spin_lock(&map_lock);
            if(!ti_dis->valid || !ti_last->valid || key != map_size - 1){
                bpf_spin_unlock(&map_lock);
                //bpf_printk("TI_DIS OR TI_LAST INVALID OR RACE DETECTED\n");
                return;
            }
            // invalidate last task in array and decrement map size
            map_size--;
            ti_last->valid = false;

            u32 pid = ti_dis->pid;

            // then move that tasks info to the index of our one about to be dispatched
            ti_dis->pid = ti_last->pid;
            ti_dis->vruntime = ti_last->vruntime;
            bpf_spin_unlock(&map_lock);
            //convert pid to task struct and dispatch that
            struct task_struct *task = bpf_task_from_pid(pid);
            if (!task){
                //bpf_printk("task struct null\n");
                return;
            }

            scx_bpf_dsq_insert(task, SHARED_DSQ, SCX_SLICE_DFL, 0);
            bpf_task_release(task);
            //bpf_printk("Successful Dispatch\n");
            stat_inc(2);
        }
        else{
            //bpf_printk("Nothing decided: map_size = %llu\n", map_size);
        }
    }
    if(map_size == 1){
        u32 key = 0;
        struct task_ctx *ti = bpf_map_lookup_elem(&task_map, &key);
        if (!ti){
            //bpf_printk("TI null\n");
            return;
        }
        //invalidate first to ensure only one cpu can dispatch this task
        bpf_spin_lock(&map_lock);
        if(!ti->valid || map_size != 1){
            bpf_spin_unlock(&map_lock);
            //bpf_printk("TI INVALID OR RACE DETECTED\n");
            return;
        }
        // invalidate the task in array and decrement map size
        map_size--;
        ti->valid = false;
        u32 pid = ti->pid;

        bpf_spin_unlock(&map_lock);

        struct task_struct *task = bpf_task_from_pid(pid);
        if (!task){
            //bpf_printk("task struct null\n");
            return;
        }
        scx_bpf_dsq_insert(task, SHARED_DSQ, SCX_SLICE_DFL, 0);
        bpf_task_release(task);
        //bpf_printk("Successful Dispatch\n");
        stat_inc(2);
    }
    scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(dynamic_running, struct task_struct *p)
{
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(dynamic_stopping, struct task_struct *p, bool runnable)
{
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
    u64 a = 85;
    avg_slice_used = (avg_slice_used * a + (SCX_SLICE_DFL - p->scx.slice) * (100 - a)) / 100;
    bpf_printk("Avg slice used in nanoseconds: %llu\n", avg_slice_used);
}

void BPF_STRUCT_OPS(dynamic_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(dynamic_init)
{
	return scx_bpf_create_dsq(SHARED_DSQ, -1);
}

void BPF_STRUCT_OPS(dynamic_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(dynamic_ops,
	       .select_cpu		= (void *)dynamic_select_cpu,
	       .enqueue			= (void *)dynamic_enqueue,
	       .dispatch		= (void *)dynamic_dispatch,
	       .running			= (void *)dynamic_running,
	       .stopping		= (void *)dynamic_stopping,
	       .enable			= (void *)dynamic_enable,
	       .exit			= (void *)dynamic_exit,
           .init			= (void *)dynamic_init,
	       .name			= "dynamic");
