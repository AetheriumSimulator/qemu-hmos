/*
 * Explicit embedded TCI entry. This module is never used by native children.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "qemu/rcu.h"
#include "system/qemu-hmos.h"
#include "system/replay.h"
#include "system/system.h"

#if !defined(CONFIG_HMOS_EMBEDDED_CORE) || !defined(CONFIG_TCG_INTERPRETER)
#error "The phone entry requires the dedicated embedded TCI build"
#endif

/* Do not advertise restartability until complete machine teardown, global
 * reset, vCPU/RCU draining and repeated real-device launches have passed.
 * The bridge exposes this as a release blocker, not a restart workaround.
 */
QEMU_HMOS_RETAIN const char qemu_hmos_phone_marker[] =
    "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0";

static pthread_mutex_t phone_session_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool phone_session_consumed;
static _Thread_local jmp_buf *phone_exit_target;
static _Thread_local int phone_exit_status;

static _Noreturn void phone_capture_exit(int status)
{
    if (!phone_exit_target) {
        /* A failure on a vCPU/IO thread is outside the entry's C stack.
         * Crossing threads with longjmp is invalid; retain the real fatal
         * process boundary rather than pretending memory corruption is safe.
         */
        abort();
    }
    phone_exit_status = status;
    longjmp(*phone_exit_target, 1);
}

/* Linker --wrap entry points, private to the embedded module. */
_Noreturn void __wrap_exit(int status);
_Noreturn void __wrap__exit(int status);
_Noreturn void __wrap__Exit(int status);
_Noreturn void __wrap_quick_exit(int status);

_Noreturn void __wrap_exit(int status) { phone_capture_exit(status); }
_Noreturn void __wrap__exit(int status) { phone_capture_exit(status); }
_Noreturn void __wrap__Exit(int status) { phone_capture_exit(status); }
_Noreturn void __wrap_quick_exit(int status) { phone_capture_exit(status); }

QEMU_HMOS_EXPORT int qemu_hmos_phone_run(int argc, char **argv)
{
    jmp_buf exit_target;
    int result;
    if (pthread_mutex_trylock(&phone_session_mutex) != 0) {
        return 126;
    }
    if (phone_session_consumed || phone_exit_target) {
        pthread_mutex_unlock(&phone_session_mutex);
        return 125;
    }
    phone_session_consumed = true;
    /* The DSO loader thread need not be the thread running this session. */
    rcu_register_thread();
    phone_exit_target = &exit_target;
    if (setjmp(exit_target) == 0) {
        qemu_init(argc, argv);
        result = qemu_main_loop();
        qemu_cleanup(result);
        /* Backends may have queued deferred frees during shutdown. */
        drain_call_rcu();
        bql_unlock();
        replay_mutex_unlock();
    } else {
        /* qemu_init has many partially initialized error paths. Do not run
         * the successful-init cleanup on a partially constructed machine.
         */
        result = phone_exit_status == 0 ? 124 : phone_exit_status;
    }
    phone_exit_target = NULL;
    rcu_unregister_thread();
    pthread_mutex_unlock(&phone_session_mutex);
    return result;
}
