#include "napi/native_api.h"
#include <string>
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
    int err = 0;
    bool success = false;
#if HAS_PRCTL
    int r = prctl(PRCTL_JIT_ENABLE, 1);
    success = (r == 0);
    if (!success) {
        err = errno;
    }
#else
    err = ENOSYS;
#endif
    if (!success) {
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
    int fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        int err = errno;
        std::string code = std::to_string(err);
        napi_throw_error(env, code.c_str(), strerror(err));
        return nullptr;
    }
    close(fd);
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

// --- QEMU 集成占位：start/stop ---
static napi_value StartVm(napi_env env, napi_callback_info info)
{
    // 这里仅做占位，返回 true，后续替换为真正的启动逻辑
    (void)info;
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

static napi_value StopVm(napi_env env, napi_callback_info info)
{
    // 这里仅做占位，返回 true
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
