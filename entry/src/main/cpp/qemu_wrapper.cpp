#include "qemu_wrapper.h"
#include <string>
#include <map>
#include <mutex>
#include <thread>
#include <memory>
#include <cstring>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>

// QEMU 虚拟机实例结构
struct QemuVmInstance {
    qemu_vm_config_t config;
    qemu_vm_state_t state;
    pid_t qemu_pid;
    std::thread monitor_thread;
    bool should_stop;
    
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
    cmd += " -machine " + std::string(config->machine_type ? config->machine_type : "virt");
    cmd += " -cpu " + std::string(config->cpu_type ? config->cpu_type : "cortex-a57");
    cmd += " -m " + std::to_string(config->memory_mb > 0 ? config->memory_mb : 512);
    
    // 无图形界面模式
    cmd += " -nographic -serial stdio";
    
    // 内核和 initrd
    if (config->kernel_path) {
        cmd += " -kernel " + std::string(config->kernel_path);
    }
    if (config->initrd_path) {
        cmd += " -initrd " + std::string(config->initrd_path);
    }
    if (config->cmdline) {
        cmd += " -append \"" + std::string(config->cmdline) + "\"";
    }

    if (config->shared_dir) {
        std::string sock = "/tmp/virtiofsd.sock";
        cmd += " -chardev socket,id=char0,path=" + sock;
        cmd += " -device vhost-user-fs-pci,chardev=char0,tag=hostshare";
        cmd += " -virtiofsd socket=" + sock + ",source=" + std::string(config->shared_dir) + ",tag=hostshare";
    }

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
    
    // 这里可以添加 QEMU 库的初始化代码
    // 目前使用外部 qemu-system-aarch64 进程
    
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
    if (config->machine_type) {
        instance->config.machine_type = strdup(config->machine_type);
    }
    if (config->cpu_type) {
        instance->config.cpu_type = strdup(config->cpu_type);
    }
    if (config->kernel_path) {
        instance->config.kernel_path = strdup(config->kernel_path);
    }
    if (config->initrd_path) {
        instance->config.initrd_path = strdup(config->initrd_path);
    }
    if (config->cmdline) {
        instance->config.cmdline = strdup(config->cmdline);
    }
    if (config->shared_dir) {
        instance->config.shared_dir = strdup(config->shared_dir);
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
    
    // 释放配置字符串
    if (instance->config.machine_type) {
        free(const_cast<char*>(instance->config.machine_type));
    }
    if (instance->config.cpu_type) {
        free(const_cast<char*>(instance->config.cpu_type));
    }
    if (instance->config.kernel_path) {
        free(const_cast<char*>(instance->config.kernel_path));
    }
    if (instance->config.initrd_path) {
        free(const_cast<char*>(instance->config.initrd_path));
    }
    if (instance->config.cmdline) {
        free(const_cast<char*>(instance->config.cmdline));
    }
    if (instance->config.shared_dir) {
        free(const_cast<char*>(instance->config.shared_dir));
    }

    g_vm_instances.erase(it);
}

const char* qemu_get_version(void) {
    return "QEMU HarmonyOS Wrapper 1.0.0";
}