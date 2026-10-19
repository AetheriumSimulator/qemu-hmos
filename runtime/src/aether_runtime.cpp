// SPDX-License-Identifier: GPL-2.0-or-later
#include "aether_runtime.h"
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <vector>

namespace {
std::mutex mutex;
aether_runtime_state state = AETHER_UNLOADED;
void *core = nullptr; // Intentionally pinned: teardown/restart is not validated.
using Run = int (*)(int, char **);
Run runCore = nullptr;
std::string loadedPath;
// QEMU may retain pointers during shutdown; keep storage for process lifetime.
std::vector<std::vector<char>> arguments;
std::vector<char *> pointers;
thread_local const char *diagnostic = "";
int fail(int code, const char *message) { diagnostic = message; return code; }
}
extern "C" uint32_t aether_runtime_abi(void) { return AETHER_RUNTIME_ABI; }
extern "C" const char *aether_runtime_last_error(void) { return diagnostic; }
extern "C" aether_runtime_state aether_runtime_get_state(void)
{
    std::lock_guard<std::mutex> lock(mutex);
    return state;
}
extern "C" int aether_runtime_load(uint32_t abi, const char *path)
{
    diagnostic = "";
    if (abi != AETHER_RUNTIME_ABI) return fail(AETHER_ABI_MISMATCH, "runtime ABI mismatch");
    if (!path || path[0] != '/') return fail(AETHER_INVALID_ARGUMENT, "absolute core path required");
    std::lock_guard<std::mutex> lock(mutex);
    if (state == AETHER_RUNNING) return fail(AETHER_BUSY, "session running");
    if (core) return loadedPath == path ? AETHER_OK : fail(AETHER_INVALID_ARGUMENT, "core already pinned");
    try {
        loadedPath = path;
        void *candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!candidate) return fail(AETHER_CORE_MISSING, "cannot load core or a dependency; inspect loader logs");
        const auto *marker = static_cast<const char *>(dlsym(candidate, "qemu_hmos_phone_marker"));
        auto entry = reinterpret_cast<Run>(dlsym(candidate, "qemu_hmos_phone_run"));
        // Fail closed on a changed contract; a new core requires an adapter review.
        if (!marker || std::strcmp(marker,
            "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0") != 0 || !entry) {
            dlclose(candidate);
            return fail(AETHER_ABI_MISMATCH, "phone-core ABI/marker mismatch; fullcore is not supported");
        }
        core = candidate;
        runCore = entry;
        state = AETHER_READY;
        return AETHER_OK;
    } catch (...) { return fail(AETHER_INTERNAL_ERROR, "core configuration allocation failed"); }
}
extern "C" int aether_runtime_run(int argc, const char *const *argv, int *exitCode)
{
    diagnostic = "";
    if (argc < 1 || !argv || !exitCode) return fail(AETHER_INVALID_ARGUMENT, "argc/argv/result required");
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (state == AETHER_UNLOADED) return fail(AETHER_NOT_LOADED, "load core first");
        if (state == AETHER_RUNNING) return fail(AETHER_BUSY, "session running");
        if (state == AETHER_CONSUMED) return fail(AETHER_SESSION_CONSUMED, "new host process required");
        try {
            arguments.clear(); pointers.clear(); arguments.reserve(argc); pointers.reserve(argc + 1);
            for (int i = 0; i < argc; ++i) {
                if (!argv[i]) return fail(AETHER_INVALID_ARGUMENT, "null argv entry");
                arguments.emplace_back(argv[i], argv[i] + std::strlen(argv[i]) + 1);
            }
            for (auto &argument : arguments) pointers.push_back(argument.data());
            pointers.push_back(nullptr);
        } catch (...) { return fail(AETHER_INTERNAL_ERROR, "argument allocation failed"); }
        state = AETHER_RUNNING;
    }
    // The core owns init/loop/cleanup. Never call legacy qemu_main or install
    // process-wide exit/signal interception here. Native fatal errors remain fatal.
    int code;
    try { code = runCore(argc, pointers.data()); }
    catch (...) {
        std::lock_guard<std::mutex> lock(mutex);
        state = AETHER_CONSUMED;
        return fail(AETHER_INTERNAL_ERROR, "core threw across C ABI");
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        state = AETHER_CONSUMED;
    }
    *exitCode = code;
    return AETHER_OK;
}
