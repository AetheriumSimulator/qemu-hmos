#ifndef QEMU_WRAPPER_H
#define QEMU_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// QEMU 虚拟机状态
typedef enum {
    QEMU_VM_STOPPED = 0,
    QEMU_VM_RUNNING = 1,
    QEMU_VM_PAUSED = 2,
    QEMU_VM_ERROR = -1
} qemu_vm_state_t;

// QEMU 虚拟机配置
typedef struct {
    const char* machine_type;    // 机器类型，如 "virt"
    const char* cpu_type;        // CPU 类型，如 "cortex-a57"
    int memory_mb;               // 内存大小（MB）
    const char* kernel_path;     // 内核镜像路径
    const char* initrd_path;     // initrd 路径（可选）
    const char* cmdline;         // 内核命令行参数
} qemu_vm_config_t;

// QEMU 虚拟机实例句柄
typedef void* qemu_vm_handle_t;

// QEMU 核心接口
int qemu_init(void);
void qemu_cleanup(void);

// 虚拟机管理接口
qemu_vm_handle_t qemu_vm_create(const qemu_vm_config_t* config);
int qemu_vm_start(qemu_vm_handle_t handle);
int qemu_vm_stop(qemu_vm_handle_t handle);
int qemu_vm_pause(qemu_vm_handle_t handle);
int qemu_vm_resume(qemu_vm_handle_t handle);
qemu_vm_state_t qemu_vm_get_state(qemu_vm_handle_t handle);
void qemu_vm_destroy(qemu_vm_handle_t handle);

// 获取 QEMU 版本信息
const char* qemu_get_version(void);

#ifdef __cplusplus
}
#endif

#endif // QEMU_WRAPPER_H