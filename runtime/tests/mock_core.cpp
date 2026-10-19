// SPDX-License-Identifier: GPL-2.0-or-later
#include <chrono>
#include <thread>
extern "C" {
#if MOCK_good
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0";
#elif MOCK_wrong
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=2;backend=tci;signals=host;reentrant=1";
#else
extern const char qemu_hmos_phone_marker[] = "aether_phone_core_abi=1;backend=tci;signals=host;reentrant=0";
#endif
#if !MOCK_missing
int qemu_hmos_phone_run(int argc, char **argv) {
    if (argc != 2 || !argv || argv[argc] || argv[1][0] != 'x') return 91;
    argv[1][0] = 'y'; // Must be a mutable copy, not the caller's literal.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    return 17; // Propagate nonzero QEMU result independently of bridge status.
}
#endif
}
