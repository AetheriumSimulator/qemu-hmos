// SPDX-License-Identifier: GPL-2.0-or-later
#include <chrono>
#include <stdexcept>
#include <thread>
extern "C" {
// Observe DSO lifetime from the executable without acquiring an extra loader
// reference, which would otherwise conceal an unintended unload.
void aether_mock_lifecycle_event(int event);
__attribute__((constructor)) static void loaded() { aether_mock_lifecycle_event(1); }
__attribute__((destructor)) static void unloaded() { aether_mock_lifecycle_event(2); }
#if !MOCK_no_marker
#if MOCK_good
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0";
#elif MOCK_wrong
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=2;backend=tci;signals=host;reentrant=1";
#elif MOCK_mttcg
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=1;backend=tcg;thread=multi;signals=host;reentrant=0";
#else
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0";
#endif
#endif
#if !MOCK_missing
int qemu_hmos_phone_run(int argc, char **argv) {
    aether_mock_lifecycle_event(3);
    if (argc != 2 || !argv || argv[argc] || argv[1][0] != 'x') return 91;
    argv[1][0] = 'y'; // Must be a mutable copy, not the caller's literal.
#if MOCK_throwing
    throw std::runtime_error("synthetic core exception");
#endif
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    return 17; // Propagate nonzero QEMU result independently of bridge status.
}
#endif
}
