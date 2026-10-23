/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef AETHER_RUNTIME_H
#define AETHER_RUNTIME_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define AETHER_RUNTIME_ABI 1u
typedef enum {
    AETHER_OK = 0,
    AETHER_INVALID_ARGUMENT = -1,
    AETHER_CORE_MISSING = -2,
    AETHER_ABI_MISMATCH = -3,
    AETHER_NOT_LOADED = -4,
    AETHER_SESSION_CONSUMED = -5,
    AETHER_BUSY = -6,
    AETHER_INTERNAL_ERROR = -7
} aether_runtime_result;
typedef enum {
    AETHER_UNLOADED = 0, AETHER_READY = 1,
    AETHER_RUNNING = 2, AETHER_CONSUMED = 3,
    AETHER_REJECTED = 4
} aether_runtime_state;
uint32_t aether_runtime_abi(void);
/* Explicit absolute path to trusted, build-matched libqemu_phone.so only.
 * No download, path guessing, fullcore fallback, or unloading. Idempotent only
 * for the same accepted path string. A successfully opened but incompatible DSO
 * stays pinned in REJECTED: subsequent load/run calls return ABI_MISMATCH and
 * require a new process. A dlopen failure leaves UNLOADED and permits retry.
 * Serialize configuration before launching a worker. */
int aether_runtime_load(uint32_t requested_abi, const char *core_path);
/* Blocking: call on a dedicated native worker, NEVER the ArkUI thread.
 * Copies argv; argv[0] is required. AETHER_OK means the core RETURNED, not booted.
 * The QEMU exit status is separate. Exactly one invocation per process, including
 * failed initialization. No C++ objects, N-API values or UI data cross this ABI. */
int aether_runtime_run(int argc, const char *const *argv, int *core_exit_code);
aether_runtime_state aether_runtime_get_state(void);
/* Thread-local diagnostic, valid until the next load/run on this thread.
 * Copy on the worker before handing a result to N-API. */
const char *aether_runtime_last_error(void);
#ifdef __cplusplus
}
#endif
#endif
