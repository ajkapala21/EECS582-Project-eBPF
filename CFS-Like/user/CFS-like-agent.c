/* user space agent */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <bpf/libbpf.h>



#include "scx_cfs.skel.h"   // libbpf-generated skeleton from scx_cfs.bpf.o
#include "rb.h"

struct cfs_task {
    __u32 pid;
    __u64 vruntime;
    __u64 weight;
    struct rb_node node;
    /* other bookkeeping */
};

/* comparator: order by vruntime, tie-break by pid */
static inline int task_cmp(const struct cfs_task *a, const struct cfs_task *b) {
    if (a->vruntime < b->vruntime) return -1;
    if (a->vruntime > b->vruntime) return 1;
    if (a->pid < b->pid) return -1;
    if (a->pid > b->pid) return 1;
    return 0;
}

/* global tree root */
struct rb_root root = RB_ROOT;

/* map fds (populated after loading BPF) */
int fd_tasks_map = -1;
int fd_chosen_map = -1;

/* helper: insert or update task in RB tree */
void insert_or_update_task(__u32 pid, __u64 vruntime, __u64 weight) {
    /* find existing node by pid (you may keep an aux hash for O(1) pid→node), but
       for simplicity we can remove old and insert new. In a full implementation use
       a hash to avoid O(n) lookup. */
    struct cfs_task *t = malloc(sizeof(*t));
    t->pid = pid; t->vruntime = vruntime; t->weight = weight;
    struct rb_node **p = &root.rb_node, *parent = NULL;
    while (*p) {
        struct cfs_task *cur = container_of(*p, struct cfs_task, node);
        parent = *p;
        if (task_cmp(t, cur) < 0)
            p = &(*p)->rb_left;
        else
            p = &(*p)->rb_right;
    }
    rb_link_node(&t->node, parent, p);
    rb_insert_color(&t->node, &root);
}

/* remove by pid: you'd normally use a pid->node hash. Omitted for brevity. */

/* pick min (leftmost) */
struct cfs_task *pick_min_task() {
    struct rb_node *n = rb_first(&root);
    if (!n) return NULL;
    return container_of(n, struct cfs_task, node);
}

/* ring buffer consumer callback */
static int handle_event(void *ctx, void *data, size_t len) {
    struct cfs_event *e = data;
    if (e->type == 1) { // enqueue
        /* read task info from BPF tasks map for accurate vruntime/weight */
        struct task_info ti;
        __u32 key = e->pid;
        if (bpf_map_lookup_elem(fd_tasks_map, &key, &ti) == 0) {
            insert_or_update_task(e->pid, ti.vruntime, ti.weight);
        } else {
            /* fallback: use event vruntime */
            insert_or_update_task(e->pid, e->vruntime, 1024);
        }
    } else if (e->type == 2) { // dequeue
        /* remove from tree (implement remove_by_pid) */
        remove_task_by_pid(e->pid);
    }
    /* After updating the tree, you can choose tasks for CPUs */
    /* Example: pick min and write to chosen_task[0] (per-cpu slot) */
    struct cfs_task *c = pick_min_task();
    if (c) {
        __u32 chosen = c->pid;
        __u32 cpu_key = 0; /* index 0 uses per-cpu semantics */
        bpf_map_update_elem(fd_chosen_map, &cpu_key, &chosen, BPF_ANY);
    }
    return 0;
}

int main(int argc, char **argv) {
    struct scx_cfs_bpf *skel;
    /* open/load/attach bpf using skeleton */
    skel = scx_cfs_bpf__open_and_load();
    scx_cfs_bpf__attach(skel);

    fd_tasks_map = bpf_map__fd(skel->maps.tasks);
    fd_chosen_map = bpf_map__fd(skel->maps.chosen_task);

    /* set up ringbuf consumer */
    struct ring_buffer *rb = ring_buffer__new(bpf_map__fd(skel->maps.events),
                                              handle_event, NULL, NULL);

    while (!exiting) {
        ring_buffer__poll(rb, 100 /* ms */);
    }

    /* cleanup */
    ring_buffer__free(rb);
    scx_cfs_bpf__destroy(skel);
    return 0;
}