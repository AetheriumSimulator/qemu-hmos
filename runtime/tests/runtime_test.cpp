// SPDX-License-Identifier: GPL-2.0-or-later
#include "aether_runtime.h"
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x << '\n'; std::exit(1); } } while (0)
int main(int argc, char **argv) {
    CHECK(argc == 5);
    const char *args[] = {"qemu", "x"};
    int code = -99;
    if (!std::strcmp(argv[1], "arguments")) {
        CHECK(aether_runtime_run(2, args, &code) == AETHER_NOT_LOADED);
        CHECK(aether_runtime_load(99, argv[2]) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_load(1, "relative.so") == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
        const char *bad[] = {"qemu", nullptr};
        CHECK(aether_runtime_run(2, bad, &code) == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_run(2, args, nullptr) == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_get_state() == AETHER_READY);
    } else if (!std::strcmp(argv[1], "missing") || !std::strcmp(argv[1], "wrong")) {
        CHECK(aether_runtime_load(1, "/nonexistent/aether-core.so") == AETHER_CORE_MISSING);
        CHECK(aether_runtime_load(1, argv[!std::strcmp(argv[1], "wrong") ? 3 : 4]) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_get_state() == AETHER_UNLOADED);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
    } else {
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
        CHECK(aether_runtime_load(1, argv[3]) == AETHER_INVALID_ARGUMENT);
        if (!std::strcmp(argv[1], "concurrent")) {
            int workerStatus = -99;
            std::thread worker([&] { workerStatus = aether_runtime_run(2, args, &code); });
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (aether_runtime_get_state() != AETHER_RUNNING && std::chrono::steady_clock::now() < deadline)
                std::this_thread::yield();
            int otherCode = -99;
            CHECK(aether_runtime_get_state() == AETHER_RUNNING);
            CHECK(aether_runtime_run(2, args, &otherCode) == AETHER_BUSY);
            CHECK(aether_runtime_load(1, argv[2]) == AETHER_BUSY);
            CHECK(otherCode == -99);
            worker.join();
            CHECK(workerStatus == AETHER_OK);
        } else CHECK(aether_runtime_run(2, args, &code) == AETHER_OK);
        CHECK(code == 17);
        CHECK(args[1][0] == 'x');
        CHECK(aether_runtime_get_state() == AETHER_CONSUMED);
        CHECK(aether_runtime_run(2, args, &code) == AETHER_SESSION_CONSUMED);
        CHECK(std::strlen(aether_runtime_last_error()) > 0);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
        CHECK(aether_runtime_get_state() == AETHER_CONSUMED);
    }
}
