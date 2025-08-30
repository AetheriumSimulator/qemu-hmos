cmake_minimum_required(VERSION 3.10.0)
project(qemu_hmos)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

<<<<<<< HEAD
# 包含 QEMU 静态库构建配置（如果存在）
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/qemu_static_build.cmake")
    include(qemu_static_build.cmake)
endif()

add_library(qemu_hmos SHARED napi_init.cpp)
=======
add_library(qemu_hmos SHARED napi_init.cpp qemu_wrapper.cpp)
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579

# 链接 QEMU 静态库（如果存在）
if(COMMAND link_qemu_static)
    link_qemu_static(qemu_hmos)
endif()

find_package(Threads REQUIRED)
# 在macOS上只链接Threads，在HarmonyOS上链接NAPI库
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    target_link_libraries(qemu_hmos PUBLIC Threads::Threads)
else()
    target_link_libraries(qemu_hmos PUBLIC libace_napi.z.so libhilog_ndk.z.so Threads::Threads)
endif()
