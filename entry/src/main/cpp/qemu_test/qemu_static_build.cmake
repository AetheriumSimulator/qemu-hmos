# QEMU 静态库构建配置
# 用于将编译好的 QEMU 静态库链接到 HarmonyOS NAPI 模块

set(QEMU_BUILD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/qemu/build)
set(QEMU_INSTALL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/qemu/qemu-build)

# QEMU 核心静态库路径（基于实际编译结果）
set(QEMU_STATIC_LIBS
    ${QEMU_BUILD_DIR}/libqemuutil.a
    ${QEMU_BUILD_DIR}/subprojects/berkeley-softfloat-3/libsoftfloat.a
    ${QEMU_BUILD_DIR}/subprojects/dtc/libfdt/libfdt.a
)

# QEMU 目标架构库（暂时为空，等待完整编译）
set(QEMU_TARGET_LIBS
    # 目标架构库将在完整编译后添加
)

# 包含 QEMU 头文件目录
set(QEMU_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/qemu/include
    ${QEMU_BUILD_DIR}
    ${QEMU_BUILD_DIR}/qapi
)

# 链接 QEMU 静态库的函数
function(link_qemu_static target_name)
    target_include_directories(${target_name} PRIVATE ${QEMU_INCLUDE_DIRS})
    
    # 链接核心静态库
    foreach(lib ${QEMU_STATIC_LIBS})
        if(EXISTS ${lib})
            target_link_libraries(${target_name} PRIVATE ${lib})
        endif()
    endforeach()
    
    # 链接目标架构库
    foreach(lib ${QEMU_TARGET_LIBS})
        if(EXISTS ${lib})
            target_link_libraries(${target_name} PRIVATE ${lib})
        endif()
    endforeach()
    
    # 链接系统依赖库
    target_link_libraries(${target_name} PRIVATE
        pthread
        dl
        m
        z
    )
endfunction()