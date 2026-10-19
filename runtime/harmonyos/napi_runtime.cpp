// SPDX-License-Identifier: GPL-2.0-or-later
// Optional API 20 phone-core bridge. Build with the actual HarmonyOS SDK.
#include "aether_runtime.h"
#include <napi/native_api.h>
#include <napi/native_node_api.h>
#include <memory>
#include <string>
#include <vector>

namespace {
struct Work {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string path;
    std::vector<std::string> args;
    int bridgeCode = AETHER_INTERNAL_ERROR;
    int exitCode = 0;
    std::string error;
};
bool readString(napi_env env, napi_value value, std::string &out)
{
    napi_valuetype type;
    size_t size = 0;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string ||
        napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) return false;
    std::vector<char> bytes(size + 1);
    if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &size) != napi_ok) return false;
    out.assign(bytes.data(), size);
    return out.find('\0') == std::string::npos;
}
void execute(napi_env, void *data)
{
    auto *w = static_cast<Work *>(data);
    try {
        w->bridgeCode = aether_runtime_load(AETHER_RUNTIME_ABI, w->path.c_str());
        if (w->bridgeCode == AETHER_OK) {
            std::vector<const char *> args;
            for (const auto &arg : w->args) args.push_back(arg.c_str());
            w->bridgeCode = aether_runtime_run(static_cast<int>(args.size()), args.data(), &w->exitCode);
        }
        w->error = aether_runtime_last_error();
    } catch (...) { w->bridgeCode = AETHER_INTERNAL_ERROR; }
}
void complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Work> w(static_cast<Work *>(data));
    napi_value result, value;
    napi_create_object(env, &result);
    napi_create_int32(env, status == napi_ok ? w->bridgeCode : AETHER_INTERNAL_ERROR, &value);
    napi_set_named_property(env, result, "bridgeCode", value);
    // No exit status exists when the core was never called.
    if (status == napi_ok && w->bridgeCode == AETHER_OK) napi_create_int32(env, w->exitCode, &value);
    else napi_get_null(env, &value);
    napi_set_named_property(env, result, "coreExitCode", value);
    napi_create_string_utf8(env, w->error.c_str(), w->error.size(), &value);
    napi_set_named_property(env, result, "error", value);
    napi_create_int32(env, aether_runtime_get_state(), &value);
    napi_set_named_property(env, result, "state", value);
    napi_resolve_deferred(env, w->deferred, result);
    napi_delete_async_work(env, w->work);
}
napi_value run(napi_env env, napi_callback_info info)
{
    try {
        size_t count = 2;
        napi_value values[2];
        bool array = false;
        uint32_t length = 0;
        auto w = std::make_unique<Work>();
        if (napi_get_cb_info(env, info, &count, values, nullptr, nullptr) != napi_ok || count != 2 ||
            !readString(env, values[0], w->path) ||
            napi_is_array(env, values[1], &array) != napi_ok || !array ||
            napi_get_array_length(env, values[1], &length) != napi_ok || length == 0 || length > 4096) {
            napi_throw_type_error(env, nullptr, "run requires an absolute core path and nonempty string[] argv");
            return nullptr;
        }
        for (uint32_t i = 0; i < length; ++i) {
            napi_value arg;
            std::string text;
            if (napi_get_element(env, values[1], i, &arg) != napi_ok || !readString(env, arg, text)) {
                napi_throw_type_error(env, nullptr, "argv entries must be strings without NUL");
                return nullptr;
            }
            w->args.push_back(std::move(text));
        }
        napi_value promise, name;
        if (napi_create_string_utf8(env, "AetherRuntimeRun", NAPI_AUTO_LENGTH, &name) != napi_ok ||
            napi_create_promise(env, &w->deferred, &promise) != napi_ok) return nullptr;
        if (napi_create_async_work(env, nullptr, name, execute, complete, w.get(), &w->work) != napi_ok ||
            napi_queue_async_work(env, w->work) != napi_ok) {
            napi_value error;
            napi_create_string_utf8(env, "cannot queue runtime worker", NAPI_AUTO_LENGTH, &error);
            napi_reject_deferred(env, w->deferred, error);
            if (w->work) napi_delete_async_work(env, w->work);
            return promise;
        }
        w.release();
        return promise;
    } catch (...) {
        napi_throw_error(env, nullptr, "runtime argument allocation failed");
        return nullptr;
    }
}
napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor property = {"run", nullptr, run, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property);
    return exports;
}
napi_module module = {1, 0, nullptr, init, "aether_runtime_napi", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterAetherRuntime(void)
{
    napi_module_register(&module);
}
