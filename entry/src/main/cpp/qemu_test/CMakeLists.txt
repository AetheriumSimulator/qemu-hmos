# 简化的 CMake 配置用于测试 QEMU 库链接
cmake_minimum_required(VERSION 3.10)
project(qemu_link_test)

set(CMAKE_CXX_STANDARD 17)

# 包含 QEMU 静态库构建配置
include(qemu_static_build.cmake)

# 创建测试可执行文件
add_executable(qemu_link_test test_qemu_link.cpp)

# 链接 QEMU 静态库到测试目标
link_qemu_static(qemu_link_test)

# 添加系统库
target_link_libraries(qemu_link_test PRIVATE pthread dl)