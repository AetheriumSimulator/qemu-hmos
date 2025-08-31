#include "qemu_wrapper.h"
#include "rdp_client.h"
#include <string>
#include <map>
#include <mutex>
#include <thread>
#include <memory>
#include <cstring>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/stat.h>
#include <fstream>
#include <sstream>
#include <vector>

// QEMU 虚拟机实例结构
struct QemuVmInstance {
    qemu_vm_config_t config;
    qemu_vm_state_t state;
    pid_t qemu_pid;
    std::thread monitor_thread;
    bool should_stop;
    std::string log_file;
    std::vector<std::string> snapshots;
    
    QemuVmInstance() : state(QEMU_VM_STOPPED), qemu_pid(-1), should_stop(false) {
        memset(&config, 0, sizeof(config));
    }
};

// 全局状态管理
static std::map<qemu_vm_handle_t, std::unique_ptr<QemuVmInstance>> g_vm_instances;
static std::mutex g_vm_mutex;
static bool g_qemu_initialized = false;

// 内部辅助函数
static std::string build_qemu_command(const qemu_vm_config_t* config) {
    std::string cmd = "qemu-system-aarch64";
    
    // 基本配置
    cmd += " -name " + std::string(config->name ? config->name : "vm");
    cmd += " -machine " + std::string(config->machine_type ? config->machine_type : "virt");
    cmd += " -cpu " + std::string(config->cpu_type ? config->cpu_type : "cortex-a57");
    cmd += " -m " + std::to_string(config->memory_mb > 0 ? config->memory_mb : 6144); // 默认6GB
    cmd += " -smp " + std::to_string(config->cpu_count > 0 ? config->cpu_count : 4);   // 默认4核
    
    // 加速模式
    if (config->accel_mode) {
        if (strcmp(config->accel_mode, "kvm") == 0) {
            cmd += " -accel kvm";
        } else if (strcmp(config->accel_mode, "hvf") == 0) {
            cmd += " -accel hvf";
        } else {
            cmd += " -accel tcg,thread=multi";
        }
    } else {
        cmd += " -accel tcg,thread=multi";
    }
    
    // 硬盘
    if (config->disk_path) {
        cmd += " -drive file=" + std::string(config->disk_path) + ",format=qcow2,if=virtio";
    }
    
    // ISO镜像
    if (config->iso_path) {
        cmd += " -cdrom " + std::string(config->iso_path);
    }
    
    // EFI固件
    if (config->efi_firmware) {
        cmd += " -drive file=" + std::string(config->efi_firmware) + ",if=pflash,format=raw,unit=0,readonly=on";
        cmd += " -drive file=" + std::string(config->efi_firmware) + ",if=pflash,format=raw,unit=1,readonly=off";
    }
    
    // 网络
    if (config->network_mode && strcmp(config->network_mode, "none") != 0) {
        if (strcmp(config->network_mode, "user") == 0) {
            cmd += " -netdev user,id=net0";
            if (config->rdp_port > 0) {
                cmd += ",hostfwd=tcp:127.0.0.1:" + std::to_string(config->rdp_port) + "-:3389";
            }
        } else if (strcmp(config->network_mode, "bridge") == 0) {
            cmd += " -netdev bridge,id=net0";
        }
        cmd += " -device virtio-net-pci,netdev=net0";
    }
    
    // 显示模式
    if (config->display_mode) {
        if (strcmp(config->display_mode, "vnc") == 0) {
            cmd += " -vnc :" + std::to_string(config->vnc_port > 0 ? config->vnc_port : 0);
        } else if (strcmp(config->display_mode, "sdl") == 0) {
            cmd += " -display sdl";
        } else if (strcmp(config->display_mode, "gtk") == 0) {
            cmd += " -display gtk";
        } else if (strcmp(config->display_mode, "none") == 0) {
            cmd += " -nographic";
        }
    } else {
        cmd += " -nographic";
    }
    
    // 共享目录
    if (config->shared_dir) {
        cmd += " -virtfs local,path=" + std::string(config->shared_dir) + ",mount_tag=shared,security_model=mapped";
    }
    
    // 其他优化
    cmd += " -enable-kvm";
    cmd += " -rtc base=utc";
    cmd += " -serial stdio";
    
    return cmd;
}

static void monitor_qemu_process(QemuVmInstance* instance) {
    while (!instance->should_stop) {
        if (instance->qemu_pid > 0) {
            int status;
            pid_t result = waitpid(instance->qemu_pid, &status, WNOHANG);
            
            if (result == instance->qemu_pid) {
                // QEMU 进程已退出
                instance->state = QEMU_VM_STOPPED;
                instance->qemu_pid = -1;
                break;
            } else if (result == -1) {
                // 等待出错
                instance->state = QEMU_VM_ERROR;
                break;
            }
        }
        
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

// 公共接口实现
int qemu_init(void) {
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    if (g_qemu_initialized) {
        return 0; // 已初始化
    }
    
    // 检测系统能力
    g_qemu_initialized = true;
    return 0;
}

void qemu_cleanup(void) {
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    // 停止所有虚拟机
    for (auto& pair : g_vm_instances) {
        auto& instance = pair.second;
        if (instance->state == QEMU_VM_RUNNING) {
            qemu_vm_stop(pair.first);
        }
    }
    
    g_vm_instances.clear();
    g_qemu_initialized = false;
}

qemu_vm_handle_t qemu_vm_create(const qemu_vm_config_t* config) {
    if (!config) {
        return nullptr;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto instance = std::make_unique<QemuVmInstance>();
    
    // 复制配置
    instance->config = *config;
    if (config->name) {
        instance->config.name = strdup(config->name);
    }
    if (config->machine_type) {
        instance->config.machine_type = strdup(config->machine_type);
    }
    if (config->cpu_type) {
        instance->config.cpu_type = strdup(config->cpu_type);
    }
    if (config->disk_path) {
        instance->config.disk_path = strdup(config->disk_path);
    }
    if (config->iso_path) {
        instance->config.iso_path = strdup(config->iso_path);
    }
    if (config->efi_firmware) {
        instance->config.efi_firmware = strdup(config->efi_firmware);
    }
    if (config->shared_dir) {
        instance->config.shared_dir = strdup(config->shared_dir);
    }
    if (config->network_mode) {
        instance->config.network_mode = strdup(config->network_mode);
    }
    if (config->accel_mode) {
        instance->config.accel_mode = strdup(config->accel_mode);
    }
    if (config->display_mode) {
        instance->config.display_mode = strdup(config->display_mode);
    }

    qemu_vm_handle_t handle = instance.get();
    g_vm_instances[handle] = std::move(instance);
    
    return handle;
}

int qemu_vm_start(qemu_vm_handle_t handle) {
    if (!handle) {
        return -1;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return -1;
    }
    
    auto& instance = it->second;
    if (instance->state == QEMU_VM_RUNNING) {
        return 0; // 已在运行
    }
    
    // 构建 QEMU 命令
    std::string cmd = build_qemu_command(&instance->config);
    
    // 启动 QEMU 进程
    pid_t pid = fork();
    if (pid == 0) {
        // 子进程：执行 QEMU
        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(1); // 如果 exec 失败
    } else if (pid > 0) {
        // 父进程：记录 PID 并启动监控线程
        instance->qemu_pid = pid;
        instance->state = QEMU_VM_RUNNING;
        instance->should_stop = false;
        
        instance->monitor_thread = std::thread(monitor_qemu_process, instance.get());
        
        return 0;
    } else {
        // fork 失败
        return -1;
    }
}

int qemu_vm_stop(qemu_vm_handle_t handle) {
    if (!handle) {
        return -1;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return -1;
    }
    
    auto& instance = it->second;
    if (instance->state != QEMU_VM_RUNNING) {
        return 0; // 已停止
    }
    
    // 停止监控线程
    instance->should_stop = true;
    
    // 终止 QEMU 进程
    if (instance->qemu_pid > 0) {
        kill(instance->qemu_pid, SIGTERM);
        
        // 等待进程退出
        int status;
        waitpid(instance->qemu_pid, &status, 0);
        
        instance->qemu_pid = -1;
    }
    
    // 等待监控线程结束
    if (instance->monitor_thread.joinable()) {
        instance->monitor_thread.join();
    }
    
    instance->state = QEMU_VM_STOPPED;
    return 0;
}

int qemu_vm_pause(qemu_vm_handle_t handle) {
    if (!handle) {
        return -1;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return -1;
    }
    
    auto& instance = it->second;
    if (instance->state != QEMU_VM_RUNNING) {
        return -1;
    }
    
    if (instance->qemu_pid > 0) {
        kill(instance->qemu_pid, SIGSTOP);
        instance->state = QEMU_VM_PAUSED;
        return 0;
    }
    
    return -1;
}

int qemu_vm_resume(qemu_vm_handle_t handle) {
    if (!handle) {
        return -1;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return -1;
    }
    
    auto& instance = it->second;
    if (instance->state != QEMU_VM_PAUSED) {
        return -1;
    }
    
    if (instance->qemu_pid > 0) {
        kill(instance->qemu_pid, SIGCONT);
        instance->state = QEMU_VM_RUNNING;
        return 0;
    }
    
    return -1;
}

qemu_vm_state_t qemu_vm_get_state(qemu_vm_handle_t handle) {
    if (!handle) {
        return QEMU_VM_ERROR;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return QEMU_VM_ERROR;
    }
    
    return it->second->state;
}

void qemu_vm_destroy(qemu_vm_handle_t handle) {
    if (!handle) {
        return;
    }
    
    std::lock_guard<std::mutex> lock(g_vm_mutex);
    
    auto it = g_vm_instances.find(handle);
    if (it == g_vm_instances.end()) {
        return;
    }
    
    auto& instance = it->second;
    
    // 确保虚拟机已停止
    if (instance->state == QEMU_VM_RUNNING || instance->state == QEMU_VM_PAUSED) {
        qemu_vm_stop(handle);
    }

    // 等待监控线程结束
    if (instance->monitor_thread.joinable()) {
        instance->monitor_thread.join();
    }

    // 释放配置字符串
    if (instance->config.name) {
        free(const_cast<char*>(instance->config.name));
    }
    if (instance->config.machine_type) {
        free(const_cast<char*>(instance->config.machine_type));
    }
    if (instance->config.cpu_type) {
        free(const_cast<char*>(instance->config.cpu_type));
    }
    if (instance->config.disk_path) {
        free(const_cast<char*>(instance->config.disk_path));
    }
    if (instance->config.iso_path) {
        free(const_cast<char*>(instance->config.iso_path));
    }
    if (instance->config.efi_firmware) {
        free(const_cast<char*>(instance->config.efi_firmware));
    }
    if (instance->config.shared_dir) {
        free(const_cast<char*>(instance->config.shared_dir));
    }
    if (instance->config.network_mode) {
        free(const_cast<char*>(instance->config.network_mode));
    }
    if (instance->config.accel_mode) {
        free(const_cast<char*>(instance->config.accel_mode));
    }
    if (instance->config.display_mode) {
        free(const_cast<char*>(instance->config.display_mode));
    }

    g_vm_instances.erase(it);
}

// 硬盘管理
int qemu_create_disk(const char* path, int size_gb, const char* format) {
    if (!path || size_gb <= 0) {
        return -1;
    }
    
    std::string format_str = format ? format : "qcow2";
    std::string cmd = "qemu-img create -f " + format_str + " " + path + " " + std::to_string(size_gb) + "G";
    
    return system(cmd.c_str());
}

int qemu_resize_disk(const char* path, int new_size_gb) {
    if (!path || new_size_gb <= 0) {
        return -1;
    }
    
    std::string cmd = "qemu-img resize " + std::string(path) + " " + std::to_string(new_size_gb) + "G";
    
    return system(cmd.c_str());
}

// 网络管理
int qemu_setup_network(const char* vm_name, const char* mode, int host_port, int guest_port) {
    // 这里可以实现网络配置逻辑
    return 0;
}

int qemu_forward_port(const char* vm_name, int host_port, int guest_port) {
    // 这里可以实现端口转发逻辑
    return 0;
}

// 显示管理
int qemu_start_vnc_server(const char* vm_name, int port) {
    // 这里可以实现VNC服务器启动逻辑
    return 0;
}

int qemu_start_rdp_server(const char* vm_name, int port) {
    // 这里可以实现RDP服务器启动逻辑
    return 0;
}

// 快照管理
int qemu_create_snapshot(const char* vm_name, const char* snapshot_name) {
    // 这里可以实现快照创建逻辑
    return 0;
}

int qemu_restore_snapshot(const char* vm_name, const char* snapshot_name) {
    // 这里可以实现快照恢复逻辑
    return 0;
}

int qemu_list_snapshots(const char* vm_name, char** snapshot_list, int* count) {
    // 这里可以实现快照列表获取逻辑
    return 0;
}

// 文件共享
int qemu_mount_shared_dir(const char* vm_name, const char* host_path, const char* guest_path) {
    // 这里可以实现目录挂载逻辑
    return 0;
}

// 获取 QEMU 版本信息
const char* qemu_get_version(void) {
    return "QEMU HarmonyOS Wrapper 1.0.0";
}

// 检测系统能力
int qemu_detect_kvm_support(void) {
    // 检测KVM支持
    std::ifstream kvm_file("/dev/kvm");
    return kvm_file.good() ? 1 : 0;
}

int qemu_detect_hvf_support(void) {
    // 检测HVF支持（macOS）
    #ifdef __APPLE__
    return 1;
    #else
    return 0;
    #endif
}

int qemu_detect_tcg_support(void) {
    // TCG总是支持的
    return 1;
}

// 日志管理
int qemu_get_vm_logs(const char* vm_name, char** logs, int* line_count) {
    // 这里可以实现日志获取逻辑
    return 0;
}

int qemu_clear_vm_logs(const char* vm_name) {
    // 这里可以实现日志清理逻辑
    return 0;
}

// RDP客户端管理接口
rdp_client_handle_t rdp_client_create(void) {
    // 创建RDP客户端实例
    auto* client = new RdpClient();
    return static_cast<rdp_client_handle_t>(client);
}

int rdp_client_connect(rdp_client_handle_t handle, const rdp_connection_config_t* config) {
    if (!handle || !config) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    
    // 转换配置
    RdpConnectionConfig rdp_config;
    rdp_config.host = config->host ? config->host : "";
    rdp_config.port = config->port;
    rdp_config.username = config->username ? config->username : "";
    rdp_config.password = config->password ? config->password : "";
    rdp_config.domain = config->domain ? config->domain : "";
    rdp_config.width = config->width;
    rdp_config.height = config->height;
    rdp_config.color_depth = config->color_depth;
    rdp_config.enable_audio = config->enable_audio != 0;
    rdp_config.enable_clipboard = config->enable_clipboard != 0;
    rdp_config.enable_file_sharing = config->enable_file_sharing != 0;
    rdp_config.shared_folder = config->shared_folder ? config->shared_folder : "";
    
    return client->connect(rdp_config) ? 0 : -1;
}

void rdp_client_disconnect(rdp_client_handle_t handle) {
    if (handle) {
        auto* client = static_cast<RdpClient*>(handle);
        client->disconnect();
    }
}

int rdp_client_is_connected(rdp_client_handle_t handle) {
    if (!handle) {
        return 0;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->is_connected() ? 1 : 0;
}

rdp_connection_state_t rdp_client_get_state(rdp_client_handle_t handle) {
    if (!handle) {
        return RDP_ERROR;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    auto state = client->get_connection_state();
    
    switch (state) {
        case RdpConnectionState::DISCONNECTED:
            return RDP_DISCONNECTED;
        case RdpConnectionState::CONNECTING:
            return RDP_CONNECTING;
        case RdpConnectionState::CONNECTED:
            return RDP_CONNECTED;
        case RdpConnectionState::ERROR:
        default:
            return RDP_ERROR;
    }
}

// RDP显示控制
int rdp_client_set_resolution(rdp_client_handle_t handle, int width, int height) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->set_resolution(width, height) ? 0 : -1;
}

int rdp_client_set_color_depth(rdp_client_handle_t handle, int depth) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->set_color_depth(depth) ? 0 : -1;
}

int rdp_client_enable_fullscreen(rdp_client_handle_t handle, int enable) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->enable_fullscreen(enable != 0) ? 0 : -1;
}

// RDP输入控制
int rdp_client_send_mouse_event(rdp_client_handle_t handle, int x, int y, int button, int pressed) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->send_mouse_event(x, y, button, pressed != 0) ? 0 : -1;
}

int rdp_client_send_keyboard_event(rdp_client_handle_t handle, int key, int pressed) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->send_keyboard_event(key, pressed != 0) ? 0 : -1;
}

int rdp_client_send_text_input(rdp_client_handle_t handle, const char* text) {
    if (!handle || !text) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->send_text_input(text) ? 0 : -1;
}

// RDP剪贴板管理
int rdp_client_enable_clipboard_sharing(rdp_client_handle_t handle, int enable) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->enable_clipboard_sharing(enable != 0) ? 0 : -1;
}

int rdp_client_get_clipboard_text(rdp_client_handle_t handle, char** text) {
    if (!handle || !text) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    std::string clipboard_text = client->get_clipboard_text();
    
    if (clipboard_text.empty()) {
        *text = nullptr;
        return 0;
    }
    
    *text = new char[clipboard_text.length() + 1];
    strcpy(*text, clipboard_text.c_str());
    
    return 0;
}

int rdp_client_set_clipboard_text(rdp_client_handle_t handle, const char* text) {
    if (!handle || !text) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->set_clipboard_text(text) ? 0 : -1;
}

// RDP文件共享
int rdp_client_enable_file_sharing(rdp_client_handle_t handle, int enable) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->enable_file_sharing(enable != 0) ? 0 : -1;
}

int rdp_client_set_shared_folder(rdp_client_handle_t handle, const char* path) {
    if (!handle || !path) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->set_shared_folder(path) ? 0 : -1;
}

int rdp_client_get_shared_folder(rdp_client_handle_t handle, char** path) {
    if (!handle || !path) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    std::string shared_folder = client->get_shared_folder();
    
    if (shared_folder.empty()) {
        *path = nullptr;
        return 0;
    }
    
    *path = new char[shared_folder.length() + 1];
    strcpy(*path, shared_folder.c_str());
    
    return 0;
}

// RDP音频控制
int rdp_client_enable_audio(rdp_client_handle_t handle, int enable) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->enable_audio(enable != 0) ? 0 : -1;
}

int rdp_client_set_audio_volume(rdp_client_handle_t handle, int volume) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->set_audio_volume(volume) ? 0 : -1;
}

int rdp_client_get_audio_volume(rdp_client_handle_t handle) {
    if (!handle) {
        return -1;
    }
    
    auto* client = static_cast<RdpClient*>(handle);
    return client->get_audio_volume();
}

// RDP客户端销毁
void rdp_client_destroy(rdp_client_handle_t handle) {
    if (handle) {
        auto* client = static_cast<RdpClient*>(handle);
        delete client;
    }
}