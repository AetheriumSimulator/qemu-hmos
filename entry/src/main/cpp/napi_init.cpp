#include "napi/native_api.h"
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

#if defined(__has_include)
#  if __has_include(<sys/prctl.h>)
#    include <sys/prctl.h>
#    define HAS_PRCTL 1
#  else
#    define HAS_PRCTL 0
#  endif
#else
#  define HAS_PRCTL 0
#endif

#ifndef PRCTL_JIT_ENABLE
#define PRCTL_JIT_ENABLE 0x6a6974 // magic from requirements, best-effort attempt
#endif

extern "C" int qemu_main(int argc, char **argv);
extern "C" void qemu_system_shutdown_request(int reason);
static constexpr int SHUTDOWN_CAUSE_HOST = 0;

static std::thread g_qemuThread;
static std::atomic<bool> g_qemuRunning{false};

static bool kvmSupported()
{
    int fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        return false;
    }
    close(fd);
    return true;
}

static bool enableJit()
{
#if HAS_PRCTL
    int r = prctl(PRCTL_JIT_ENABLE, 1);
    return r == 0;
#else
    errno = ENOSYS;
    return false;
#endif
}

static std::vector<std::string> ParseArgs(napi_env env, napi_value config, bool &ok)
{
    napi_value argsArray;
    ok = (napi_get_named_property(env, config, "args", &argsArray) == napi_ok);
    if (!ok) {
        return {};
    }
    bool isArray = false;
    napi_is_array(env, argsArray, &isArray);
    if (!isArray) {
        ok = false;
        return {};
    }
    uint32_t len = 0;
    napi_get_array_length(env, argsArray, &len);
    std::vector<std::string> out;
    for (uint32_t i = 0; i < len; ++i) {
        napi_value elem;
        napi_get_element(env, argsArray, i, &elem);
        size_t strLen = 0;
        napi_get_value_string_utf8(env, elem, nullptr, 0, &strLen);
        std::string s(strLen, '\0');
        napi_get_value_string_utf8(env, elem, s.data(), s.size() + 1, &strLen);
        s.resize(strLen);
        out.push_back(std::move(s));
    }
    return out;
}

static napi_value GetVersion(napi_env env, napi_callback_info info)
{
    const char* ver = "qemu_hmos_stub_0.1";
    napi_value ret;
    napi_create_string_utf8(env, ver, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

static napi_value EnableJit(napi_env env, napi_callback_info info)
{
    (void)info; // unused
    if (!enableJit()) {
        int err = errno;
        std::string code = std::to_string(err);
        napi_throw_error(env, code.c_str(), strerror(err));
        return nullptr;
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

static napi_value KvmSupported(napi_env env, napi_callback_info info)
{
    (void)info; // unused
    if (!kvmSupported()) {
        int err = errno;
        std::string code = std::to_string(err);
        napi_throw_error(env, code.c_str(), strerror(err));
        return nullptr;
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

// --- QEMU 集成占位：start/stop ---
static napi_value StartVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value result;

    if (argc < 1 || g_qemuRunning.load()) {
        napi_get_boolean(env, false, &result);
        return result;
    }

    bool ok = false;
    std::vector<std::string> args = ParseArgs(env, argv[0], ok);
    if (!ok || args.empty()) {
        napi_get_boolean(env, false, &result);
        return result;
    }

    bool useKvm = false;
    bool jitOk = false;
    bool useTci = false;
    bool pending = false;
    napi_value tmp;

    tmp = KvmSupported(env, nullptr);
    napi_is_exception_pending(env, &pending);
    if (!pending && tmp != nullptr) {
        useKvm = true;
    } else if (pending) {
        napi_value exc;
        napi_get_and_clear_last_exception(env, &exc);
    }

    tmp = EnableJit(env, nullptr);
    napi_is_exception_pending(env, &pending);
    if (!pending && tmp != nullptr) {
        jitOk = true;
    } else if (pending) {
        napi_value exc;
        napi_get_and_clear_last_exception(env, &exc);
        useTci = true;
    }

    if (useKvm) {
        args.push_back("-accel");
        args.push_back("kvm");
    } else if (jitOk) {
        args.push_back("-accel");
        args.push_back("tcg,thread=multi");
    } else if (useTci) {
        args.push_back("-accel");
        args.push_back("tcg");
    }

    g_qemuRunning = true;
    g_qemuThread = std::thread([args]() {
        std::vector<char*> cargs;
        for (const auto &s : args) {
            cargs.push_back(const_cast<char*>(s.c_str()));
        }
        qemu_main(static_cast<int>(cargs.size()), cargs.data());
        g_qemuRunning = false;
    });

    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value StopVm(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_qemuRunning.load()) {
        qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST);
        if (g_qemuThread.joinable()) {
            g_qemuThread.join();
        }
        g_qemuRunning = false;
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "version", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "enableJit", nullptr, EnableJit, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "kvmSupported", nullptr, KvmSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startVm", nullptr, StartVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopVm", nullptr, StopVm, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module qemuModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "qemu_hmos",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterQemuModule(void)
{
    napi_module_register(&qemuModule);
}
