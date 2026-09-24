/*
 * Embedded main-loop teardown tests.  These exercise real AioContexts, GLib
 * sources, timers and RCU on changing caller threads, not a machine emulator.
 * Passing them does NOT establish whole-machine/QEMU reentrancy.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/main-loop.h"
#include "qemu/rcu.h"
#include "qemu/timer.h"

typedef struct Cycle {
    int pipefd[2];
    unsigned bh_calls;
    unsigned fd_calls;
    unsigned timer_calls;
    unsigned rcu_calls;
    struct rcu_head rcu;
} Cycle;

static void count_bh(void *opaque)
{
    Cycle *c = opaque;
    c->bh_calls++;
}

static void read_pipe(void *opaque)
{
    Cycle *c = opaque;
    char byte;
    g_assert_cmpint(read(c->pipefd[0], &byte, 1), ==, 1);
    c->fd_calls++;
}

static void count_timer(void *opaque)
{
    Cycle *c = opaque;
    c->timer_calls++;
}

static void count_rcu(struct rcu_head *head)
{
    Cycle *c = container_of(head, Cycle, rcu);
    c->rcu_calls++;
}

static void *run_cycle(void *opaque)
{
    Cycle c = { 0 };
    QEMUBH *bh;
    QEMUTimer *timer;

    rcu_register_thread();
    g_assert_cmpint(qemu_init_main_loop(&error_abort), ==, 0);
    g_assert_nonnull(qemu_get_aio_context());
    g_assert_cmpint(pipe(c.pipefd), ==, 0);
    qemu_set_fd_handler(c.pipefd[0], read_pipe, NULL, &c);
    bh = qemu_bh_new(count_bh, &c);
    qemu_bh_schedule(bh);
    timer = timer_new_ns(QEMU_CLOCK_REALTIME, count_timer, &c);
    timer_mod(timer, qemu_clock_get_ns(QEMU_CLOCK_REALTIME));
    g_assert_cmpint(write(c.pipefd[1], "x", 1), ==, 1);

    for (unsigned i = 0; i < 1000 &&
         (!c.bh_calls || !c.fd_calls || !c.timer_calls); i++) {
        main_loop_wait(true);
    }
    g_assert_cmpuint(c.bh_calls, ==, 1);
    g_assert_cmpuint(c.fd_calls, ==, 1);
    g_assert_cmpuint(c.timer_calls, ==, 1);
    qemu_bh_delete(bh);
    timer_free(timer);
    qemu_set_fd_handler(c.pipefd[0], NULL, NULL, NULL);
    close(c.pipefd[0]);
    close(c.pipefd[1]);
    call_rcu1(&c.rcu, count_rcu);
    drain_call_rcu();
    g_assert_cmpuint(c.rcu_calls, ==, 1);

    qemu_hmos_main_loop_cleanup();
    g_assert_null(qemu_get_aio_context());
    /* A stale source must not call into c after its owner has gone away. */
    while (g_main_context_iteration(NULL, false)) {
    }
    rcu_unregister_thread();
    return NULL;
}

static unsigned fd_count(void)
{
    GDir *dir = g_dir_open("/proc/self/fd", 0, NULL);
    unsigned count = 0;

    g_assert_nonnull(dir);
    while (g_dir_read_name(dir)) {
        count++;
    }
    g_dir_close(dir);
    return count;
}

static void test_cycles(void)
{
    QemuThread thread;
    unsigned baseline;

    /* Warm up process-lifetime GLib resources before comparing descriptors. */
    run_cycle(NULL);
    baseline = fd_count();
    for (unsigned i = 0; i < 100; i++) {
        if (i & 1) {
            qemu_thread_create(&thread, "phone-loop-test", run_cycle, NULL,
                               QEMU_THREAD_JOINABLE);
            qemu_thread_join(&thread);
        } else {
            run_cycle(NULL);
        }
        g_assert_cmpuint(fd_count(), ==, baseline);
    }
}

static void test_live_bh_rejected(void)
{
    if (g_test_subprocess()) {
        rcu_register_thread();
        qemu_init_main_loop(&error_abort);
        /* Deliberately leave a live producer: cleanup must not hide the leak. */
        qemu_bh_schedule(qemu_bh_new(count_bh, NULL));
        qemu_hmos_main_loop_cleanup();
        g_assert_not_reached();
    }
    g_test_trap_subprocess(NULL, 5 * G_TIME_SPAN_SECOND, 0);
    g_test_trap_assert_failed();
    g_test_trap_assert_stderr("*BH*leaked*aborting*");
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/hmos-main-loop/repeated-home-threads", test_cycles);
    g_test_add_func("/hmos-main-loop/live-bh-rejected", test_live_bh_rejected);
    return g_test_run();
}
