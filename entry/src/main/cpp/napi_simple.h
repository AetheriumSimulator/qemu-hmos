#ifndef NAPI_SIMPLE_H
#define NAPI_SIMPLE_H

#include <cstddef>
#include <cstdint>

// NAPI类型定义
typedef struct napi_env__* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_callback_info__* napi_callback_info;
typedef struct napi_property_descriptor__* napi_property_descriptor;
typedef struct napi_module__* napi_module;

// NAPI状态码
typedef int napi_status;
#define napi_ok 0

// NAPI回调函数类型
typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);

// NAPI属性描述符结构
struct napi_property_descriptor__ {
    const char* utf8name;
    napi_callback method;
    int attributes;
};

// NAPI模块结构
struct napi_module__ {
    int nm_version;
    unsigned int nm_flags;
    const char* nm_filename;
    void (*nm_register_func)(napi_env env, napi_value exports);
    const char* nm_modname;
    void* nm_priv;
    size_t reserved[4];
};

// 简化的模块结构（用于我们的实现）
struct napi_module_simple {
    int nm_version;
    unsigned int nm_flags;
    const char* nm_filename;
    void (*nm_register_func)(napi_env env, napi_value exports);
    const char* nm_modname;
    void* nm_priv;
    size_t reserved[4];
};

// NAPI函数声明
extern "C" {
    napi_status napi_get_cb_info(napi_env env, napi_callback_info cbinfo,
                                size_t* argc, napi_value* argv,
                                napi_value* this_arg, void** data);
    
    napi_status napi_get_named_property(napi_env env, napi_value object,
                                       const char* utf8name, napi_value* result);
    
    napi_status napi_set_named_property(napi_env env, napi_value object,
                                       const char* utf8name, napi_value value);
    
    napi_status napi_get_value_string_utf8(napi_env env, napi_value value,
                                          char* buf, size_t bufsize, size_t* result);
    
    napi_status napi_get_value_int32(napi_env env, napi_value value, int32_t* result);
    
    napi_status napi_get_value_bool(napi_env env, napi_value value, bool* result);
    
    napi_status napi_create_string_utf8(napi_env env, const char* str,
                                       size_t length, napi_value* result);
    
    napi_status napi_create_object(napi_env env, napi_value* result);
    
    napi_status napi_create_int32(napi_env env, int32_t value, napi_value* result);
    
    napi_status napi_get_boolean(napi_env env, bool value, napi_value* result);
    
    napi_status napi_define_properties(napi_env env, napi_value object,
                                      size_t property_count,
                                      const napi_property_descriptor* properties);
    
    napi_status napi_throw_error(napi_env env, const char* code, const char* msg);
    
    napi_status napi_create_array(napi_env env, napi_value* result);
    
    napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value);
    
    void napi_module_register(napi_module_simple* mod);
}

// 宏定义
#define NAPI_AUTO_LENGTH SIZE_MAX

#endif // NAPI_SIMPLE_H