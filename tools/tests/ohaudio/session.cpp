// Host-only test of the same generation guard used by the NAPI entrypoints.
#include "microphone_session.h"
#include <cassert>
#include <cstring>
#include <thread>

static bool enabled;
static bool allowed = true;
static int status;
static int setEnabled(bool value)
{
    enabled = value && allowed;
    status = enabled ? 1 : value ? 3 : 0;
    return !value || enabled;
}
static int getStatus() { return status; }

int main()
{
    MicrophoneSession mic;
    assert(!mic.Available());
    assert(mic.Session("vm") == 0);
    assert(!mic.Enable("vm", 0, true));
    mic.Bind(setEnabled, getStatus);
    assert(mic.Available());
    auto first = mic.Begin("vm");
    assert(first && !enabled && !mic.Session("vm"));
    assert(!mic.Enable("vm", first, true));
    mic.Running(first);
    assert(mic.Session("vm") == first);
    assert(!mic.Enable("other", first, true));
    assert(!std::strcmp(mic.Status("vm"), "disabled"));
    allowed = false;
    assert(!mic.Enable("vm", first, true));
    assert(!std::strcmp(mic.Status("vm"), "blocked"));
    allowed = true;
    assert(mic.Enable("vm", first, true) && enabled);
    assert(!std::strcmp(mic.Status("vm"), "armed"));
    status = 2; assert(!std::strcmp(mic.Status("vm"), "capturing"));
    status = 4; assert(!std::strcmp(mic.Status("vm"), "error"));
    mic.Stop("other"); assert(enabled);
    mic.Stop("vm"); assert(!enabled && !mic.Session("vm"));
    assert(!mic.Enable("vm", first, true));
    assert(!std::strcmp(mic.Status("vm"), "unavailable"));

    auto second = mic.Begin("vm");
    assert(second != first);
    mic.Running(second); assert(mic.Enable("vm", second, true));
    // Delayed allow, disable, startup completion and exit from old generation.
    assert(!mic.Enable("vm", first, true));
    assert(!mic.Enable("vm", first, false));
    mic.Running(first); mic.End(first);
    assert(enabled && mic.Session("vm") == second);
    std::thread stale([&]() { for(int i=0;i<1000;i++) mic.End(first); });
    for(int i=0;i<1000;i++) assert(mic.Enable("vm", second, true));
    stale.join();assert(enabled);
    mic.End(second); assert(!enabled && !mic.Session("vm"));

    auto third = mic.Begin("vm");
    mic.Stop("vm"); // User cancels while qemu_init is still in progress.
    mic.Running(third);
    assert(!mic.Session("vm") && !mic.Enable("vm", third, true));
    auto fourth = mic.Begin("vm"); mic.Running(fourth);
    assert(mic.Enable("vm", fourth, true));
    status = 99; assert(!std::strcmp(mic.Status("vm"), "unavailable") && !enabled);
    assert(mic.Enable("vm", fourth, true));
    mic.Bind(nullptr, nullptr); assert(!enabled && !mic.Available());
    assert(!mic.Enable("vm", fourth, true));
    assert(!std::strcmp(mic.Status("vm"), "unavailable"));
    mic.Bind(setEnabled, nullptr);
    assert(!mic.Available());
    assert(!mic.Enable("vm", fourth, true));
}
