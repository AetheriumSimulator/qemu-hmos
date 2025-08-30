#ifndef NAPI_SIMPLE_H
#define NAPI_SIMPLE_H

#include <stdint.h>
#include <stddef.h>

// 简化的NAPI类型定义
typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_callback_info__ *napi_callback_info;

typedef enum {
    napi_ok,
    napi_invalid_arg,
    napi_object_expected,
    napi_string_expected,
    napi_function_expected,
    napi_number_expected,
    napi_boolean_expected,
    napi_array_expected,
    napi_generic_failure,
    napi_pending_exception,
    napi_cancelled,
    napi_escape_called_twice,
    napi_handle_scope_mismatch,
    napi_callback_scope_mismatch,
    napi_queue_full,
    napi_closing,
    napi_bigint_expected,
    napi_date_expected,
    napi_arraybuffer_expected,
    napi_detachable_arraybuffer_expected,
    napi_would_deadlock
} napi_status;

typedef enum {
    napi_default = 0,
    napi_writable = 1 << 0,
    napi_enumerable = 1 << 1,
    napi_configurable = 1 << 2,
    napi_static = 1 << 10,
    napi_default_method = napi_writable | napi_configurable,
    napi_default_jsproperty = napi_writable | napi_enumerable | napi_configurable
} napi_property_attributes;

typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);

typedef struct {
    const char* utf8name;
    napi_value name;
    napi_callback method;
    napi_callback getter;
    napi_callback setter;
    napi_value value;
    napi_property_attributes attributes;
    void* data;
} napi_property_descriptor;

typedef struct napi_module {
    int nm_version;
    unsigned int nm_flags;
    const char* nm_filename;
    napi_value (*nm_register_func)(napi_env env, napi_value exports);
    const char* nm_modname;
    void* nm_priv;
    void* reserved[4];
} napi_module;

// 简化的NAPI函数声明
#ifdef __cplusplus
extern "C" {
#endif

napi_status napi_get_cb_info(napi_env env, napi_callback_info cbinfo,
                            size_t* argc, napi_value* argv,
                            napi_value* this_arg, void** data);

napi_status napi_get_named_property(napi_env env, napi_value object,
                                   const char* utf8name, napi_value* result);

napi_status napi_get_value_string_utf8(napi_env env, napi_value value,
                                      char* buf, size_t bufsize, size_t* result);

napi_status napi_get_value_int32(napi_env env, napi_value value, int32_t* result);

napi_status napi_create_string_utf8(napi_env env, const char* str,
                                   size_t length, napi_value* result);

napi_status napi_get_boolean(napi_env env, bool value, napi_value* result);

napi_status napi_define_properties(napi_env env, napi_value object,
                                  size_t property_count,
                                  const napi_property_descriptor* properties);

void napi_module_register(napi_module* mod);

#ifdef __cplusplus
}
#endif

#ifndef EXTERN_C_START
#ifdef __cplusplus
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }
#else
#define EXTERN_C_START
#define EXTERN_C_END
#endif
#endif

#endif // NAPI_SIMPLE_H