// NAPI bindings for QEMU wrapper
#include "napi/native_api.h"
#include "qemu_wrapper.h"
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>

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

// Helper to extract VM handle from JS number
static qemu_vm_handle_t GetHandle(napi_env env, napi_value value)
{
    int64_t raw = 0;
    napi_get_value_int64(env, value, &raw);
    return reinterpret_cast<qemu_vm_handle_t>(raw);
}

static napi_value StartVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    // 默认配置，后续可根据 argv[0] 解析
    qemu_vm_config_t cfg{};
    cfg.machine_type = "virt";
    cfg.cpu_type = "cortex-a57";
    cfg.memory_mb = 256;
    cfg.cmdline = "console=ttyAMA0";

    qemu_vm_handle_t handle = qemu_vm_create(&cfg);
    napi_value result;
    if (!handle || qemu_vm_start(handle) != 0) {
        if (handle) {
            qemu_vm_destroy(handle);
        }
        napi_create_int64(env, 0, &result);
        return result;
    }

    return result;
}

static napi_value StopVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }

    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_stop(handle);
    qemu_vm_destroy(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value PauseVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_pause(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value ResumeVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_resume(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value SnapshotVm(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
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
        { "pauseVm", nullptr, PauseVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resumeVm", nullptr, ResumeVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshotVm", nullptr, SnapshotVm, nullptr, nullptr, nullptr, napi_default, nullptr },
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
