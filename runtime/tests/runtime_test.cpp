// SPDX-License-Identifier: GPL-2.0-or-later
#include "aether_runtime.h"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
namespace {
std::atomic<int> constructed{0}, destructed{0}, invoked{0};
}
extern "C" void aether_mock_lifecycle_event(int event) {
    if (event == 1) ++constructed;
    else if (event == 2) ++destructed;
    else if (event == 3) ++invoked;
}
#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x << '\n'; std::exit(1); } } while (0)
int main(int argc, char **argv) {
    CHECK(argc == 8);
    const char *args[] = {"qemu", "x"};
    int code = -99;
    if (!std::strcmp(argv[1], "arguments")) {
        CHECK(aether_runtime_run(2, args, &code) == AETHER_NOT_LOADED);
        CHECK(aether_runtime_load(99, argv[2]) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_load(1, "relative.so") == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_load(1, "/nonexistent/aether-core.so") == AETHER_CORE_MISSING);
        CHECK(aether_runtime_get_state() == AETHER_UNLOADED);
        CHECK(constructed == 0);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_OK);
        const char *bad[] = {"qemu", nullptr};
        CHECK(aether_runtime_run(2, bad, &code) == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_run(2, args, nullptr) == AETHER_INVALID_ARGUMENT);
        CHECK(aether_runtime_get_state() == AETHER_READY);
    } else if (!std::strcmp(argv[1], "missing") || !std::strcmp(argv[1], "wrong") ||
               !std::strcmp(argv[1], "mttcg") || !std::strcmp(argv[1], "no_marker")) {
        CHECK(aether_runtime_load(1, "/nonexistent/aether-core.so") == AETHER_CORE_MISSING);
        CHECK(aether_runtime_get_state() == AETHER_UNLOADED);
        const char *rejected = argv[!std::strcmp(argv[1], "wrong") ? 3 :
                                    !std::strcmp(argv[1], "missing") ? 4 :
                                    !std::strcmp(argv[1], "mttcg") ? 5 : 6];
        CHECK(aether_runtime_load(1, rejected) == AETHER_ABI_MISMATCH);
        CHECK(constructed == 1);
        CHECK(destructed == 0);
        CHECK(invoked == 0);
        CHECK(aether_runtime_get_state() == AETHER_REJECTED);
        CHECK(aether_runtime_load(1, rejected) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_load(1, argv[2]) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_load(1, "/nonexistent/aether-core.so") == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_load(1, nullptr) == AETHER_ABI_MISMATCH);
        CHECK(aether_runtime_run(2, args, &code) == AETHER_ABI_MISMATCH);
        CHECK(code == -99);
        CHECK(aether_runtime_run(0, nullptr, nullptr) == AETHER_ABI_MISMATCH);
        CHECK(std::strlen(aether_runtime_last_error()) > 0);
        CHECK(aether_runtime_get_state() == AETHER_REJECTED);
        CHECK(constructed == 1);
        CHECK(destructed == 0);
        CHECK(invoked == 0);
    } else if (!std::strcmp(argv[1], "throwing")) {
        CHECK(aether_runtime_load(1, argv[7]) == AETHER_OK);
        CHECK(aether_runtime_run(2, args, &code) == AETHER_INTERNAL_ERROR);
        CHECK(code == -99);
        CHECK(aether_runtime_get_state() == AETHER_CONSUMED);
        CHECK(aether_runtime_load(1, argv[7]) == AETHER_OK);
        CHECK(aether_runtime_get_state() == AETHER_CONSUMED);
        CHECK(aether_runtime_run(2, args, &code) == AETHER_SESSION_CONSUMED);
        CHECK(invoked == 1);
        CHECK(destructed == 0);
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
    CHECK(constructed == 1);
    CHECK(destructed == 0);
}
