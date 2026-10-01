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
    const char* name;                    // 虚拟机名称
    const char* arch_type;               // 架构类型：aarch64, x86_64, i386
    const char* machine_type;            // 机器类型，如 "virt"
    const char* cpu_type;                // CPU 类型，如 "cortex-a57"
    int memory_mb;                       // 内存大小（MB）
    int cpu_count;                       // CPU核心数
    const char* disk_path;               // 硬盘文件路径
    int disk_size_gb;                    // 硬盘大小（GB）
    const char* iso_path;                // ISO镜像路径
    const char* efi_firmware;            // EFI固件路径
    const char* shared_dir;              // 宿主共享目录
    int vnc_port;                        // VNC端口
    int rdp_port;                        // RDP端口
    const char* network_mode;            // 网络模式：user, bridge, none
    const char* accel_mode;              // 加速模式：kvm, tcg, hvf
    const char* display_mode;            // 显示模式：vnc, sdl, gtk, none
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

// 硬盘管理
int qemu_create_disk(const char* path, int size_gb, const char* format);
int qemu_resize_disk(const char* path, int new_size_gb);

// 网络管理
int qemu_setup_network(const char* vm_name, const char* mode, int host_port, int guest_port);
int qemu_forward_port(const char* vm_name, int host_port, int guest_port);

// 显示管理
int qemu_start_vnc_server(const char* vm_name, int port);

// 快照管理
int qemu_create_snapshot(const char* vm_name, const char* snapshot_name);
int qemu_restore_snapshot(const char* vm_name, const char* snapshot_name);
int qemu_list_snapshots(const char* vm_name, char** snapshot_list, int* count);

// 文件共享
int qemu_mount_shared_dir(const char* vm_name, const char* host_path, const char* guest_path);

// 获取 QEMU 版本信息
const char* qemu_get_version(void);

// 检测系统能力
int qemu_detect_kvm_support(void);
int qemu_detect_hvf_support(void);
int qemu_detect_tcg_support(void);

// KVM 权限检测（HarmonyOS 专用）
const char* qemu_get_kvm_unavailable_reason(int is_release_build);
int qemu_is_pc_device(void);

// 设备信息设置（从 ArkTS 层调用）
// device_type: 0=unknown, 1=phone, 2=tablet, 3=2in1, 4=pc
void qemu_set_device_info(int device_type, const char* model);

// JIT 权限（ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY）
void qemu_set_jit_permission(int has_permission);
int qemu_has_jit_permission(void);
const char* qemu_get_jit_permission_info(int is_release_build);

// 日志管理
int qemu_get_vm_logs(const char* vm_name, char** logs, int* line_count);
int qemu_clear_vm_logs(const char* vm_name);
void qemu_append_log(const char* vm_name, const char* message);
void qemu_register_log_file(const char* vm_name, const char* log_path);

// Monitor 管理
void qemu_register_monitor(const char* vm_name, const char* socket_path);

// 共享目录管理
int qemu_get_shared_dirs(const char* vm_name, char*** dirs, int* count);

// 删除快照
int qemu_delete_snapshot(const char* vm_name, const char* snapshot_name);

// Windows 11 配置相关 (TPM/UEFI/SecureBoot)
// TPM 设置结果
typedef struct {
    int success;
    const char* socket_path;
    const char* state_dir;
    const char* error_message;
} tpm_setup_result_t;

// UEFI 设置结果
typedef struct {
    int success;
    const char* code_path;
    const char* vars_path;
    const char* error_message;
} uefi_setup_result_t;

// Windows 11 兼容性检查结果
typedef struct {
    int tpm_available;
    int uefi_available;
    int secure_boot_available;
    int overall_compatible;
    const char* tpm_status;
    const char* uefi_status;
    const char* secure_boot_status;
} win11_compatibility_result_t;

// TPM 管理
int qemu_setup_tpm(const char* vm_name, tpm_setup_result_t* result);
int qemu_cleanup_tpm(const char* vm_name);
int qemu_is_tpm_available(const char* vm_name);

// UEFI 管理
int qemu_setup_uefi(const char* vm_name, uefi_setup_result_t* result);
int qemu_cleanup_uefi(const char* vm_name);
int qemu_is_uefi_available(void);
const char* qemu_get_uefi_code_path(void);
const char* qemu_get_uefi_vars_template_path(void);

// Secure Boot 管理
int qemu_enable_secure_boot(const char* vm_name, int enable);
int qemu_is_secure_boot_enabled(const char* vm_name);

// Windows 11 兼容性检查
int qemu_check_win11_compatibility(const char* vm_name, win11_compatibility_result_t* result);

// 生成 Windows 11 优化的 QEMU 命令参数
const char* qemu_build_win11_args(const char* vm_name, int memory_mb, const char* disk_path, const char* iso_path);
// QEMU 核心库加载函数
extern "C" {
    void EnsureQemuCoreLoaded(const char* log_path);
    extern int (*g_qemu_core_init)(int argc, char** argv);
}

#ifdef __cplusplus
}
#endif

#endif // QEMU_WRAPPER_H