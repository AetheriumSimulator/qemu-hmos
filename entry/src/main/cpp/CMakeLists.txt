cmake_minimum_required(VERSION 3.5)
project(qemu_hmos)

# 设置C++标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 鸿蒙开发环境特定配置
if(DEFINED ENV{OHOS_NDK_HOME})
    set(OHOS_NDK_HOME $ENV{OHOS_NDK_HOME})
else()
    # 尝试自动检测NDK路径
    if(EXISTS "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native")
        set(OHOS_NDK_HOME "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native")
    elseif(EXISTS "/Applications/DevEco-Studio.app/Contents/ohos/ndk")
        set(OHOS_NDK_HOME "/Applications/DevEco-Studio.app/Contents/ohos/ndk")
    else()
        message(FATAL_ERROR "OHOS_NDK_HOME not set and could not be auto-detected")
    endif()
endif()

# 设置工具链
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# 设置编译器路径
set(CMAKE_C_COMPILER "${OHOS_NDK_HOME}/llvm/bin/clang")
set(CMAKE_CXX_COMPILER "${OHOS_NDK_HOME}/llvm/bin/clang++")

# 设置查找路径
set(CMAKE_FIND_ROOT_PATH "${OHOS_NDK_HOME}/sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# 包含目录
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${OHOS_NDK_HOME}/sysroot/usr/include"
    "${OHOS_NDK_HOME}/sysroot/usr/include/aarch64-linux-ohos"
)

# 库目录
link_directories(
    "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos"
    "${OHOS_NDK_HOME}/sysroot/usr/lib"
)

# 源文件
set(SOURCES
    napi_init.cpp
)

# 创建共享库
add_library(qemu_hmos SHARED ${SOURCES})

# 查找并链接必要的库
find_library(LOG_LIB hilog_ndk
    PATHS
    "${OHOS_NDK_HOME}/sysroot/usr/lib"
    "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos"
    NO_DEFAULT_PATH
)

# 在鸿蒙环境中，android库可能不存在，我们跳过它
set(ANDROID_LIB "")

# 如果找不到日志库，使用空值避免链接错误
if(NOT LOG_LIB)
    message(WARNING "LOG library not found, skipping...")
    set(LOG_LIB "")
endif()

message(STATUS "LOG_LIB: ${LOG_LIB}")
message(STATUS "ANDROID_LIB: ${ANDROID_LIB}")

# 查找鸿蒙NAPI库
set(NAPI_LIB_PATH "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos/libace_napi.z.so")

if(EXISTS ${NAPI_LIB_PATH})
    set(NAPI_LIB ${NAPI_LIB_PATH})
    message(STATUS "Found NAPI library: ${NAPI_LIB}")
else()
    message(FATAL_ERROR "NAPI library not found at: ${NAPI_LIB_PATH}")
endif()

# 查找QEMU相关库
# 1. QEMU核心库
set(QEMU_CORE_LIB "${CMAKE_CURRENT_SOURCE_DIR}/libqemu_hmos.so")
if(EXISTS ${QEMU_CORE_LIB})
    message(STATUS "Found QEMU core library: ${QEMU_CORE_LIB}")
else()
    message(WARNING "QEMU core library not found, will build without QEMU core support")
    set(QEMU_CORE_LIB "")
endif()

# 2. VNC库 (libvncserver)
set(VNC_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libvncserver/libvncserver.a")
if(EXISTS ${VNC_LIB_PATH})
    message(STATUS "Found VNC library: ${VNC_LIB_PATH}")
else()
    message(WARNING "VNC library not found, VNC support will be limited")
    set(VNC_LIB_PATH "")
endif()

# 3. FreeRDP库
set(FREERDP_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/third_party/freerdp/libfreerdp.a")
if(EXISTS ${FREERDP_LIB_PATH})
    message(STATUS "Found FreeRDP library: ${FREERDP_LIB_PATH}")
else()
    message(WARNING "FreeRDP library not found, RDP support will be limited")
    set(FREERDP_LIB_PATH "")
endif()

# 链接库
target_link_libraries(qemu_hmos 
    ${NAPI_LIB}
)

# 只有在找到库的情况下才链接
if(LOG_LIB)
    target_link_libraries(qemu_hmos ${LOG_LIB})
endif()

if(ANDROID_LIB)
    target_link_libraries(qemu_hmos ${ANDROID_LIB})
endif()

# 链接QEMU相关库
if(QEMU_CORE_LIB)
    target_link_libraries(qemu_hmos ${QEMU_CORE_LIB})
endif()

if(VNC_LIB_PATH)
    target_link_libraries(qemu_hmos ${VNC_LIB_PATH})
    # VNC依赖库
    target_link_libraries(qemu_hmos 
        -lpthread
        -lz
        -ljpeg
        -lpng
    )
endif()

if(FREERDP_LIB_PATH)
    target_link_libraries(qemu_hmos ${FREERDP_LIB_PATH})
    # FreeRDP依赖库
    target_link_libraries(qemu_hmos 
        -lpthread
        -lssl
        -lcrypto
        -lwinpr
        -lfreerdp
    )
endif()

# 设置编译选项
target_compile_options(qemu_hmos PRIVATE
    -fPIC
    -Wall
    -Wextra
    -O2
    -D__MUSL__
    -D__OHOS__
    --target=aarch64-linux-ohos
    -fdata-sections
    -ffunction-sections
    -funwind-tables
    -fstack-protector-strong
    -no-canonical-prefixes
    -fno-addrsig
    -Wa,--noexecstack
    -Wformat
    -Werror=format-security
    -fuse-ld=lld
    -Wl,--build-id=sha1
    -Wl,--warn-shared-textrel
    -Wl,--fatal-warnings
    -lunwind
    -Wl,--no-undefined
    -Qunused-arguments
    -Wl,-z,noexecstack
)

# 设置输出名称和路径
set_target_properties(qemu_hmos PROPERTIES
    OUTPUT_NAME "qemu_hmos"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    PREFIX ""
)

# 添加自定义目标用于调试
add_custom_target(debug_info
    COMMAND ${CMAKE_COMMAND} -E echo "OHOS_NDK_HOME: ${OHOS_NDK_HOME}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_C_COMPILER: ${CMAKE_C_COMPILER}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_FIND_ROOT_PATH: ${CMAKE_FIND_ROOT_PATH}"
    COMMAND ${CMAKE_COMMAND} -E echo "NAPI_LIB: ${NAPI_LIB}"
)
