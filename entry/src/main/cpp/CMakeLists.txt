cmake_minimum_required(VERSION 3.5)
project(qemu_hmos VERSION 1.0.0)

# 设置C++标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 设置构建类型
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release")
endif()

message(STATUS "Building ${PROJECT_NAME} v${PROJECT_VERSION} in ${CMAKE_BUILD_TYPE} mode")

# 鸿蒙开发环境特定配置
# 允许通过缓存变量或环境变量传入 OpenHarmony NDK 根目录
set(OHOS_NDK_HOME "" CACHE PATH "Path to the OpenHarmony NDK (set for device builds)")
set(_candidate_ndk_paths
    "$ENV{OHOS_NDK_HOME}"
    "$ENV{OHOS_NDK}"
    "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
    "$ENV{USERPROFILE}/AppData/Local/Huawei/DevEcoStudio/sdk/default/openharmony/native"
    "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
    "/mnt/e/HMOS_SDK/linux/native"
    "$ENV{HOME}/OpenHarmony/Sdk/18/native"
    "$ENV{HOME}/OpenHarmony/Sdk/15/native"
    "/opt/openharmony/ndk/18/native"
    "/opt/openharmony/ndk/15/native"
    "/Users/caidingding233/Library/OpenHarmony/Sdk/18/native"
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
    "/Applications/DevEco-Studio.app/Contents/ohos/ndk"
)

if(NOT OHOS_NDK_HOME)
    foreach(_candidate IN LISTS _candidate_ndk_paths)
        if(_candidate AND EXISTS "${_candidate}")
            set(OHOS_NDK_HOME "${_candidate}" CACHE PATH "Path to the OpenHarmony NDK (auto-detected)" FORCE)
            break()
        endif()
    endforeach()
endif()


if(OHOS_NDK_HOME AND EXISTS "${OHOS_NDK_HOME}")
    set(BUILD_FOR_OHOS TRUE)
    message(STATUS "Using OpenHarmony NDK at ${OHOS_NDK_HOME}")

    # 确保使用HarmonyOS NDK的工具链
    if(DEFINED ENV{CC})
        set(CMAKE_C_COMPILER "$ENV{CC}")
    else()
        set(CMAKE_C_COMPILER "${OHOS_NDK_HOME}/llvm/bin/clang")
    endif()

    if(DEFINED ENV{CXX})
        set(CMAKE_CXX_COMPILER "$ENV{CXX}")
    else()
        set(CMAKE_CXX_COMPILER "${OHOS_NDK_HOME}/llvm/bin/clang++")
    endif()

    if(NOT CMAKE_LINKER)
        set(CMAKE_LINKER "${OHOS_NDK_HOME}/llvm/bin/ld.lld")
    endif()

    # 设置交叉编译目标
    set(CMAKE_SYSTEM_NAME Linux)
    set(CMAKE_SYSTEM_PROCESSOR aarch64)

    # 设置sysroot
    set(CMAKE_SYSROOT "${OHOS_NDK_HOME}/sysroot")

    # 确保不使用主机的工具
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

    # 设置编译选项，确保使用正确的 OHOS target
    # 注意：不要手动设置 CMAKE_C_FLAGS 和 CMAKE_CXX_FLAGS，让编译器包装脚本处理 target 和 sysroot

    # 根据构建类型设置优化级别
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O0 -g -DDEBUG")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O0 -g -DDEBUG")
    elseif(CMAKE_BUILD_TYPE STREQUAL "Release")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O2 -DNDEBUG")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -DNDEBUG")
    endif()
else()
    set(BUILD_FOR_OHOS FALSE)
    message(WARNING "OpenHarmony NDK not found. Building host-only shim; set OHOS_NDK_HOME for device binaries.")
endif()


# 确保输出文件扩展名为.so而不是.dylib
# 让工具链按默认规则生成平台后缀（不要强制输出到源码树）

# QEMU库路径
set(QEMU_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/qemu/build")

# 检查实际的QEMU构建目录（可能因构建配置而异）
if(NOT EXISTS "${QEMU_BUILD_DIR}")
    # 尝试其他可能的构建目录
    set(QEMU_BUILD_DIR_CANDIDATES
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/qemu/build_harmonyos_full"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/qemu/build_local_test"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/qemu/build_mac_local"
    )

    foreach(candidate ${QEMU_BUILD_DIR_CANDIDATES})
        if(EXISTS "${candidate}")
            set(QEMU_BUILD_DIR "${candidate}")
            message(STATUS "Found QEMU build directory: ${QEMU_BUILD_DIR}")
            break()
        endif()
    endforeach()
endif()

message(STATUS "Using QEMU build directory: ${QEMU_BUILD_DIR}")
set(QEMU_INCLUDE_DIRS
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/qemu/include"
    "${QEMU_BUILD_DIR}"
)

# 检测操作系统
if(APPLE)
    # macOS 主机上也走 OpenHarmony NDK 交叉编译，不使用 /usr/bin/clang++
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=c99")
    # 包含/库目录
    include_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${QEMU_INCLUDE_DIRS}
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/build-ohos/include"
    )
    link_directories(
        "${QEMU_BUILD_DIR}"
    )
elseif(BUILD_FOR_OHOS)
    # HarmonyOS构建（沿用上面已解析出的 OHOS_NDK_HOME）
    # 设置工具链
    set(CMAKE_SYSTEM_NAME Linux)
    set(CMAKE_SYSTEM_PROCESSOR aarch64)
    
    # 设置编译器路径（使用环境变量或默认路径）
    if(DEFINED ENV{CC})
        set(CMAKE_C_COMPILER "$ENV{CC}")
    else()
        set(CMAKE_C_COMPILER "${OHOS_NDK_HOME}/llvm/bin/clang")
    endif()

    if(DEFINED ENV{CXX})
        set(CMAKE_CXX_COMPILER "$ENV{CXX}")
    else()
        set(CMAKE_CXX_COMPILER "${OHOS_NDK_HOME}/llvm/bin/aarch64-unknown-linux-ohos-clang++")
    endif()
    
    # 设置查找根路径
    set(CMAKE_FIND_ROOT_PATH "${OHOS_NDK_HOME}/sysroot")
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
    
    # 注意：target 和 sysroot 由编译器包装脚本 (aarch64-unknown-linux-ohos-clang++) 处理
    # 
    # 关键修复：清空 CMake 自动检测的 C++ implicit include 目录
    # CMake 会检测编译器并设置 CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES
    # 这会导致错误的 llvm/include/c++/v1 被添加到编译命令，破坏 include 顺序
    # 编译器包装脚本 (aarch64-unknown-linux-ohos-clang++) 已经设置了正确的路径
    # 所以我们清空这个变量，让编译器自己处理
    set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")
    set(CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES "")
    
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -D__MUSL__")

    # 包含目录 - 注意：不要添加 NDK 的 sysroot/include 或 llvm/include/c++/v1
    # 编译器包装脚本已经设置了正确的头文件搜索路径
    include_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${QEMU_INCLUDE_DIRS}
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/build-ohos/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libvncclient/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cjson"
    )
    
    # 添加 OpenSSL 头文件路径（如果存在）
    if(HAVE_OPENSSL)
        include_directories(${OPENSSL_INCLUDE_DIR})
    endif()

    # 库目录
    link_directories(
        "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos"
        "${OHOS_NDK_HOME}/sysroot/usr/lib"
        "${QEMU_BUILD_DIR}"
    )
    
    # 添加第三方依赖库目录（GLib, PCRE2, Pixman, OpenSSL）
    # 这些库通过 tools/build_ohos_deps.sh 编译到 third_party/deps/install-ohos/lib/
    set(DEPS_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/deps/install-ohos")
    if(EXISTS "${DEPS_PREFIX}/lib")
        link_directories("${DEPS_PREFIX}/lib")
        message(STATUS "✅ Added dependencies library directory: ${DEPS_PREFIX}/lib")
    endif()
    
    # 添加 OpenSSL 库目录（如果存在，与上面重复但保持兼容）
    if(HAVE_OPENSSL)
        link_directories("${OPENSSL_PREFIX}/lib")
    endif()
else()
    # 主机侧编译仅验证代码完整性，不依赖 HarmonyOS NDK
    include_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${QEMU_INCLUDE_DIRS}
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/libvnc/build-ohos/include"
    )

    link_directories(
        "${QEMU_BUILD_DIR}"
    )
endif()

# 源文件
set(SOURCES
    napi_init.cpp
    qemu_wrapper.cpp
    third_party/cjson/cJSON.c
    compat_stubs.c
)

# 仅在本机仿真或显式启用时使用简化 NAPI 实现（避免在设备端与系统 NAPI 冲突）
option(USE_FAKE_NAPI "Build with simplified NAPI shim (host only)" OFF)

# 仅允许在主机侧启用简化NAPI；设备端强制关闭以避免ABI冲突
if(USE_FAKE_NAPI AND BUILD_FOR_OHOS)
    message(FATAL_ERROR "USE_FAKE_NAPI is only allowed for host builds. Disable it for device builds.")
endif()

if(NOT BUILD_FOR_OHOS AND NOT USE_FAKE_NAPI)
    message(STATUS "Enabling USE_FAKE_NAPI for host-side build")
    set(USE_FAKE_NAPI ON CACHE BOOL "Build with simplified NAPI shim (host only)" FORCE)
endif()

if(USE_FAKE_NAPI)
    list(APPEND SOURCES napi_impl.cpp)
endif()

# 检查是否使用预编译库模式
# 如果设置了 USE_PREBUILT_LIB，则只检查预编译库是否存在，不进行编译
option(USE_PREBUILT_LIB "Use prebuilt libqemu_hmos.so instead of building it" OFF)

# ======================================================================================
# Hvigor 打包路径说明（重要）：
# - 模块（entry）构建时，Hvigor 会从 entry/build/default/intermediates/... 取 native libs 进行打包；
# - 根工程构建时，也可能从 build/default/intermediates/... 取 native libs（不同任务/插件实现略有差异）。
#
# 为了避免 “src/main/libs 已更新，但 entry/build 仍旧打包旧 so” 的情况，
# 这里在 CMake 阶段同时把关键 so 同步到两套 intermediates 目录。
# ======================================================================================
set(HVIGOR_APP_INTERMEDIATES_LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../build/default/intermediates/libs/default/arm64-v8a")
set(HVIGOR_ENTRY_INTERMEDIATES_LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/default/intermediates/libs/default/arm64-v8a")
set(HVIGOR_ENTRY_STRIPPED_LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/default/intermediates/stripped_native_libs/default/arm64-v8a")

# 预编译库路径：从 entry/src/main/cpp 向上到 entry/src/main，然后进入 libs/arm64-v8a
get_filename_component(PREBUILT_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a" ABSOLUTE)
set(PREBUILT_LIB_PATH "${PREBUILT_LIB_DIR}/libqemu_hmos.so")

if(USE_PREBUILT_LIB)
    # 预编译库模式：只检查库是否存在，并复制到 hvigor 期望的位置
    if(EXISTS ${PREBUILT_LIB_PATH})
        message(STATUS "✅ Using prebuilt library: ${PREBUILT_LIB_PATH}")
        # 创建一个导入库目标，用于依赖管理
        add_library(qemu_hmos SHARED IMPORTED GLOBAL)
        set_target_properties(qemu_hmos PROPERTIES
            IMPORTED_LOCATION ${PREBUILT_LIB_PATH}
        )
        
        # 关键：将预编译库复制到 hvigor 期望的 intermediates 目录（entry/build & build）
        set(PREBUILT_DST_APP_DIR "${HVIGOR_APP_INTERMEDIATES_LIBS_DIR}")
        set(PREBUILT_DST_ENTRY_DIR "${HVIGOR_ENTRY_INTERMEDIATES_LIBS_DIR}")
        set(PREBUILT_DST_APP "${PREBUILT_DST_APP_DIR}/libqemu_hmos.so")
        set(PREBUILT_DST_ENTRY "${PREBUILT_DST_ENTRY_DIR}/libqemu_hmos.so")
        
        # 使用 file(COPY) 在配置阶段复制
        file(MAKE_DIRECTORY ${PREBUILT_DST_APP_DIR})
        file(MAKE_DIRECTORY ${PREBUILT_DST_ENTRY_DIR})
        file(COPY ${PREBUILT_LIB_PATH} DESTINATION ${PREBUILT_DST_APP_DIR})
        file(COPY ${PREBUILT_LIB_PATH} DESTINATION ${PREBUILT_DST_ENTRY_DIR})
        message(STATUS "✅ Copied prebuilt library to: ${PREBUILT_DST_APP}")
        message(STATUS "✅ Copied prebuilt library to: ${PREBUILT_DST_ENTRY}")
        
        # 同时创建一个自定义目标确保每次构建都复制
        add_custom_target(copy_prebuilt_qemu_hmos ALL
            COMMAND ${CMAKE_COMMAND} -E make_directory ${PREBUILT_DST_APP_DIR}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${PREBUILT_DST_ENTRY_DIR}
            COMMAND ${CMAKE_COMMAND} -E copy_if_different ${PREBUILT_LIB_PATH} ${PREBUILT_DST_APP}
            COMMAND ${CMAKE_COMMAND} -E copy_if_different ${PREBUILT_LIB_PATH} ${PREBUILT_DST_ENTRY}
            COMMENT "Copying prebuilt libqemu_hmos.so to intermediates"
        )
        
        message(STATUS "⚠️  Prebuilt library mode: skipping compile, using pre-built binary")
    else()
        message(FATAL_ERROR "❌ Prebuilt library not found at ${PREBUILT_LIB_PATH}")
        message(FATAL_ERROR "   Please run: tools/build_libqemu_hmos.sh")
    endif()
else()
    # 编译模式：正常编译库
    message(STATUS "Building libqemu_hmos.so from source...")
    add_library(qemu_hmos SHARED ${SOURCES})
endif()

# QEMU库文件 - 动态检测存在的库文件（可能是静态库或动态库）
set(QEMU_LIBS_CANDIDATES
    # 静态库（如果QEMU配置为静态库）
    "${QEMU_BUILD_DIR}/libqemu-aarch64-softmmu.a"
    "${QEMU_BUILD_DIR}/libqemuutil.a"
    "${QEMU_BUILD_DIR}/libui-dbus.a"
    "${QEMU_BUILD_DIR}/libmodule-common.a"
    "${QEMU_BUILD_DIR}/libblock-curl.a"
    "${QEMU_BUILD_DIR}/libblock-ssh.a"
    "${QEMU_BUILD_DIR}/libhw-display-virtio-gpu.a"
    "${QEMU_BUILD_DIR}/libhw-display-virtio-gpu-pci.a"
    "${QEMU_BUILD_DIR}/libhw-uefi-vars.a"
    "${QEMU_BUILD_DIR}/subprojects/dtc/libfdt/libfdt.a"
    "${QEMU_BUILD_DIR}/subprojects/berkeley-softfloat-3/libsoftfloat.a"
    "${QEMU_BUILD_DIR}/qemu-bundle/usr/local/lib/libfdt.a"
    # 动态库（如果QEMU配置为动态库）
    "${QEMU_BUILD_DIR}/libqemu-aarch64-softmmu.so"
    "${QEMU_BUILD_DIR}/libqemuutil.so"
    "${QEMU_BUILD_DIR}/libui-dbus.so"
    "${QEMU_BUILD_DIR}/libmodule-common.so"
    "${QEMU_BUILD_DIR}/libblock-curl.so"
    "${QEMU_BUILD_DIR}/libblock-ssh.so"
    "${QEMU_BUILD_DIR}/libhw-display-virtio-gpu.so"
    "${QEMU_BUILD_DIR}/libhw-display-virtio-gpu-pci.so"
    "${QEMU_BUILD_DIR}/libhw-uefi-vars.so"
)

set(QEMU_LIBS "")
foreach(lib ${QEMU_LIBS_CANDIDATES})
    if(EXISTS ${lib})
        list(APPEND QEMU_LIBS ${lib})
        message(STATUS "Found QEMU library: ${lib}")
    else()
        message(STATUS "QEMU library not found (skipping): ${lib}")
    endif()
endforeach()

# QEMU库检测已在上面完成

# 链接QEMU库（静态库需要 whole-archive，否则会被裁掉）
if(QEMU_LIBS)
    target_link_libraries(qemu_hmos
        -Wl,--whole-archive
        ${QEMU_LIBS}
        -Wl,--no-whole-archive
        # QEMU依赖库
        -lpthread
        -ldl
        -lm
        -lz
        -lssl
        -lcrypto
        -lcurl
        -lssh
        -lgmp
        -lglib-2.0
        -lgio-2.0
        -lgobject-2.0
        -lpixman-1
        -lgnutls
        -ltasn1
        -lsasl2
        -lpam
        -lbz2
        -lzstd
    )
endif()

if(BUILD_FOR_OHOS)
    # 查找并链接必要的库
    # LOG 库在 HarmonyOS NDK 中的实际名称是 libhilog_ndk.z.so
    find_library(LOG_LIB hilog_ndk.z
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

    # NativeWindow / NativeBuffer (XComponent 直绘需要)
    find_library(NATIVE_WINDOW_LIB native_window
        PATHS
        "${OHOS_NDK_HOME}/sysroot/usr/lib"
        "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos"
        NO_DEFAULT_PATH
    )
    find_library(NATIVE_BUFFER_LIB native_buffer
        PATHS
        "${OHOS_NDK_HOME}/sysroot/usr/lib"
        "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos"
        NO_DEFAULT_PATH
    )

    if(NATIVE_WINDOW_LIB)
        target_link_libraries(qemu_hmos ${NATIVE_WINDOW_LIB})
    else()
        message(WARNING "native_window library not found, XComponent direct draw may fail to link")
    endif()
    if(NATIVE_BUFFER_LIB)
        target_link_libraries(qemu_hmos ${NATIVE_BUFFER_LIB})
    else()
        message(WARNING "native_buffer library not found, XComponent direct draw may fail to link")
    endif()

    message(STATUS "LOG_LIB: ${LOG_LIB}")
    message(STATUS "ANDROID_LIB: ${ANDROID_LIB}")

    # 查找鸿蒙NAPI库
    set(NAPI_LIB_PATH "${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos/libace_napi.z.so")

    if(EXISTS ${NAPI_LIB_PATH})
        set(NAPI_LIB ${NAPI_LIB_PATH})
        message(STATUS "Found NAPI library: ${NAPI_LIB}")
    else()
        message(WARNING "NAPI library not found at: ${NAPI_LIB_PATH}")
        set(NAPI_LIB "")
    endif()

    # 只有在非预编译模式下才链接系统库
    if(NOT USE_PREBUILT_LIB)
    if(NAPI_LIB)
        target_link_libraries(qemu_hmos ${NAPI_LIB})
    endif()
    if(LOG_LIB)
        target_link_libraries(qemu_hmos ${LOG_LIB})
    endif()
    if(ANDROID_LIB)
        target_link_libraries(qemu_hmos ${ANDROID_LIB})
        endif()
    endif()
endif()

# ============ 链接 QEMU 核心库（使用相对名称，让系统自动加载）============
# HarmonyOS 的命名空间策略阻止了 dlopen，所以改为直接链接依赖
set(QEMU_FULL_SO "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libqemu_full.so")
if(EXISTS ${QEMU_FULL_SO})
    message(STATUS "✅ Found QEMU core library: ${QEMU_FULL_SO}")
    # 使用 -L 和 -l 格式，确保 DT_NEEDED 中只有 "libqemu_full.so"（相对名称）
    target_link_directories(qemu_hmos PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a")
    target_link_options(qemu_hmos PRIVATE "-Wl,--no-as-needed")
    target_link_libraries(qemu_hmos qemu_full)
    target_link_options(qemu_hmos PRIVATE "-Wl,--as-needed")
    
    # ============ 确保 libqemu_full.so 被复制到输出目录 ============
    # HarmonyOS 构建系统需要显式复制依赖库
    add_custom_command(TARGET qemu_hmos POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${QEMU_FULL_SO}"
            "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libqemu_full.so"
        COMMENT "Copying libqemu_full.so to output directory"
    )
else()
    message(WARNING "❌ QEMU core library not found, will use dlopen at runtime")
endif()

# 2. VNC库 (LibVNC: server/client)
set(VNC_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libvncserver/libvncserver.a")
set(VNC_CLIENT_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libvncclient/libvncclient.a")

# 检查VNC库状态
if(EXISTS ${VNC_LIB_PATH})
    message(STATUS "✅ Found VNC server library: ${VNC_LIB_PATH}")
    set(HAVE_VNC_SERVER ON)
else()
    message(WARNING "❌ VNC server library not found, VNC server support will be limited")
    set(VNC_LIB_PATH "")
    set(HAVE_VNC_SERVER OFF)
endif()

if(EXISTS ${VNC_CLIENT_LIB_PATH})
    message(STATUS "✅ Found VNC client library: ${VNC_CLIENT_LIB_PATH}")
    add_definitions(-DLIBVNC_HAVE_CLIENT=1)
    set(HAVE_VNC_CLIENT ON)
else()
    message(WARNING "❌ VNC client library not found, Native VNC viewer will be stubbed")
    set(VNC_CLIENT_LIB_PATH "")
    set(HAVE_VNC_CLIENT OFF)
endif()

# OpenSSL library (static) （静态库）
# 从 entry/src/main/cpp 向上4级到项目根目录: ../../../../third_party/deps/install-ohos
set(OPENSSL_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/deps/install-ohos")
set(OPENSSL_CRYPTO_LIB "${OPENSSL_PREFIX}/lib/libcrypto.a")
set(OPENSSL_SSL_LIB "${OPENSSL_PREFIX}/lib/libssl.a")
set(OPENSSL_INCLUDE_DIR "${OPENSSL_PREFIX}/include")

if(EXISTS ${OPENSSL_CRYPTO_LIB} AND EXISTS ${OPENSSL_SSL_LIB})
    message(STATUS "✅ Found OpenSSL libraries:")
    message(STATUS "   - libcrypto.a: ${OPENSSL_CRYPTO_LIB}")
    message(STATUS "   - libssl.a: ${OPENSSL_SSL_LIB}")
    set(HAVE_OPENSSL ON)
else()
    message(WARNING "⚠️  OpenSSL static libraries not found, some features may be limited")
    set(OPENSSL_CRYPTO_LIB "")
    set(OPENSSL_SSL_LIB "")
    set(HAVE_OPENSSL OFF)
endif()

# 只有在非预编译模式下才链接系统库
if(BUILD_FOR_OHOS AND NOT USE_PREBUILT_LIB)
    if(NAPI_LIB)
        target_link_libraries(qemu_hmos ${NAPI_LIB})
    endif()
    if(LOG_LIB)
        target_link_libraries(qemu_hmos ${LOG_LIB})
    endif()
    if(ANDROID_LIB)
        target_link_libraries(qemu_hmos ${ANDROID_LIB})
    endif()
endif()

# 链接QEMU相关库（只在非预编译模式下）
# no direct link to libqemu_full.so

if(NOT USE_PREBUILT_LIB)
# 链接静态库 - 使用 --whole-archive 强制包含所有符号
# 必须在一个 target_link_libraries 调用中按正确顺序指定
set(STATIC_LIBS_TO_LINK "")

if(VNC_LIB_PATH)
    list(APPEND STATIC_LIBS_TO_LINK ${VNC_LIB_PATH})
endif()
if(VNC_CLIENT_LIB_PATH)
    list(APPEND STATIC_LIBS_TO_LINK ${VNC_CLIENT_LIB_PATH})
endif()

# 使用正确的链接顺序：--whole-archive 静态库 --no-whole-archive
# 添加 --allow-multiple-definition 处理 libvncserver 和 libvncclient 中的重复符号（SHA1, LZO等）
if(STATIC_LIBS_TO_LINK)
    target_link_libraries(qemu_hmos
        -Wl,--allow-multiple-definition
        -Wl,--whole-archive
        ${STATIC_LIBS_TO_LINK}
        -Wl,--no-whole-archive
    )
    message(STATUS "✅ Linking static libraries with --whole-archive: ${STATIC_LIBS_TO_LINK}")
endif()

# 依赖库
target_link_libraries(qemu_hmos 
    -lpthread
    -lz
)


# 设置编译选项（只在非预编译模式下）
if(BUILD_FOR_OHOS AND NOT USE_PREBUILT_LIB)
    target_compile_options(qemu_hmos PRIVATE
        -fPIC
        -Wall
        -Wextra
        -O2
        -D__MUSL__
        -D__OHOS__
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
        # QEMU特定编译选项
        -DCONFIG_VNC=1
        -DCONFIG_SLIRP=1
        -DCONFIG_TCG=1
        -DCONFIG_MODULES=1
        -DCONFIG_UI_DBUS=1
        -DCONFIG_VIRTIO_GPU=1
        -DCONFIG_VIRTIO_GPU_PCI=1
        -DCONFIG_BLOCK_CURL=1
        -DCONFIG_BLOCK_SSH=1
        -DCONFIG_UEFI_VARS=1
    )
elseif(NOT USE_PREBUILT_LIB)
    # 主机侧编译选项（只在非预编译模式下）
    target_compile_options(qemu_hmos PRIVATE
        -fPIC
        -Wall
        -Wextra
        -O2
    )
endif()

# 设置输出名称和路径 - 使用Hvigor期望的目录结构
# 只有在编译模式下才设置输出目录
if(NOT USE_PREBUILT_LIB)
set_target_properties(qemu_hmos PROPERTIES
    OUTPUT_NAME "qemu_hmos"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a"
)

# 确保 libqemu_hmos.so 也被复制到 intermediates 目录（HVIGOR 打包时会从这里读取）
set(QEMU_HMOS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libqemu_hmos.so")
set(QEMU_HMOS_DST_APP_DIR "${HVIGOR_APP_INTERMEDIATES_LIBS_DIR}")
set(QEMU_HMOS_DST_ENTRY_DIR "${HVIGOR_ENTRY_INTERMEDIATES_LIBS_DIR}")
set(QEMU_HMOS_DST_APP "${QEMU_HMOS_DST_APP_DIR}/libqemu_hmos.so")
set(QEMU_HMOS_DST_ENTRY "${QEMU_HMOS_DST_ENTRY_DIR}/libqemu_hmos.so")

add_custom_command(
    TARGET qemu_hmos POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_HMOS_DST_APP_DIR}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_HMOS_DST_ENTRY_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${QEMU_HMOS_SRC} ${QEMU_HMOS_DST_APP}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${QEMU_HMOS_SRC} ${QEMU_HMOS_DST_ENTRY}
    COMMENT "Copying libqemu_hmos.so to intermediates/libs for HAP packaging"
)
endif()

# ---- Bundle prebuilt QEMU core into native outputs (so Hvigor packs it) ----
# Copy prebuilt core from cpp folder to Hvigor expected directory
set(QEMU_FULL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libqemu_full.so")
set(QEMU_FULL_DST_APP_DIR "${HVIGOR_APP_INTERMEDIATES_LIBS_DIR}")
set(QEMU_FULL_DST_ENTRY_DIR "${HVIGOR_ENTRY_INTERMEDIATES_LIBS_DIR}")
set(QEMU_FULL_DST_ENTRY_STRIPPED_DIR "${HVIGOR_ENTRY_STRIPPED_LIBS_DIR}")
set(QEMU_FULL_DST_APP "${QEMU_FULL_DST_APP_DIR}/libqemu_full.so")
set(QEMU_FULL_DST_ENTRY "${QEMU_FULL_DST_ENTRY_DIR}/libqemu_full.so")
set(QEMU_FULL_DST_ENTRY_STRIPPED "${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}/libqemu_full.so")

# Copy libslirp.so.0 (QEMU networking component - note the .0 suffix!)
set(SLIRP_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libslirp.so.0")
set(SLIRP_DST_APP "${QEMU_FULL_DST_APP_DIR}/libslirp.so.0")
set(SLIRP_DST_ENTRY "${QEMU_FULL_DST_ENTRY_DIR}/libslirp.so.0")
set(SLIRP_DST_ENTRY_STRIPPED "${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}/libslirp.so.0")
if(EXISTS ${SLIRP_SRC})
    add_custom_command(
        OUTPUT ${SLIRP_DST_APP} ${SLIRP_DST_ENTRY} ${SLIRP_DST_ENTRY_STRIPPED}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_APP_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy ${SLIRP_SRC} ${SLIRP_DST_APP}
        COMMAND ${CMAKE_COMMAND} -E copy ${SLIRP_SRC} ${SLIRP_DST_ENTRY}
        COMMAND ${CMAKE_COMMAND} -E copy ${SLIRP_SRC} ${SLIRP_DST_ENTRY_STRIPPED}
        DEPENDS ${SLIRP_SRC}
        COMMENT "Copying libslirp.so.0 to intermediates"
    )
    add_custom_target(copy_slirp ALL DEPENDS ${SLIRP_DST_APP} ${SLIRP_DST_ENTRY} ${SLIRP_DST_ENTRY_STRIPPED})
endif()

# Copy libintl.so (gettext internationalization library)
set(INTL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libintl.so")
set(INTL_DST_APP "${QEMU_FULL_DST_APP_DIR}/libintl.so")
set(INTL_DST_ENTRY "${QEMU_FULL_DST_ENTRY_DIR}/libintl.so")
set(INTL_DST_ENTRY_STRIPPED "${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}/libintl.so")
if(EXISTS ${INTL_SRC})
    add_custom_command(
        OUTPUT ${INTL_DST_APP} ${INTL_DST_ENTRY} ${INTL_DST_ENTRY_STRIPPED}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_APP_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy ${INTL_SRC} ${INTL_DST_APP}
        COMMAND ${CMAKE_COMMAND} -E copy ${INTL_SRC} ${INTL_DST_ENTRY}
        COMMAND ${CMAKE_COMMAND} -E copy ${INTL_SRC} ${INTL_DST_ENTRY_STRIPPED}
        DEPENDS ${INTL_SRC}
        COMMENT "Copying libintl.so to intermediates"
    )
    add_custom_target(copy_intl ALL DEPENDS ${INTL_DST_APP} ${INTL_DST_ENTRY} ${INTL_DST_ENTRY_STRIPPED})
endif()

# Also copy to oh_modules for runtime loading
set(QEMU_FULL_OH_DST "${CMAKE_CURRENT_SOURCE_DIR}/../../oh_modules/libqemu_full.so")

if(EXISTS ${QEMU_FULL_SRC})
    add_custom_command(
        OUTPUT ${QEMU_FULL_DST_APP} ${QEMU_FULL_DST_ENTRY} ${QEMU_FULL_DST_ENTRY_STRIPPED} ${QEMU_FULL_OH_DST}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_APP_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different ${QEMU_FULL_SRC} ${QEMU_FULL_DST_APP}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different ${QEMU_FULL_SRC} ${QEMU_FULL_DST_ENTRY}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different ${QEMU_FULL_SRC} ${QEMU_FULL_DST_ENTRY_STRIPPED}
        COMMAND ${CMAKE_COMMAND} -E copy ${QEMU_FULL_SRC} ${QEMU_FULL_OH_DST}
        DEPENDS ${QEMU_FULL_SRC}
        COMMENT "Copying prebuilt libqemu_full.so to intermediates (entry/build & build) and oh_modules"
    )
    add_custom_target(copy_qemu_full ALL DEPENDS ${QEMU_FULL_DST_APP} ${QEMU_FULL_DST_ENTRY} ${QEMU_FULL_DST_ENTRY_STRIPPED} ${QEMU_FULL_OH_DST})
    add_dependencies(qemu_hmos copy_qemu_full)

    # 不再链接 libqemu_full.so，而是在运行时通过 dlopen 加载
    # 这样可以避免绝对路径被嵌入到 libqemu_hmos.so 中
    message(STATUS "libqemu_full.so will be loaded via dlopen at runtime")
else()
    message(WARNING "Prebuilt core not found at ${QEMU_FULL_SRC}; libqemu_full.so will not be packaged. You can still place it under src/main/libs/arm64-v8a/ manually or push to files/ at runtime.")
endif()

# End the source-build-only static-linking block opened above. Prebuilt
# packaging and diagnostics below must run in both build modes.
endif()

# ============ 复制架构特定的 QEMU 库（用于多架构支持）============
# libqemu_aarch64.so, libqemu_x86_64.so, libqemu_i386.so
set(QEMU_ARCH_LIBS "libqemu_aarch64.so" "libqemu_x86_64.so" "libqemu_i386.so")
foreach(ARCH_LIB ${QEMU_ARCH_LIBS})
    set(ARCH_LIB_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/${ARCH_LIB}")
    set(ARCH_LIB_DST_APP "${QEMU_FULL_DST_APP_DIR}/${ARCH_LIB}")
    set(ARCH_LIB_DST_ENTRY "${QEMU_FULL_DST_ENTRY_DIR}/${ARCH_LIB}")
    set(ARCH_LIB_DST_ENTRY_STRIPPED "${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}/${ARCH_LIB}")
    if(EXISTS ${ARCH_LIB_SRC})
        add_custom_command(
            OUTPUT ${ARCH_LIB_DST_APP} ${ARCH_LIB_DST_ENTRY} ${ARCH_LIB_DST_ENTRY_STRIPPED}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_APP_DIR}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_DIR}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${QEMU_FULL_DST_ENTRY_STRIPPED_DIR}
            COMMAND ${CMAKE_COMMAND} -E copy ${ARCH_LIB_SRC} ${ARCH_LIB_DST_APP}
            COMMAND ${CMAKE_COMMAND} -E copy ${ARCH_LIB_SRC} ${ARCH_LIB_DST_ENTRY}
            COMMAND ${CMAKE_COMMAND} -E copy ${ARCH_LIB_SRC} ${ARCH_LIB_DST_ENTRY_STRIPPED}
            DEPENDS ${ARCH_LIB_SRC}
            COMMENT "Copying ${ARCH_LIB} to intermediates for HAP packaging"
        )
        add_custom_target(copy_${ARCH_LIB} ALL DEPENDS ${ARCH_LIB_DST_APP} ${ARCH_LIB_DST_ENTRY} ${ARCH_LIB_DST_ENTRY_STRIPPED})
        message(STATUS "✅ Will copy ${ARCH_LIB} to HAP")
    else()
        message(STATUS "⚠️  ${ARCH_LIB} not found at ${ARCH_LIB_SRC}")
    endif()
endforeach()

# 添加自定义目标用于调试
add_custom_target(debug_info
    COMMAND ${CMAKE_COMMAND} -E echo "OHOS_NDK_HOME: ${OHOS_NDK_HOME}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_C_COMPILER: ${CMAKE_C_COMPILER}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}"
    COMMAND ${CMAKE_COMMAND} -E echo "CMAKE_FIND_ROOT_PATH: ${CMAKE_FIND_ROOT_PATH}"
    COMMAND ${CMAKE_COMMAND} -E echo "NAPI_LIB: ${NAPI_LIB}"
    COMMAND ${CMAKE_COMMAND} -E echo "HAVE_VNC_CLIENT: ${HAVE_VNC_CLIENT}"
    COMMAND ${CMAKE_COMMAND} -E echo "HAVE_VNC_SERVER: ${HAVE_VNC_SERVER}"
)

# 构建配置摘要
message(STATUS "=== QEMU on HarmonyOS Build Configuration ===")
message(STATUS "Target: ${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "C++ Standard: ${CMAKE_CXX_STANDARD}")

if(HAVE_VNC_CLIENT)
    message(STATUS "✅ VNC Client: Enabled")
else()
    message(STATUS "❌ VNC Client: Disabled (missing libvncclient.a)")
endif()

if(HAVE_VNC_SERVER)
    message(STATUS "✅ VNC Server: Enabled")
else()
    message(STATUS "❌ VNC Server: Disabled (missing libvncserver.a)")
endif()

# 检查核心库
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/libqemu_full.so")
    message(STATUS "✅ Core Library: Found (libqemu_full.so)")
else()
    message(STATUS "❌ Core Library: Missing (libqemu_full.so)")
endif()

message(STATUS "Output Directory: ${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a")
message(STATUS "================================================")

# 添加构建验证目标
add_custom_target(verify_build
    COMMAND ${CMAKE_COMMAND} -E echo "=== Build Verification ==="
    COMMAND ${CMAKE_COMMAND} -E echo "Checking output files..."
    COMMAND test -f "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libqemu_hmos.so" && echo "✅ libqemu_hmos.so found" || echo "❌ libqemu_hmos.so missing"
    COMMAND test -f "${CMAKE_CURRENT_SOURCE_DIR}/../../oh_modules/libqemu_full.so" && echo "✅ libqemu_full.so found in oh_modules" || echo "❌ libqemu_full.so missing in oh_modules"
    COMMAND test -f "${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libqemu_full.so" && echo "✅ libqemu_full.so found in libs" || echo "❌ libqemu_full.so missing in libs"
    COMMAND ${CMAKE_COMMAND} -E echo "=== Verification Complete ==="
    DEPENDS qemu_hmos copy_qemu_full
    COMMENT "Verifying that all required files are built and copied correctly"
)
