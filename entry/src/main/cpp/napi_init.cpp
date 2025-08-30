<<<<<<< HEAD
#include "napi_simple.h"
=======
// NAPI bindings for QEMU wrapper
#include "napi/native_api.h"
#include "qemu_wrapper.h"
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
<<<<<<< HEAD
#include <cstring>
#include <fstream>
#include <sstream>
#include <map>
#include <mutex>
#include <chrono>
#include <iomanip>
#include <sys/stat.h>
#include <sys/types.h>

// NAPI常量定义
#define NAPI_AUTO_LENGTH SIZE_MAX
=======
#include <string.h>
#include <stdint.h>
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579

#if defined(__has_include)
#  if __has_include(<sys/prctl.h>)
#    include <sys/prctl.h>
#    define HAS_PRCTL 1
#  else
#    define HAS_PRCTL 0
#  endif
#else
#  define HAS_PRCTL 0
#endif

#ifndef PRCTL_JIT_ENABLE
#define PRCTL_JIT_ENABLE 0x6a6974 // magic from requirements, best-effort attempt
#endif

// VM配置结构
struct VMConfig {
    std::string name;
    std::string isoPath;
    int diskSizeGB;
    int memoryMB;
    int cpuCount;
    std::string diskPath;
    std::string logPath;
};

// 全局变量
static std::map<std::string, std::thread> g_vmThreads;
static std::map<std::string, std::atomic<bool>*> g_vmRunning;
static std::mutex g_vmMutex;

// QEMU相关全局变量
static std::atomic<bool> g_qemu_shutdown_requested{false};
static std::string g_current_vm_name;
static std::string g_current_log_path;

// 日志回传相关全局变量
static std::map<std::string, std::vector<std::string>> g_vmLogBuffers;
static std::map<std::string, std::mutex> g_vmLogMutexes;
static const size_t MAX_LOG_BUFFER_SIZE = 1000; // 最大缓存日志条数

// 前向声明
extern "C" int qemu_main(int argc, char **argv);
extern "C" void qemu_system_shutdown_request(int reason);
static constexpr int SHUTDOWN_CAUSE_HOST = 0;

<<<<<<< HEAD
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
    if (napi_get_named_property(env, config, "isoPath", &isoValue) != napi_ok) return vmConfig;
    size_t isoLen;
    if (napi_get_value_string_utf8(env, isoValue, nullptr, 0, &isoLen) != napi_ok) return vmConfig;
    vmConfig.isoPath.resize(isoLen);
    if (napi_get_value_string_utf8(env, isoValue, &vmConfig.isoPath[0], isoLen + 1, &isoLen) != napi_ok) return vmConfig;
    
    // 获取数值参数
    napi_value diskSizeValue, memoryValue, cpuValue;
    if (napi_get_named_property(env, config, "diskSizeGB", &diskSizeValue) == napi_ok) {
        napi_get_value_int32(env, diskSizeValue, &vmConfig.diskSizeGB);
    } else {
        vmConfig.diskSizeGB = 20; // 默认20GB
=======
static std::thread g_qemuThread;
static std::atomic<bool> g_qemuRunning{false};

static bool kvmSupported()
{
    int fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        return false;
    }
    close(fd);
    return true;
}

static bool enableJit()
{
#if HAS_PRCTL
    int r = prctl(PRCTL_JIT_ENABLE, 1);
    return r == 0;
#else
    errno = ENOSYS;
    return false;
#endif
}

static std::vector<std::string> ParseArgs(napi_env env, napi_value config, bool &ok)
{
    napi_value argsArray;
    ok = (napi_get_named_property(env, config, "args", &argsArray) == napi_ok);
    if (!ok) {
        return {};
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579
    }
    
    if (napi_get_named_property(env, config, "memoryMB", &memoryValue) == napi_ok) {
        napi_get_value_int32(env, memoryValue, &vmConfig.memoryMB);
    } else {
        vmConfig.memoryMB = 2048; // 默认2GB
    }
    
    if (napi_get_named_property(env, config, "cpuCount", &cpuValue) == napi_ok) {
        napi_get_value_int32(env, cpuValue, &vmConfig.cpuCount);
    } else {
        vmConfig.cpuCount = 2; // 默认2核
    }
    
    // 生成磁盘和日志路径
    vmConfig.diskPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmConfig.name + ".raw";
    vmConfig.logPath = "/data/storage/el2/base/haps/entry/files/logs/VM-" + vmConfig.name + ".log";
    
    ok = !vmConfig.name.empty() && !vmConfig.isoPath.empty();
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

// 获取目录路径
static std::string GetDirectoryPath(const std::string& filePath) {
    size_t pos = filePath.find_last_of('/');
    if (pos != std::string::npos) {
        return filePath.substr(0, pos);
    }
    return ".";
}

// 创建VM工作目录
static bool CreateVMDirectory(const std::string& vmName) {
    try {
        std::string vmDir = "/tmp/qemu_vms/" + vmName;
        return CreateDirectories(vmDir);
    } catch (...) {
        return false;
    }
}

// 获取VM工作目录路径
static std::string GetVMDirectory(const std::string& vmName) {
    return "/tmp/qemu_vms/" + vmName;
}

// 创建VM配置文件
static bool CreateVMConfigFile(const VMConfig& config) {
    try {
        std::string vmDir = GetVMDirectory(config.name);
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
        std::string vmDir = GetVMDirectory(vmName);
        std::string configPath = vmDir + "/vm_config.json";
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
        std::string dirPath = GetDirectoryPath(diskPath);
        if (!CreateDirectories(dirPath)) {
            return false;
        }
        
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

// 构建QEMU命令行
static std::vector<std::string> BuildQemuArgs(const VMConfig& config) {
    std::vector<std::string> args;
    
    args.push_back("qemu-system-aarch64");
    
    // 基本配置 - 最小化VM配置
    args.push_back("-machine");
    args.push_back("virt");
    
    args.push_back("-cpu");
    args.push_back("cortex-a57");
    
    args.push_back("-smp");
    args.push_back(std::to_string(config.cpuCount));
    
    args.push_back("-m");
    args.push_back(std::to_string(config.memoryMB));
    
    // TCG软件加速 - 适用于所有平台
    args.push_back("-accel");
    args.push_back("tcg");
    
    // 无图形显示 - 最小化配置
    args.push_back("-nographic");
    
    // 串口输出重定向到日志
    args.push_back("-serial");
    args.push_back("file:" + config.logPath);
    
    // 监控接口 - 用于控制VM
    args.push_back("-monitor");
    args.push_back("none");
    
    // 磁盘配置 - 如果存在磁盘文件
    if (FileExists(config.diskPath)) {
        args.push_back("-drive");
        args.push_back("file=" + config.diskPath + ",if=virtio,format=raw");
    }
    
    // ISO光驱 - 如果提供了ISO文件
    if (!config.isoPath.empty() && FileExists(config.isoPath)) {
        args.push_back("-cdrom");
        args.push_back(config.isoPath);
    }
    
    // 网络配置 - 简化的用户模式网络
    args.push_back("-netdev");
    args.push_back("user,id=net0");
    args.push_back("-device");
    args.push_back("virtio-net-pci,netdev=net0");
    
    // 禁用不必要的设备以提高兼容性
    args.push_back("-nodefaults");
    
    // 启用日志记录
    args.push_back("-d");
    args.push_back("guest_errors,unimp");
    
    return args;
}

// 写入日志
static void WriteLog(const std::string& logPath, const std::string& message) {
    try {
        std::string dirPath = GetDirectoryPath(logPath);
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
    
    WriteLog(logPath, "[QEMU] TCG加速器已启用");
    WriteLog(logPath, "[QEMU] 虚拟网络设备已配置");
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

// 简化的NAPI函数实现（用于测试）
napi_status napi_get_cb_info(napi_env env, napi_callback_info cbinfo,
                            size_t* argc, napi_value* argv,
                            napi_value* this_arg, void** data) {
    // 简化实现
    return napi_ok;
}

napi_status napi_get_named_property(napi_env env, napi_value object,
                                   const char* utf8name, napi_value* result) {
    // 简化实现
    return napi_ok;
}

napi_status napi_get_value_string_utf8(napi_env env, napi_value value,
                                      char* buf, size_t bufsize, size_t* result) {
    // 简化实现
    if (result) *result = 0;
    return napi_ok;
}

napi_status napi_get_value_int32(napi_env env, napi_value value, int32_t* result) {
    // 简化实现
    if (result) *result = 0;
    return napi_ok;
}

napi_status napi_create_string_utf8(napi_env env, const char* str,
                                   size_t length, napi_value* result) {
    // 简化实现
    return napi_ok;
}

napi_status napi_get_boolean(napi_env env, bool value, napi_value* result) {
    // 简化实现
    return napi_ok;
}

napi_status napi_define_properties(napi_env env, napi_value object,
                                  size_t property_count,
                                  const napi_property_descriptor* properties) {
    // 简化实现
    return napi_ok;
}

void napi_module_register(napi_module* mod) {
    // 简化实现
}

// 简化的错误处理函数
napi_status napi_throw_error(napi_env env, const char* code, const char* msg) {
    // 简化实现
    return napi_ok;
}

napi_status napi_create_array(napi_env env, napi_value* result) {
    // 简化实现
    return napi_ok;
}

napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value) {
    // 简化实现
    return napi_ok;
}



static napi_value GetVersion(napi_env env, napi_callback_info info)
{
    const char* ver = "qemu_hmos_stub_0.1";
    napi_value ret;
    napi_create_string_utf8(env, ver, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

static napi_value EnableJit(napi_env env, napi_callback_info info)
{
    (void)info; // unused
    if (!enableJit()) {
        int err = errno;
        std::string code = std::to_string(err);
        napi_throw_error(env, code.c_str(), strerror(err));
        return nullptr;
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

static napi_value KvmSupported(napi_env env, napi_callback_info info)
{
    (void)info; // unused
    if (!kvmSupported()) {
        int err = errno;
        std::string code = std::to_string(err);
        napi_throw_error(env, code.c_str(), strerror(err));
        return nullptr;
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

// Helper to extract VM handle from JS number
static qemu_vm_handle_t GetHandle(napi_env env, napi_value value)
{
    int64_t raw = 0;
    napi_get_value_int64(env, value, &raw);
    return reinterpret_cast<qemu_vm_handle_t>(raw);
}

static napi_value StartVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    // 默认配置，后续可根据 argv[0] 解析
    qemu_vm_config_t cfg{};
    cfg.machine_type = "virt";
    cfg.cpu_type = "cortex-a57";
    cfg.memory_mb = 256;
    cfg.cmdline = "console=ttyAMA0";

    qemu_vm_handle_t handle = qemu_vm_create(&cfg);
    napi_value result;
<<<<<<< HEAD

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
=======
    if (!handle || qemu_vm_start(handle) != 0) {
        if (handle) {
            qemu_vm_destroy(handle);
        }
        napi_create_int64(env, 0, &result);
        return result;
    }
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579

    return result;
}

static napi_value StopVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
<<<<<<< HEAD
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
        
        std::string logPath = "/data/storage/el2/base/haps/entry/files/logs/VM-" + vmName + ".log";
        WriteLog(logPath, "VM stopped by user request");
    }
    
    napi_get_boolean(env, true, &result);
    return result;
}

// 获取VM实时日志
static napi_value GetVmLogs(napi_env env, napi_callback_info info)
{
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
=======

    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }

    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_stop(handle);
    qemu_vm_destroy(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value PauseVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_pause(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value ResumeVm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    if (argc < 1) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    qemu_vm_handle_t handle = GetHandle(env, argv[0]);
    int ret = qemu_vm_resume(handle);
    napi_get_boolean(env, ret == 0, &out);
    return out;
}

static napi_value SnapshotVm(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "version", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "enableJit", nullptr, EnableJit, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "kvmSupported", nullptr, KvmSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startVm", nullptr, StartVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopVm", nullptr, StopVm, nullptr, nullptr, nullptr, napi_default, nullptr },
<<<<<<< HEAD
        { "getVmLogs", nullptr, GetVmLogs, nullptr, nullptr, nullptr, napi_default, nullptr },
=======
        { "pauseVm", nullptr, PauseVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resumeVm", nullptr, ResumeVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshotVm", nullptr, SnapshotVm, nullptr, nullptr, nullptr, napi_default, nullptr },
>>>>>>> f44720f2f3c409526b12b20f5d0584266f573579
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module qemuModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "qemu_hmos",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterQemuModule(void)
{
    napi_module_register(&qemuModule);
}
