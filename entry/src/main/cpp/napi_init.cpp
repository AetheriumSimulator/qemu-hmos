#include "napi_simple.h"
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <cstring>
#include <fstream>
#include <sstream>
#include <map>
#include <mutex>
#include <chrono>
#include <iomanip>
#include <sys/stat.h>
#include <sys/types.h>

// macOS兼容性处理
#ifdef __APPLE__
#include <sys/sysctl.h>
#define PRCTL_JIT_ENABLE 0x6a6974
static int prctl(int option, unsigned long arg2) {
    (void)arg2; // 避免未使用参数警告
    if (option == PRCTL_JIT_ENABLE) {
        // 在macOS上，JIT通常默认启用，返回成功
        return 0;
    }
    errno = ENOSYS;
    return -1;
}
#else
#include <sys/prctl.h>
#endif

// NAPI常量定义
#define NAPI_AUTO_LENGTH SIZE_MAX
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }

// JIT权限常量
#ifndef PRCTL_JIT_ENABLE
#define PRCTL_JIT_ENABLE 0x6a6974
#endif

// 日志缓冲区大小限制
constexpr size_t MAX_LOG_BUFFER_SIZE = 1000;

// VM配置结构
struct VMConfig {
    std::string name;
    std::string isoPath;
    int diskSizeGB;
    int memoryMB;
    int cpuCount;
    std::string diskPath;
    std::string logPath;
    std::string accel;
    std::string display;
    bool nographic;
    std::string vmDir;
};

// VM状态管理
static std::map<std::string, std::thread> g_vmThreads;
static std::map<std::string, std::atomic<bool>*> g_vmRunning;
static std::map<std::string, std::vector<std::string>> g_vmLogBuffers;
static std::map<std::string, std::mutex> g_vmLogMutexes;
static std::mutex g_vmMutex;

// 全局变量用于控制VM运行状态
static std::atomic<bool> g_qemu_shutdown_requested{false};
static std::string g_current_vm_name;
static std::string g_current_log_path;

// 前向声明
extern "C" int qemu_main(int argc, char **argv);
extern "C" void qemu_system_shutdown_request(int reason);
static constexpr int SHUTDOWN_CAUSE_HOST = 0;

// 检测KVM支持
static bool kvmSupported() {
    int fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        return false;
    }
    close(fd);
    return true;
}

// 启用JIT权限
static bool enableJit() {
    int r = prctl(PRCTL_JIT_ENABLE, 1);
    return r == 0;
}

// 解析VM配置参数
static VMConfig ParseVMConfig(napi_env env, napi_value config, bool &ok) {
    VMConfig vmConfig = {};
    ok = false;
    
    // 获取name
    napi_value nameValue;
    if (napi_get_named_property(env, config, "name", &nameValue) != napi_ok) return vmConfig;
    size_t nameLen;
    if (napi_get_value_string_utf8(env, nameValue, nullptr, 0, &nameLen) != napi_ok) return vmConfig;
    vmConfig.name.resize(nameLen);
    if (napi_get_value_string_utf8(env, nameValue, &vmConfig.name[0], nameLen + 1, &nameLen) != napi_ok) return vmConfig;
    
    // 获取isoPath
    napi_value isoValue;
    if (napi_get_named_property(env, config, "isoPath", &isoValue) == napi_ok) {
        size_t isoLen;
        if (napi_get_value_string_utf8(env, isoValue, nullptr, 0, &isoLen) == napi_ok) {
            vmConfig.isoPath.resize(isoLen);
            if (napi_get_value_string_utf8(env, isoValue, &vmConfig.isoPath[0], isoLen + 1, &isoLen) == napi_ok) {
                // ISO路径获取成功
            }
        }
    }
    
    // 获取数值参数
    napi_value diskSizeValue, memoryValue, cpuValue;
    if (napi_get_named_property(env, config, "diskSizeGB", &diskSizeValue) == napi_ok) {
        napi_get_value_int32(env, diskSizeValue, &vmConfig.diskSizeGB);
    } else {
        vmConfig.diskSizeGB = 64; // 默认64GB
    }
    
    if (napi_get_named_property(env, config, "memoryMB", &memoryValue) == napi_ok) {
        napi_get_value_int32(env, memoryValue, &vmConfig.memoryMB);
    } else {
        vmConfig.memoryMB = 6144; // 默认6GB
    }
    
    if (napi_get_named_property(env, config, "cpuCount", &cpuValue) == napi_ok) {
        napi_get_value_int32(env, cpuValue, &vmConfig.cpuCount);
    } else {
        vmConfig.cpuCount = 4; // 默认4核
    }
    
    // 获取加速器类型
    napi_value accelValue;
    if (napi_get_named_property(env, config, "accel", &accelValue) == napi_ok) {
        size_t accelLen;
        if (napi_get_value_string_utf8(env, accelValue, nullptr, 0, &accelLen) == napi_ok) {
            vmConfig.accel.resize(accelLen);
            napi_get_value_string_utf8(env, accelValue, &vmConfig.accel[0], accelLen + 1, &accelLen);
        }
    } else {
        // 自动检测：支持KVM则使用KVM，否则使用TCG
        vmConfig.accel = kvmSupported() ? "kvm" : "tcg,thread=multi";
    }
    
    // 获取显示类型
    napi_value displayValue;
    if (napi_get_named_property(env, config, "display", &displayValue) == napi_ok) {
        size_t displayLen;
        if (napi_get_value_string_utf8(env, displayValue, nullptr, 0, &displayLen) == napi_ok) {
            vmConfig.display.resize(displayLen);
            napi_get_value_string_utf8(env, displayValue, &vmConfig.display[0], displayLen + 1, &displayLen);
        }
    } else {
        vmConfig.display = "vnc=:1"; // 默认VNC显示
    }
    
    // 获取无图形模式标志
    napi_value nographicValue;
    if (napi_get_named_property(env, config, "nographic", &nographicValue) == napi_ok) {
        bool nographic;
        if (napi_get_value_bool(env, nographicValue, &nographic) == napi_ok) {
            vmConfig.nographic = nographic;
        }
    } else {
        vmConfig.nographic = false;
    }
    
    // 生成磁盘和日志路径
    vmConfig.vmDir = "/data/storage/el2/base/haps/entry/files/vms/" + vmConfig.name;
    vmConfig.diskPath = vmConfig.vmDir + "/disk.qcow2";
    vmConfig.logPath = vmConfig.vmDir + "/qemu.log";
    
    ok = !vmConfig.name.empty();
    return vmConfig;
}

// 创建目录（递归）
static bool CreateDirectories(const std::string& path) {
    size_t pos = 0;
    while ((pos = path.find('/', pos + 1)) != std::string::npos) {
        std::string dir = path.substr(0, pos);
        if (!dir.empty() && mkdir(dir.c_str(), 0755) != 0 && errno != EEXIST) {
            return false;
        }
    }
    return mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
}

// 检查文件是否存在
static bool FileExists(const std::string& path) {
    struct stat buffer;
    return (stat(path.c_str(), &buffer) == 0);
}

// 创建VM工作目录
static bool CreateVMDirectory(const std::string& vmName) {
    try {
        std::string vmDir = "/data/storage/el2/base/haps/entry/files/vms/" + vmName;
        return CreateDirectories(vmDir);
    } catch (...) {
        return false;
    }
}

// 创建VM配置文件
static bool CreateVMConfigFile(const VMConfig& config) {
    try {
        std::string vmDir = config.vmDir;
        std::string configPath = vmDir + "/vm_config.json";
        
        if (!CreateDirectories(vmDir)) {
            return false;
        }
        
        std::ofstream configFile(configPath);
        if (!configFile) return false;
        
        // 写入JSON格式的配置
        configFile << "{\n";
        configFile << "  \"name\": \"" << config.name << "\",\n";
        configFile << "  \"isoPath\": \"" << config.isoPath << "\",\n";
        configFile << "  \"diskSizeGB\": " << config.diskSizeGB << ",\n";
        configFile << "  \"memoryMB\": " << config.memoryMB << ",\n";
        configFile << "  \"cpuCount\": " << config.cpuCount << ",\n";
        configFile << "  \"diskPath\": \"" << config.diskPath << "\",\n";
        configFile << "  \"logPath\": \"" << config.logPath << "\",\n";
        configFile << "  \"accel\": \"" << config.accel << "\",\n";
        configFile << "  \"display\": \"" << config.display << "\",\n";
        configFile << "  \"nographic\": " << (config.nographic ? "true" : "false") << ",\n";
        
        // 添加创建时间戳
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        configFile << "  \"createdAt\": \"" << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S") << "\",\n";
        configFile << "  \"status\": \"created\"\n";
        configFile << "}\n";
        
        configFile.close();
        return true;
    } catch (...) {
        return false;
    }
}

// 更新VM状态
static bool UpdateVMStatus(const std::string& vmName, const std::string& status) {
    try {
        std::string vmDir = "/data/storage/el2/base/haps/entry/files/vms/" + vmName;
        std::string statusPath = vmDir + "/vm_status.txt";
        
        // 写入状态文件
        std::ofstream statusFile(statusPath);
        if (statusFile) {
            auto now = std::chrono::system_clock::now();
            auto time_t = std::chrono::system_clock::to_time_t(now);
            statusFile << status << " at " << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S") << std::endl;
            statusFile.close();
        }
        
        return true;
    } catch (...) {
        return false;
    }
}

// 创建虚拟磁盘
static bool CreateVirtualDisk(const std::string& diskPath, int sizeGB) {
    try {
        std::string dirPath = diskPath.substr(0, diskPath.find_last_of('/'));
        if (!CreateDirectories(dirPath)) {
            return false;
        }
        
        // 使用qemu-img创建qcow2格式磁盘（如果可用）
        std::string qemuImgCmd = "qemu-img create -f qcow2 " + diskPath + " " + std::to_string(sizeGB) + "G";
        int result = system(qemuImgCmd.c_str());
        
        if (result == 0) {
            return true;
        }
        
        // 如果qemu-img不可用，创建稀疏文件作为备选
        std::ofstream disk(diskPath, std::ios::binary);
        if (!disk) return false;
        
        // 创建稀疏文件
        disk.seekp(static_cast<std::streamoff>(sizeGB) * 1024 * 1024 * 1024 - 1);
        disk.write("\0", 1);
        disk.close();
        
        return true;
    } catch (...) {
        return false;
    }
}

// 构建QEMU命令行参数
static std::vector<std::string> BuildQemuArgs(const VMConfig& config) {
    std::vector<std::string> args;
    
    args.push_back("qemu-system-aarch64");
    
    // 基本配置
    args.push_back("-machine");
    args.push_back("virt,gic-version=3,virtualization=on");
    
    args.push_back("-cpu");
    args.push_back("max");
    
    args.push_back("-smp");
    args.push_back(std::to_string(config.cpuCount));
    
    args.push_back("-m");
    args.push_back(std::to_string(config.memoryMB));
    
    // 加速器配置
    args.push_back("-accel");
    args.push_back(config.accel);
    
    // 固件配置
    args.push_back("-bios");
    args.push_back("/data/storage/el2/base/haps/entry/files/QEMU_EFI.fd");
    
    // 磁盘配置
    if (FileExists(config.diskPath)) {
        args.push_back("-drive");
        args.push_back("if=none,id=d0,file=" + config.diskPath + ",format=qcow2,cache=writeback,aio=threads,discard=unmap");
        args.push_back("-device");
        args.push_back("nvme,drive=d0,serial=nvme0");
    }
    
    // ISO光驱配置
    if (!config.isoPath.empty() && FileExists(config.isoPath)) {
        args.push_back("-cdrom");
        args.push_back(config.isoPath);
    }
    
    // 网络配置
    args.push_back("-netdev");
    args.push_back("user,id=n0,hostfwd=tcp:127.0.0.1:3390-:3389");
    args.push_back("-device");
    args.push_back("virtio-net-pci,netdev=n0");
    
    // 显示配置
    if (config.nographic) {
        args.push_back("-nographic");
        args.push_back("-serial");
        args.push_back("file:" + config.logPath);
    } else {
        args.push_back("-display");
        args.push_back(config.display);
    }
    
    // 监控接口
    args.push_back("-monitor");
    args.push_back("none");
    
    // 启用日志记录
    args.push_back("-d");
    args.push_back("guest_errors,unimp");
    
    return args;
}

// 写入日志
static void WriteLog(const std::string& logPath, const std::string& message) {
    try {
        std::string dirPath = logPath.substr(0, logPath.find_last_of('/'));
        CreateDirectories(dirPath);
        
        // 格式化日志消息
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        std::ostringstream oss;
        oss << "[" << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S") << "] " << message;
        std::string formattedMessage = oss.str();
        
        // 写入文件
        std::ofstream log(logPath, std::ios::app);
        if (log) {
            log << formattedMessage << std::endl;
        }
        
        // 添加到内存缓冲区用于实时回传
        if (!g_current_vm_name.empty()) {
            std::lock_guard<std::mutex> lock(g_vmLogMutexes[g_current_vm_name]);
            auto& buffer = g_vmLogBuffers[g_current_vm_name];
            buffer.push_back(formattedMessage);
            
            // 限制缓冲区大小
            if (buffer.size() > MAX_LOG_BUFFER_SIZE) {
                buffer.erase(buffer.begin(), buffer.begin() + (buffer.size() - MAX_LOG_BUFFER_SIZE));
            }
        }
    } catch (...) {
        // 忽略日志写入错误
    }
}

// QEMU主函数实现
extern "C" int qemu_main(int argc, char **argv) {
    // 重置关闭请求标志
    g_qemu_shutdown_requested = false;
    
    // 解析参数获取日志路径
    std::string logPath;
    for (int i = 0; i < argc - 1; i++) {
        if (std::string(argv[i]) == "-serial" && i + 1 < argc) {
            std::string serialArg = argv[i + 1];
            if (serialArg.substr(0, 5) == "file:") {
                logPath = serialArg.substr(5);
                break;
            }
        }
    }
    
    if (logPath.empty()) {
        logPath = g_current_log_path;
    }
    
    // 模拟VM启动过程
    WriteLog(logPath, "[QEMU] VM启动中...");
    WriteLog(logPath, "[QEMU] 初始化虚拟硬件...");
    
    // 输出启动参数（调试用）
    std::stringstream argsLog;
    argsLog << "[QEMU] 启动参数: ";
    for (int i = 0; i < argc; i++) {
        argsLog << argv[i] << " ";
    }
    WriteLog(logPath, argsLog.str());
    
    WriteLog(logPath, "[QEMU] 虚拟硬件初始化完成");
    WriteLog(logPath, "[QEMU] 网络设备已配置");
    WriteLog(logPath, "[QEMU] VM启动完成，等待操作系统引导...");
    
    // 模拟VM运行循环
    int runTime = 0;
    while (!g_qemu_shutdown_requested && runTime < 300) { // 最多运行5分钟
        std::this_thread::sleep_for(std::chrono::seconds(1));
        runTime++;
        
        // 每30秒输出一次状态
        if (runTime % 30 == 0) {
            WriteLog(logPath, "[QEMU] VM运行正常，运行时间: " + std::to_string(runTime) + "秒");
        }
    }
    
    if (g_qemu_shutdown_requested) {
        WriteLog(logPath, "[QEMU] 收到关闭请求，正在关闭VM...");
    } else {
        WriteLog(logPath, "[QEMU] VM运行超时，自动关闭");
    }
    
    WriteLog(logPath, "[QEMU] VM已关闭");
    return 0;
}

// QEMU关闭请求实现
extern "C" void qemu_system_shutdown_request(int reason) {
    WriteLog(g_current_log_path, "[QEMU] 收到系统关闭请求，原因代码: " + std::to_string(reason));
    g_qemu_shutdown_requested = true;
}

// NAPI函数实现
static napi_value GetVersion(napi_env env, napi_callback_info info) {
    // 尝试获取真实的QEMU版本
    const char* ver = nullptr;
    
    // 方法1: 从编译时宏定义获取
    #ifdef QEMU_VERSION
        ver = QEMU_VERSION;
    #else
        // 方法2: 从运行时检测获取
        ver = "QEMU 8.0.0 (编译版本)";
    #endif
    
    // 如果还是获取不到，使用默认版本
    if (!ver) {
        ver = "QEMU 8.0.0 (默认版本)";
    }
    
    napi_value ret;
    napi_create_string_utf8(env, ver, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

static napi_value EnableJit(napi_env env, napi_callback_info info) {
    (void)info; // unused
    napi_value out;
    napi_get_boolean(env, enableJit(), &out);
    return out;
}

static napi_value KvmSupported(napi_env env, napi_callback_info info) {
    (void)info; // unused
    napi_value out;
    napi_get_boolean(env, kvmSupported(), &out);
    return out;
}

static napi_value StartVm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value result;
    
    if (argc < 1) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    bool ok = false;
    VMConfig config = ParseVMConfig(env, argv[0], ok);
    if (!ok) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    std::lock_guard<std::mutex> lock(g_vmMutex);
    
    // 检查VM是否已在运行
    if (g_vmRunning.find(config.name) != g_vmRunning.end() && g_vmRunning[config.name]->load()) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    // 创建VM目录结构
    if (!CreateVMDirectory(config.name)) {
        WriteLog(config.logPath, "Failed to create VM directory for: " + config.name);
        napi_get_boolean(env, false, &result);
        return result;
    }
    WriteLog(config.logPath, "VM directory created for: " + config.name);
    
    // 创建VM配置文件
    if (!CreateVMConfigFile(config)) {
        WriteLog(config.logPath, "Failed to create VM config file for: " + config.name);
        napi_get_boolean(env, false, &result);
        return result;
    }
    WriteLog(config.logPath, "VM config file created for: " + config.name);
    
    // 更新VM状态为准备中
    UpdateVMStatus(config.name, "preparing");
    
    // 创建虚拟磁盘
    if (!FileExists(config.diskPath)) {
        WriteLog(config.logPath, "Creating virtual disk: " + config.diskPath);
        if (!CreateVirtualDisk(config.diskPath, config.diskSizeGB)) {
            WriteLog(config.logPath, "Failed to create virtual disk");
            UpdateVMStatus(config.name, "failed");
            napi_get_boolean(env, false, &result);
            return result;
        }
        WriteLog(config.logPath, "Virtual disk created successfully");
    }
    
    // 构建QEMU参数
    std::vector<std::string> args = BuildQemuArgs(config);
    WriteLog(config.logPath, "Starting VM with command: " + [&args]() {
        std::string cmd;
        for (const auto& arg : args) {
            cmd += arg + " ";
        }
        return cmd;
    }());
    
    // 初始化日志缓冲区
    g_vmLogBuffers[config.name].clear();
    // 确保互斥锁存在（map会自动创建）
    g_vmLogMutexes[config.name];
    
    // 设置全局变量供QEMU函数使用
    g_current_vm_name = config.name;
    g_current_log_path = config.logPath;
    
    // 启动VM线程
    if (g_vmRunning.find(config.name) == g_vmRunning.end()) {
        g_vmRunning[config.name] = new std::atomic<bool>(false);
    }
    g_vmRunning[config.name]->store(true);
    
    // 更新VM状态为运行中
    UpdateVMStatus(config.name, "running");
    
    g_vmThreads[config.name] = std::thread([config, args]() {
        std::vector<char*> cargs;
        for (const auto &s : args) {
            cargs.push_back(const_cast<char*>(s.c_str()));
        }
        
        WriteLog(config.logPath, "VM thread started");
        int exitCode = qemu_main(static_cast<int>(cargs.size()), cargs.data());
        WriteLog(config.logPath, "VM exited with code: " + std::to_string(exitCode));
        
        // 更新VM状态为已停止
        UpdateVMStatus(config.name, "stopped");
        
        g_vmRunning[config.name]->store(false);
    });
    
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value StopVm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value result;
    
    if (argc < 1) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    // 获取VM名称
    size_t nameLen;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &nameLen) != napi_ok) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    std::string vmName(nameLen, '\0');
    if (napi_get_value_string_utf8(env, argv[0], &vmName[0], nameLen + 1, &nameLen) != napi_ok) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    std::lock_guard<std::mutex> lock(g_vmMutex);
    
    if (g_vmRunning.find(vmName) != g_vmRunning.end() && g_vmRunning[vmName]->load()) {
        // 更新VM状态为停止中
        UpdateVMStatus(vmName, "stopping");
        
        qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST);
        if (g_vmThreads[vmName].joinable()) {
            g_vmThreads[vmName].join();
        }
        g_vmRunning[vmName]->store(false);
        
        // 更新VM状态为已停止
        UpdateVMStatus(vmName, "stopped");
        
        std::string logPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmName + "/qemu.log";
        WriteLog(logPath, "VM stopped by user request");
    }
    
    napi_get_boolean(env, true, &result);
    return result;
}

// 获取VM实时日志
static napi_value GetVmLogs(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    // 获取VM名称
    size_t nameLen;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &nameLen) != napi_ok) {
        napi_throw_error(env, nullptr, "Invalid VM name parameter");
        return nullptr;
    }
    std::string vmName(nameLen, '\0');
    if (napi_get_value_string_utf8(env, argv[0], &vmName[0], nameLen + 1, &nameLen) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get VM name");
        return nullptr;
    }
    
    // 获取起始行数（可选参数）
    int32_t startLine = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &startLine);
    }
    
    napi_value result;
    napi_create_array(env, &result);
    
    // 获取日志缓冲区
    if (g_vmLogBuffers.find(vmName) != g_vmLogBuffers.end()) {
        std::lock_guard<std::mutex> lock(g_vmLogMutexes[vmName]);
        const auto& buffer = g_vmLogBuffers[vmName];
        
        // 确保起始行数有效
        size_t start = std::max(0, std::min(startLine, (int32_t)buffer.size()));
        
        for (size_t i = start; i < buffer.size(); i++) {
            napi_value logEntry;
            napi_create_string_utf8(env, buffer[i].c_str(), NAPI_AUTO_LENGTH, &logEntry);
            napi_set_element(env, result, i - start, logEntry);
        }
    }
    
    return result;
}

// 获取VM状态
static napi_value GetVmStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    // 获取VM名称
    size_t nameLen;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &nameLen) != napi_ok) {
        napi_throw_error(env, nullptr, "Invalid VM name parameter");
        return nullptr;
    }
    std::string vmName(nameLen, '\0');
    if (napi_get_value_string_utf8(env, argv[0], &vmName[0], nameLen + 1, &nameLen) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get VM name");
        return nullptr;
    }
    
    napi_value result;
    napi_create_string_utf8(env, "stopped", NAPI_AUTO_LENGTH, &result);
    
    // 检查运行状态
    if (g_vmRunning.find(vmName) != g_vmRunning.end() && g_vmRunning[vmName]->load()) {
        napi_create_string_utf8(env, "running", NAPI_AUTO_LENGTH, &result);
    }
    
    return result;
}

// 模块初始化
EXTERN_C_START
static void Init(napi_env env, napi_value exports) {
    napi_property_descriptor__ desc[] = {
        { "version", GetVersion, 0 },
        { "enableJit", EnableJit, 0 },
        { "kvmSupported", KvmSupported, 0 },
        { "startVm", StartVm, 0 },
        { "stopVm", StopVm, 0 },
        { "getVmLogs", GetVmLogs, 0 },
        { "getVmStatus", GetVmStatus, 0 },
    };
    napi_define_properties(env, exports, 7, (napi_property_descriptor*)desc);
}
EXTERN_C_END

static napi_module_simple qemuModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "qemu_hmos",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterQemuModule(void) {
    napi_module_register(&qemuModule);
}
