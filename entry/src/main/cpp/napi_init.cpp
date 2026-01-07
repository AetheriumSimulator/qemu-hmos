#include "napi_compat.h"
#include "qemu_wrapper.h"
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <fstream>
#include <sstream>
#include <setjmp.h>
#include <map>
#include <mutex>
#include <chrono>
#include <iomanip>
#include <sys/stat.h>
#include <sys/types.h>
#include <dlfcn.h>
#include <cstdio>

#if defined(__OHOS__)
#include <hilog/log.h>
// NativeWindow / NativeBuffer: XComponent surface 直绘
#include <native_window/external_window.h>
#include <native_buffer/native_buffer.h>
// 定义日志 domain 和 tag
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xA00000
#define LOG_TAG "QEMU_NAPI"

// 早期初始化已禁用 - 避免与 HarmonyOS 运行时冲突
// __attribute__((constructor(101))) static void qemu_so_loaded(void) {
//     OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, ">>> libqemu_hmos.so LOADED <<<");
// }
#endif
#include <vector>

// ======================================================================================
// HarmonyOS 重要约束：
// - QEMU 作为 in-process shared library 运行时，如果内部调用 exit(1)/_exit/_Exit，会被 appspawn 判定为
//   非法退出（Unexpected call: exit(1)）从而 SIGABRT 杀死整个应用进程。
//
// 处理策略：
// - 在 VM 线程进入 QEMU 前，启用 thread_local 的 setjmp/longjmp 兜底。
// - 通过符号劫持拦截 exit/_exit/_Exit，把“进程退出”转换成“VM 线程失败返回码”。
// ======================================================================================
static thread_local bool g_tls_in_qemu = false;
static thread_local jmp_buf g_tls_exit_jmp;
static thread_local int g_tls_exit_code = 0;
// 用于生成运行期唯一的设备ID（例如 rng、tpm），防止多次启动在同一进程内发生 ID 冲突
static std::atomic<uint32_t> g_id_suffix_counter {0};

static void CallRealExit(int status)
{
    // 仅在非 QEMU 线程兜底调用，正常情况下我们不应触发真实 exit。
    using ExitFn = void (*)(int);
    static ExitFn realExit = nullptr;
    if (!realExit) {
        realExit = reinterpret_cast<ExitFn>(dlsym(RTLD_NEXT, "exit"));
    }
    if (realExit) {
        realExit(status);
    }
    // 如果获取不到真实 exit，则卡死避免继续执行未知状态
    for (;;) {
        pause();
    }
}

extern "C" __attribute__((noreturn)) void exit(int status)
{
    if (g_tls_in_qemu) {
        g_tls_exit_code = status;
        longjmp(g_tls_exit_jmp, 1);
    }
    CallRealExit(status);
}

extern "C" __attribute__((noreturn)) void _exit(int status)
{
    if (g_tls_in_qemu) {
        g_tls_exit_code = status;
        longjmp(g_tls_exit_jmp, 1);
    }
    // 尝试调用真实 _exit
    using ExitFn = void (*)(int);
    static ExitFn realExit = nullptr;
    if (!realExit) {
        realExit = reinterpret_cast<ExitFn>(dlsym(RTLD_NEXT, "_exit"));
    }
    if (realExit) {
        realExit(status);
    }
    for (;;) {
        pause();
    }
}

extern "C" __attribute__((noreturn)) void _Exit(int status)
{
    if (g_tls_in_qemu) {
        g_tls_exit_code = status;
        longjmp(g_tls_exit_jmp, 1);
    }
    // 尝试调用真实 _Exit
    using ExitFn = void (*)(int);
    static ExitFn realExit = nullptr;
    if (!realExit) {
        realExit = reinterpret_cast<ExitFn>(dlsym(RTLD_NEXT, "_Exit"));
    }
    if (realExit) {
        realExit(status);
    }
    for (;;) {
        pause();
    }
}

extern "C" __attribute__((noreturn)) void abort(void)
{
    // QEMU 内部（或其依赖）可能通过 abort() 终止进程；在 QEMU 线程内将其转换为 longjmp，
    // 避免被 appspawn 视为异常退出而杀掉整个应用。
    if (g_tls_in_qemu) {
        // 134 是常见的 “Aborted” 退出码（SIGABRT）
        g_tls_exit_code = 134;
        longjmp(g_tls_exit_jmp, 1);
    }
    using AbortFn = void (*)(void);
    static AbortFn realAbort = nullptr;
    if (!realAbort) {
        realAbort = reinterpret_cast<AbortFn>(dlsym(RTLD_NEXT, "abort"));
    }
    if (realAbort) {
        realAbort();
    }
    for (;;) {
        pause();
    }
}

// 前向声明：qemu_wrapper.cpp 中定义的 C 函数
extern "C" {
    bool qemu_pause_vm_by_name(const char* vm_name);
    bool qemu_resume_vm_by_name(const char* vm_name);
    bool qemu_create_snapshot_by_name(const char* vm_name, const char* snapshot_name);
    bool qemu_restore_snapshot_by_name(const char* vm_name, const char* snapshot_name);
    int qemu_list_snapshots_by_name(const char* vm_name, char** out_snapshots, int max_count);
    bool qemu_delete_snapshot_by_name(const char* vm_name, const char* snapshot_name);
}

// macOS兼容性处理
#ifdef __APPLE__
#include <sys/sysctl.h>
#else
#include <sys/prctl.h>
#include <sys/ioctl.h>
#include <linux/kvm.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <signal.h>
#endif

// NAPI常量定义（如官方头已定义则不重复定义）
#ifndef NAPI_AUTO_LENGTH
#  include <cstdint>
#  define NAPI_AUTO_LENGTH SIZE_MAX
#endif

// 安全获取 NAPI 字符串为 std::string（确保为 NUL 终止分配 len+1 缓冲区，避免越界）
static bool NapiGetStringUtf8(napi_env env, napi_value value, std::string& out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::vector<char> buf(len + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len) != napi_ok) {
        return false;
    }
    out.assign(buf.data(), len);
    return true;
}
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }

// 全局控制台回调
static napi_threadsafe_function g_consoleCallback = nullptr;

// 前向声明：CaptureQemuOutput 里需要用它把 QEMU 的 stdout/stderr 打进同一套 QEMU_CORE 日志里
static void HilogPrint(const std::string& message);

// ----------------------------- Serial TCP bridge (QEMU -serial tcp:127.0.0.1:4321,server,nowait) -----------------------------
// 现状说明：
// - 我们启动 QEMU 时把串口输出放到 TCP 4321 server 上。
// - 但 ArkTS 的 ConsoleWindow 只注册了 consoleCallback，并不会自动去连 4321。
// - 结果就是“串口没有透传到 ArkTS”，看起来像没有输出。
// 这里在 Native 层自动连接 4321，并把收到的数据通过 g_consoleCallback 推给 ArkTS。
static std::thread g_serial_thread;
static std::atomic<bool> g_serial_running(false);
static int g_serial_fd = -1;
static std::mutex g_serial_mtx;

static void SerialCloseLocked()
{
    if (g_serial_fd != -1) {
        close(g_serial_fd);
        g_serial_fd = -1;
    }
}

static void SerialEmitToJs(const std::string& s)
{
    if (!g_consoleCallback) return;
    std::string* msg = new std::string(s);
    napi_call_threadsafe_function(g_consoleCallback, msg, napi_tsfn_nonblocking);
}

static bool SerialTryConnectLocked()
{
    if (g_serial_fd != -1) return true;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;

    // 超时，避免阻塞线程
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 200 * 1000; // 200ms
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(4321);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
            "[TTY] connect(127.0.0.1:4321) failed errno=%{public}d (%{public}s)",
            errno, strerror(errno));
        close(fd);
        return false;
    }

    g_serial_fd = fd;
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "[TTY] connected to 127.0.0.1:4321");
    return true;
}

static void SerialBridgeThread()
{
    // 反复尝试连接，直到成功或被停止
    SerialEmitToJs("[TTY] connecting to 127.0.0.1:4321 ...\n");

    while (g_serial_running.load()) {
        {
            std::lock_guard<std::mutex> lk(g_serial_mtx);
            if (!SerialTryConnectLocked()) {
                // not ready yet
            }
        }

        int fd = -1;
        {
            std::lock_guard<std::mutex> lk(g_serial_mtx);
            fd = g_serial_fd;
        }

        if (fd == -1) {
            usleep(300 * 1000);
            continue;
        }

        // 已连接：读数据并推给 JS
        char buf[4096];
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n > 0) {
            SerialEmitToJs(std::string(buf, (size_t)n));
            continue;
        }

        // timeout or disconnected
        if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
            std::lock_guard<std::mutex> lk(g_serial_mtx);
            SerialCloseLocked();
            SerialEmitToJs("[TTY] disconnected, retrying...\n");
        }
    }

    {
        std::lock_guard<std::mutex> lk(g_serial_mtx);
        SerialCloseLocked();
    }
}

static void SerialStart()
{
    if (g_serial_running.load()) return;
    g_serial_running.store(true);
    g_serial_thread = std::thread(SerialBridgeThread);
}

static void SerialStop()
{
    if (!g_serial_running.load()) return;
    g_serial_running.store(false);
    {
        std::lock_guard<std::mutex> lk(g_serial_mtx);
        SerialCloseLocked();
    }
    if (g_serial_thread.joinable()) g_serial_thread.join();
}

// JS 回调包装器
static void ConsoleJsCallback(napi_env env, napi_value js_cb, void* context, void* data) {
    std::string* msg = static_cast<std::string*>(data);
    if (!msg) return;
    
    napi_value undefined, js_string;
    napi_get_undefined(env, &undefined);
    napi_create_string_utf8(env, msg->c_str(), msg->length(), &js_string);
    napi_call_function(env, undefined, js_cb, 1, &js_string, nullptr);
    
    delete msg;
}

// 捕获 stdout/stderr 并重定向到 hilog
class CaptureQemuOutput {
public:
    explicit CaptureQemuOutput(const std::string& vmDir) : stdout_log_fd(-1), stderr_log_fd(-1) {
        // 创建管道
        if (pipe(stdout_pipe) == -1 || pipe(stderr_pipe) == -1 || pipe(stdin_pipe) == -1) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Failed to create pipes");
            return;
        }

        // 保存原始文件描述符
        stdout_backup = dup(STDOUT_FILENO);
        stderr_backup = dup(STDERR_FILENO);
        stdin_backup = dup(STDIN_FILENO);

        // 重定向 stdout/stderr 到管道写端
        if (dup2(stdout_pipe[1], STDOUT_FILENO) == -1 || dup2(stderr_pipe[1], STDERR_FILENO) == -1) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Failed to dup2 stdout/stderr");
            return;
        }
        
        // 重定向 stdin 到管道读端
        if (dup2(stdin_pipe[0], STDIN_FILENO) == -1) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Failed to dup2 stdin");
            return;
        }

        // 额外：把 QEMU 的 stdout/stderr 同步落盘到 VM 目录（用于诊断导出）
        // 注意：不要写到 qemu.log（该文件会被 QEMU -D 打开并可能清空），我们单独写 stdout/stderr 文件。
        if (!vmDir.empty()) {
            const std::string outPath = vmDir + "/qemu_stdout.log";
            const std::string errPath = vmDir + "/qemu_stderr.log";
            stdout_log_fd = open(outPath.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
            stderr_log_fd = open(errPath.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
            if (stdout_log_fd == -1 || stderr_log_fd == -1) {
                OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                             "Failed to open stdout/stderr log files in vmDir (errno=%{public}d)",
                             errno);
            }
        }

        // 启动读取线程
        running = true;
        stdout_thread = std::thread(&CaptureQemuOutput::ReadThread, this, stdout_pipe[0], stdout_log_fd, "QEMU_STDOUT");
        stderr_thread = std::thread(&CaptureQemuOutput::ReadThread, this, stderr_pipe[0], stderr_log_fd, "QEMU_STDERR");
        
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "QEMU output capture started");
    }

    ~CaptureQemuOutput() {
        running = false;
        
        // 恢复原始文件描述符
        dup2(stdout_backup, STDOUT_FILENO);
        dup2(stderr_backup, STDERR_FILENO);
        dup2(stdin_backup, STDIN_FILENO);
        
        close(stdout_backup);
        close(stderr_backup);
        close(stdin_backup);
        
        close(stdout_pipe[1]); // 关闭写端，这将导致读端 EOF
        close(stderr_pipe[1]);
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);

        if (stdout_thread.joinable()) stdout_thread.join();
        if (stderr_thread.joinable()) stderr_thread.join();
        
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);

        if (stdout_log_fd != -1) {
            close(stdout_log_fd);
            stdout_log_fd = -1;
        }
        if (stderr_log_fd != -1) {
            close(stderr_log_fd);
            stderr_log_fd = -1;
        }
        
        // 释放回调
        if (g_consoleCallback) {
            napi_release_threadsafe_function(g_consoleCallback, napi_tsfn_abort);
            g_consoleCallback = nullptr;
        }
    }
    
    void WriteToStdin(const std::string& data) {
        if (stdin_pipe[1] != -1) {
            write(stdin_pipe[1], data.c_str(), data.length());
            // 不需要 fsync，管道通常是无缓冲的或行缓冲的
        }
    }

private:
    int stdout_pipe[2];
    int stderr_pipe[2];
    int stdin_pipe[2];
    int stdout_backup;
    int stderr_backup;
    int stdin_backup;
    std::thread stdout_thread;
    std::thread stderr_thread;
    std::atomic<bool> running;
    int stdout_log_fd;
    int stderr_log_fd;

    void ReadThread(int fd, int logFd, const char* tag) {
        char buffer[1024];
        ssize_t n;
        while (running) {
            n = read(fd, buffer, sizeof(buffer) - 1);
            if (n > 0) {
                // 先把原始输出落盘（保留换行符/原始内容）
                if (logFd != -1) {
                    (void)write(logFd, buffer, static_cast<size_t>(n));
                }
                buffer[n] = '\0';
                
                // 发送给 JS (需要在 hilog 之前，保留换行符)
                if (g_consoleCallback) {
                    std::string* msg = new std::string(buffer);
                    napi_call_threadsafe_function(g_consoleCallback, msg, napi_tsfn_nonblocking);
                }
                
                // 移除换行符，HilogPrint 会自动按行处理
                if (buffer[n - 1] == '\n') buffer[n - 1] = '\0';
                // 关键修复：用 QEMU_CORE 统一日志出口，确保你抓的 hilog.log 一定能看到
                HilogPrint(std::string("QEMU: [") + tag + "] " + buffer);
            } else if (n == 0) {
                break; // EOF
            } else {
                if (errno != EAGAIN && errno != EINTR) break;
            }
        }
    }
};

// 全局唯一实例
static std::unique_ptr<CaptureQemuOutput> g_logCapture;

// JIT权限常量
#ifndef PRCTL_JIT_ENABLE
#define PRCTL_JIT_ENABLE 0x6a6974
#endif

// 日志缓冲区大小限制
constexpr size_t MAX_LOG_BUFFER_SIZE = 1000;

// VM配置结构
struct VMConfig {
    std::string name;
    std::string osType;          // 来宾系统类型：Windows / Linux / ...
    std::string archType;        // 架构类型：aarch64, x86_64, i386
    std::string isoPath;
    int diskSizeGB;
    int memoryMB;
    int cpuCount;
    std::string cpuModel;        // CPU 型号（可选，不填则使用默认策略）
    std::string diskPath;
    std::string logPath;
    std::string accel;
    std::string display;
    bool nographic;
    std::string vmDir;
    std::string sharedDir;       // 共享目录路径（virtio-9p）
    std::string efiFirmware;     // UEFI 固件路径
    std::string qemuDataDir;     // QEMU数据目录（包含keymaps，由ArkTS KeymapsManager提供）
    bool keymapsAvailable;       // ArkTS 是否已确认 keymaps 存在
    bool installMode;            // ArkTS 启动上下文：安装模式（aarch64 固件阶段更保守的硬件兜底）
    // 高级硬件配置（由 ArkTS 创建向导传入）
    std::string machine;         // 机器类型（如 virt、raspi3b）
    std::string displayDevice;   // 显卡设备（virtio-gpu、ramfb、none）
    std::string networkDevice;   // 网卡设备（virtio-net、e1000、rtl8139、none）
    std::string audioDevice;     // 声卡设备（hda、ac97、none）
};

// VM状态管理
static std::map<std::string, std::thread> g_vmThreads;
static std::map<std::string, std::atomic<bool>*> g_vmRunning;
static std::map<std::string, std::vector<std::string>> g_vmLogBuffers;
static std::map<std::string, std::mutex> g_vmLogMutexes;
static std::mutex g_vmMutex;

// 全局变量用于控制VM运行状态
// 使用显式构造避免静态初始化问题
static std::atomic<bool> g_qemu_shutdown_requested(false);
static std::string g_current_vm_name;
static std::string g_current_log_path;
static std::string g_current_arch_type;  // 当前 VM 的架构类型 (aarch64, x86_64, i386)

// VM 启动错误码
enum class VmStartError {
    SUCCESS = 0,
    CORE_LIB_MISSING = 1,
    INIT_FAILED = 2,
    LOOP_CRASHED = 3,
    DISK_CREATE_FAILED = 4,
    CONFIG_FAILED = 5,
    ALREADY_RUNNING = 6
};

// Promise 回调数据结构
struct VmStartCallbackData {
    napi_env env;
    napi_deferred deferred;
    std::string vmName;
    VmStartError error;
    int exitCode;
    std::string errorMessage;
};

// 存储每个 VM 的 threadsafe function 和 deferred
struct VmStartContext {
    napi_threadsafe_function tsfn;
    napi_deferred deferred;
    napi_env env;
};
static std::map<std::string, VmStartContext> g_vmStartCallbacks;

// 前向声明
extern "C" int qemu_main(int argc, char **argv);
extern "C" void qemu_system_shutdown_request(int reason);
static constexpr int SHUTDOWN_CAUSE_HOST = 0;

// 前向声明 - 日志函数
static void HilogPrint(const std::string& message);
static void WriteLog(const std::string& logPath, const std::string& message);

// RDP客户端管理
static std::map<std::string, rdp_client_handle_t> g_rdp_clients;
static std::mutex g_rdp_mutex;

// 检测KVM支持
static bool kvmSupported() {
    // 检查KVM设备文件是否存在
    int fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        return false;
    }
    
    // 检查KVM版本
    int kvm_version = ioctl(fd, KVM_GET_API_VERSION, 0);
    if (kvm_version < 0) {
        close(fd);
        return false;
    }
    
    // 检查KVM能力
    int ret = ioctl(fd, KVM_CHECK_EXTENSION, KVM_CAP_USER_MEMORY);
    if (ret <= 0) {
        close(fd);
        return false;
    }
    
    close(fd);
    return true;
}

// JIT 探测/启用：
// 旧实现曾尝试通过 prctl(PRCTL_JIT_ENABLE) 走 syscall 探测/启用。
// 现在改为 ArkTS 侧通过权限系统探测：
// `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`
// 因此 Native 侧不再做 syscall 探测，避免“开发阶段无意义”的绕路与兼容性风险。
static bool enableJit() {
    return false;
}

// 获取设备能力信息 + 常见机器类型列表
static napi_value GetDeviceCapabilities(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);

    // KVM 支持
    bool kvm_supported = kvmSupported();
    napi_value kvm_value;
    napi_get_boolean(env, kvm_supported, &kvm_value);
    napi_set_named_property(env, result, "kvmSupported", kvm_value);

    // JIT 支持
    // JIT 权限/可用性由 ArkTS 侧通过权限系统探测（ALLOW_WRITABLE_CODE_MEMORY）
    bool jit_supported = false;
    napi_value jit_value;
    napi_get_boolean(env, jit_supported, &jit_value);
    napi_set_named_property(env, result, "jitSupported", jit_value);

    // 内存信息（字节数）
    long pages = sysconf(_SC_PHYS_PAGES);
    long page_size = sysconf(_SC_PAGE_SIZE);
    long total_memory = pages * page_size;

    napi_value memory_value;
    napi_create_int64(env, total_memory, &memory_value);
    napi_set_named_property(env, result, "totalMemory", memory_value);

    // CPU 核心数
    long cpu_cores = sysconf(_SC_NPROCESSORS_ONLN);
    napi_value cores_value;
    napi_create_int64(env, cpu_cores, &cores_value);
    napi_set_named_property(env, result, "cpuCores", cores_value);

    // 常见 aarch64 机器类型列表
    // 这里使用当前构建中实际使用的一组安全机器类型，后续可以扩展为直接从 QMP query-machines 读取。
    napi_value machines_array;
    napi_create_array(env, &machines_array);

    auto append_machine = [&](uint32_t index,
                              const char* id,
                              const char* name,
                              const char* desc) {
        napi_value mobj;
        napi_create_object(env, &mobj);

        napi_value vid;
        napi_create_string_utf8(env, id, NAPI_AUTO_LENGTH, &vid);
        napi_set_named_property(env, mobj, "id", vid);

        napi_value vname;
        napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &vname);
        napi_set_named_property(env, mobj, "name", vname);

        napi_value vdesc;
        napi_create_string_utf8(env, desc, NAPI_AUTO_LENGTH, &vdesc);
        napi_set_named_property(env, mobj, "desc", vdesc);

        napi_set_element(env, machines_array, index, mobj);
    };

    append_machine(0, "virt",       "virt (推荐)",           "通用 ARM 虚拟机平台，性能与兼容性最佳");
    append_machine(1, "virt-2.12",  "virt-2.12",             "virt 2.12 兼容版本，适合部分旧系统");
    append_machine(2, "vexpress-a15","vexpress-a15",         "ARM Versatile Express A15 开发板");
    append_machine(3, "vexpress-a9","vexpress-a9",           "ARM Versatile Express A9 开发板");
    append_machine(4, "raspi3b",    "Raspberry Pi 3B",       "树莓派 3B 模拟");
    append_machine(5, "sbsa-ref",   "SBSA 参考平台",         "适合测试通用 ARM 服务器软件");

    napi_set_named_property(env, result, "machines", machines_array);

    return result;
}

// ============================================================================
// 设备扫描器：异步版本，不阻塞主线程
// ============================================================================

// 全局缓存：扫描结果
static std::string g_cached_devices_json;
static bool g_devices_scanned = false;
static std::mutex g_scan_mutex;

// 异步工作上下文
struct ScanWorkContext {
    napi_async_work work;
    napi_deferred deferred;
    bool success;
    std::string result_json;
    std::string error_msg;
};

// 在工作线程中执行扫描（不能调用 NAPI）
static void ExecuteScanWork(napi_env env, void* data) {
    (void)env;  // 工作线程中不能使用 env
    auto* ctx = static_cast<ScanWorkContext*>(data);
    
    HilogPrint("QEMU: ExecuteScanWork - Starting in worker thread...");
    
    // 检查缓存
    {
        std::lock_guard<std::mutex> lock(g_scan_mutex);
        if (g_devices_scanned && !g_cached_devices_json.empty()) {
            ctx->success = true;
            ctx->result_json = g_cached_devices_json;
            HilogPrint("QEMU: ExecuteScanWork - Using cached results");
            return;
        }
    }
    
    // 由于 QEMU 库在 HarmonyOS 上的线程限制，
    // 我们无法在工作线程中安全地启动 QEMU 实例。
    // 因此，返回一个基于 qemu-system-aarch64 文档的设备列表。
    // 用户可以在创建 VM 后通过 probeQemuDevices() 获取实际支持的设备。
    
    // 构建设备列表 JSON（基于 QEMU 9.x for aarch64 的常见设备）
    std::string json = R"({
        "return": [
            {"name": "virtio-gpu-pci", "parent": "virtio-gpu-pci-base"},
            {"name": "virtio-gpu-gl-pci", "parent": "virtio-gpu-pci-base"},
            {"name": "ramfb", "parent": "device"},
            {"name": "bochs-display", "parent": "device"},
            {"name": "virtio-vga", "parent": "virtio-gpu-device"},
            {"name": "virtio-vga-gl", "parent": "virtio-gpu-device"},
            {"name": "qxl-vga", "parent": "pci-device"},
            {"name": "VGA", "parent": "pci-device"},
            {"name": "cirrus-vga", "parent": "pci-device"},
            {"name": "secondary-vga", "parent": "device"},
            {"name": "virtio-net-pci", "parent": "virtio-net-pci-base"},
            {"name": "virtio-net-pci-non-transitional", "parent": "virtio-net-pci-base"},
            {"name": "e1000", "parent": "pci-device"},
            {"name": "e1000e", "parent": "pci-device"},
            {"name": "e1000-82544gc", "parent": "e1000"},
            {"name": "e1000-82545em", "parent": "e1000"},
            {"name": "rtl8139", "parent": "pci-device"},
            {"name": "ne2k_pci", "parent": "pci-device"},
            {"name": "pcnet", "parent": "pci-device"},
            {"name": "vmxnet3", "parent": "pci-device"},
            {"name": "usb-net", "parent": "usb-device"},
            {"name": "ich9-intel-hda", "parent": "pci-device"},
            {"name": "intel-hda", "parent": "pci-device"},
            {"name": "hda-duplex", "parent": "hda-audio"},
            {"name": "hda-micro", "parent": "hda-audio"},
            {"name": "hda-output", "parent": "hda-audio"},
            {"name": "AC97", "parent": "pci-device"},
            {"name": "es1370", "parent": "pci-device"},
            {"name": "sb16", "parent": "isa-device"},
            {"name": "adlib", "parent": "isa-device"},
            {"name": "gus", "parent": "isa-device"},
            {"name": "cs4231a", "parent": "isa-device"},
            {"name": "usb-audio", "parent": "usb-device"},
            {"name": "virtio-sound-pci", "parent": "virtio-pci"},
            {"name": "virtio-blk-pci", "parent": "virtio-blk-pci-base"},
            {"name": "virtio-scsi-pci", "parent": "virtio-scsi-pci-base"},
            {"name": "nvme", "parent": "pci-device"},
            {"name": "usb-storage", "parent": "usb-device"},
            {"name": "virtio-serial-pci", "parent": "virtio-pci"},
            {"name": "usb-kbd", "parent": "usb-device"},
            {"name": "usb-mouse", "parent": "usb-device"},
            {"name": "usb-tablet", "parent": "usb-device"},
            {"name": "virtio-keyboard-pci", "parent": "virtio-pci"},
            {"name": "virtio-mouse-pci", "parent": "virtio-pci"},
            {"name": "virtio-tablet-pci", "parent": "virtio-pci"},
            {"name": "pci-bridge", "parent": "base-pci-bridge"},
            {"name": "pcie-root-port", "parent": "pcie-port"},
            {"name": "virtio-balloon-pci", "parent": "virtio-pci"},
            {"name": "virtio-rng-pci", "parent": "virtio-pci"},
            {"name": "qemu-xhci", "parent": "pci-device"},
            {"name": "nec-usb-xhci", "parent": "pci-device"},
            {"name": "ich9-usb-ehci1", "parent": "pci-device"},
            {"name": "ich9-usb-uhci1", "parent": "pci-device"},
            {"name": "usb-ehci", "parent": "pci-device"},
            {"name": "usb-host", "parent": "usb-device"}
        ],
        "source": "static-list",
        "note": "基于 QEMU 9.x aarch64 文档的设备列表，实际可用设备需要测试"
    })";
    
    ctx->success = true;
    ctx->result_json = json;
    
    // 缓存结果
    {
        std::lock_guard<std::mutex> lock(g_scan_mutex);
        g_cached_devices_json = json;
        g_devices_scanned = true;
    }
    
    HilogPrint("QEMU: ExecuteScanWork - Returned static device list");
}

// 在主线程中完成（可以调用 NAPI）
static void CompleteScanWork(napi_env env, napi_status status, void* data) {
    auto* ctx = static_cast<ScanWorkContext*>(data);
    
    napi_value result;
    napi_create_object(env, &result);
    
    if (status == napi_ok && ctx->success) {
        napi_value success_val, json_val;
        napi_get_boolean(env, true, &success_val);
        napi_create_string_utf8(env, ctx->result_json.c_str(), NAPI_AUTO_LENGTH, &json_val);
        napi_set_named_property(env, result, "success", success_val);
        napi_set_named_property(env, result, "rawJson", json_val);
        
        napi_resolve_deferred(env, ctx->deferred, result);
    } else {
        napi_value success_val, error_val;
        napi_get_boolean(env, false, &success_val);
        napi_create_string_utf8(env, ctx->error_msg.empty() ? "扫描失败" : ctx->error_msg.c_str(), 
                                NAPI_AUTO_LENGTH, &error_val);
        napi_set_named_property(env, result, "success", success_val);
        napi_set_named_property(env, result, "error", error_val);
        
        napi_resolve_deferred(env, ctx->deferred, result);
    }
    
    // 清理
    napi_delete_async_work(env, ctx->work);
    delete ctx;
    
    HilogPrint("QEMU: CompleteScanWork - Done");
}

// 异步扫描设备（返回 Promise）
static napi_value ScanQemuDevicesAsync(napi_env env, napi_callback_info info) {
    (void)info;
    
    HilogPrint("QEMU: ScanQemuDevicesAsync - Creating async work...");
    
    // 创建 Promise
    napi_value promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);
    
    // 创建上下文
    auto* ctx = new ScanWorkContext();
    ctx->deferred = deferred;
    ctx->success = false;
    
    // 创建异步工作
    napi_value work_name;
    napi_create_string_utf8(env, "ScanQemuDevices", NAPI_AUTO_LENGTH, &work_name);
    
    napi_create_async_work(env, nullptr, work_name,
                           ExecuteScanWork, CompleteScanWork,
                           ctx, &ctx->work);
    
    // 加入队列
    napi_queue_async_work(env, ctx->work);
    
    return promise;
}

// 同步版本（兼容旧代码，直接返回缓存或静态列表）
static napi_value ScanQemuDevices(napi_env env, napi_callback_info info) {
    (void)info;
    
    napi_value result;
    napi_create_object(env, &result);
    
    HilogPrint("QEMU: ScanQemuDevices - Sync version called");
    
    // 检查缓存
    {
        std::lock_guard<std::mutex> lock(g_scan_mutex);
        if (g_devices_scanned && !g_cached_devices_json.empty()) {
            napi_value success, json;
            napi_get_boolean(env, true, &success);
            napi_create_string_utf8(env, g_cached_devices_json.c_str(), NAPI_AUTO_LENGTH, &json);
            napi_set_named_property(env, result, "success", success);
            napi_set_named_property(env, result, "rawJson", json);
            napi_set_named_property(env, result, "cached", success);
            return result;
        }
    }
    
    // 无缓存时，触发一次异步扫描，然后返回提示
    napi_value success, note;
    napi_get_boolean(env, false, &success);
    napi_create_string_utf8(env, "请使用 scanQemuDevicesAsync() 异步扫描，或等待下次调用", NAPI_AUTO_LENGTH, &note);
    napi_set_named_property(env, result, "success", success);
    napi_set_named_property(env, result, "note", note);
    
    return result;
}

// 清除设备缓存（强制重新扫描）
static napi_value ClearDeviceCache(napi_env env, napi_callback_info info) {
    (void)info;
    g_cached_devices_json.clear();
    g_devices_scanned = false;
    HilogPrint("QEMU: Device cache cleared");
    
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// 兼容旧接口：返回缓存的设备列表或提示扫描
static napi_value GetSupportedDevices(napi_env env, napi_callback_info info) {
    (void)info;
    
    napi_value result;
    napi_create_object(env, &result);

    if (g_devices_scanned && !g_cached_devices_json.empty()) {
        // 有缓存，返回缓存
        napi_value rawJson;
        napi_create_string_utf8(env, g_cached_devices_json.c_str(), NAPI_AUTO_LENGTH, &rawJson);
        napi_set_named_property(env, result, "rawJson", rawJson);
        
        napi_value note;
        napi_create_string_utf8(env, "已从缓存加载设备列表", NAPI_AUTO_LENGTH, &note);
        napi_set_named_property(env, result, "note", note);
    } else {
        // 无缓存，提示扫描
        napi_value emptyArr;
        napi_create_array_with_length(env, 0, &emptyArr);
        napi_set_named_property(env, result, "machines", emptyArr);
        napi_set_named_property(env, result, "displays", emptyArr);
        napi_set_named_property(env, result, "networks", emptyArr);
        napi_set_named_property(env, result, "audios", emptyArr);
        
        napi_value note;
        napi_create_string_utf8(env, "请先调用 scanQemuDevices() 扫描设备列表", NAPI_AUTO_LENGTH, &note);
        napi_set_named_property(env, result, "note", note);
    }

    return result;
}

// ============================================================================
// QMP 设备动态探测（从运行中的 VM 获取真实设备列表）
// 这是获取 QEMU 真正支持的设备的最可靠方式
// ============================================================================

// 通过 QMP 查询 QEMU 支持的设备类型
// 参数：vmName - 虚拟机名称（用于定位 QMP socket）
static napi_value ProbeQemuDevices(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value result;
    napi_create_object(env, &result);
    
    // 设置默认返回值
    napi_value success;
    napi_get_boolean(env, false, &success);
    napi_set_named_property(env, result, "success", success);
    
    if (argc < 1) {
        napi_value msg;
        napi_create_string_utf8(env, "需要提供虚拟机名称", NAPI_AUTO_LENGTH, &msg);
        napi_set_named_property(env, result, "error", msg);
        return result;
    }
    
    std::string vmName;
    if (!NapiGetStringUtf8(env, args[0], vmName)) {
        napi_value msg;
        napi_create_string_utf8(env, "无效的虚拟机名称", NAPI_AUTO_LENGTH, &msg);
        napi_set_named_property(env, result, "error", msg);
        return result;
    }
    
    // 构建 QMP socket 路径
    std::string qmpSocketPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmName + "/qmp.sock";
    
    // 检查 QMP socket 是否存在
    struct stat st;
    if (stat(qmpSocketPath.c_str(), &st) != 0) {
        napi_value msg;
        napi_create_string_utf8(env, 
            ("QMP socket 不存在，请先启动虚拟机: " + qmpSocketPath).c_str(), 
            NAPI_AUTO_LENGTH, &msg);
        napi_set_named_property(env, result, "error", msg);
        HilogPrint("QEMU: ProbeQemuDevices - QMP socket not found: " + qmpSocketPath);
        return result;
    }
    
    // 连接 QMP socket
    int sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd < 0) {
        napi_value msg;
        napi_create_string_utf8(env, "创建 socket 失败", NAPI_AUTO_LENGTH, &msg);
        napi_set_named_property(env, result, "error", msg);
        return result;
    }
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, qmpSocketPath.c_str(), sizeof(addr.sun_path) - 1);
    
    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        napi_value msg;
        napi_create_string_utf8(env, 
            ("连接 QMP socket 失败: " + std::string(strerror(errno))).c_str(), 
            NAPI_AUTO_LENGTH, &msg);
        napi_set_named_property(env, result, "error", msg);
        HilogPrint("QEMU: ProbeQemuDevices - connect failed: " + std::string(strerror(errno)));
        return result;
    }
    
    HilogPrint("QEMU: ProbeQemuDevices - connected to QMP socket");
    
    // 读取 QMP 欢迎消息
    char buffer[4096];
    ssize_t n = read(sockfd, buffer, sizeof(buffer) - 1);
    if (n > 0) {
        buffer[n] = '\0';
        HilogPrint(std::string("QEMU: QMP greeting: ") + buffer);
    }
    
    // 发送 qmp_capabilities 命令（必须先执行）
    const char* capCmd = "{\"execute\": \"qmp_capabilities\"}\n";
    write(sockfd, capCmd, strlen(capCmd));
    n = read(sockfd, buffer, sizeof(buffer) - 1);
    if (n > 0) buffer[n] = '\0';
    
    // 发送 qom-list-types 命令查询设备类型
    const char* listCmd = "{\"execute\": \"qom-list-types\", \"arguments\": {\"implements\": \"device\"}}\n";
    write(sockfd, listCmd, strlen(listCmd));
    
    // 读取响应
    std::string response;
    while ((n = read(sockfd, buffer, sizeof(buffer) - 1)) > 0) {
        buffer[n] = '\0';
        response += buffer;
        if (response.find("\"return\"") != std::string::npos || 
            response.find("\"error\"") != std::string::npos) {
            break;
        }
    }
    
    close(sockfd);
    
    HilogPrint("QEMU: ProbeQemuDevices - response length: " + std::to_string(response.size()));
    
    // 返回原始 QMP 响应（让 ArkTS 层解析 JSON）
    napi_get_boolean(env, true, &success);
    napi_set_named_property(env, result, "success", success);
    
    napi_value respVal;
    napi_create_string_utf8(env, response.c_str(), NAPI_AUTO_LENGTH, &respVal);
    napi_set_named_property(env, result, "qmpResponse", respVal);
    
    napi_value pathVal;
    napi_create_string_utf8(env, qmpSocketPath.c_str(), NAPI_AUTO_LENGTH, &pathVal);
    napi_set_named_property(env, result, "qmpSocket", pathVal);
    
    return result;
}

// 暂停VM
static napi_value PauseVm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    char vm_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    
    // 调用真正的暂停实现
    bool success = qemu_pause_vm_by_name(vm_name);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 恢复VM
static napi_value ResumeVm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    char vm_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    
    // 调用真正的恢复实现
    bool success = qemu_resume_vm_by_name(vm_name);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 创建快照
static napi_value CreateSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Missing VM name and snapshot name parameters");
        return nullptr;
    }
    
    char vm_name[256];
    char snapshot_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    napi_get_value_string_utf8(env, args[1], snapshot_name, sizeof(snapshot_name), &name_len);
    
    // 调用真正的快照创建实现
    bool success = qemu_create_snapshot_by_name(vm_name, snapshot_name);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 恢复快照
static napi_value RestoreSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Missing VM name and snapshot name parameters");
        return nullptr;
    }
    
    char vm_name[256];
    char snapshot_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    napi_get_value_string_utf8(env, args[1], snapshot_name, sizeof(snapshot_name), &name_len);
    
    // 调用真正的快照恢复实现
    bool success = qemu_restore_snapshot_by_name(vm_name, snapshot_name);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 列出快照
static napi_value ListSnapshots(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    char vm_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    
    // 调用真正的快照列表实现
    const int max_snapshots = 64;
    char* snapshot_names[64] = {nullptr};
    int count = qemu_list_snapshots_by_name(vm_name, snapshot_names, max_snapshots);
    
    napi_value result;
    napi_create_array_with_length(env, count, &result);
    
    for (int i = 0; i < count; i++) {
        napi_value snapshot;
        if (snapshot_names[i]) {
            napi_create_string_utf8(env, snapshot_names[i], NAPI_AUTO_LENGTH, &snapshot);
            free(snapshot_names[i]);  // 释放 strdup 分配的内存
        } else {
            napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &snapshot);
        }
        napi_set_element(env, result, i, snapshot);
    }
    
    return result;
}

// 删除快照
static napi_value DeleteSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Missing VM name and snapshot name parameters");
        return nullptr;
    }
    
    char vm_name[256];
    char snapshot_name[256];
    size_t name_len;
    napi_get_value_string_utf8(env, args[0], vm_name, sizeof(vm_name), &name_len);
    napi_get_value_string_utf8(env, args[1], snapshot_name, sizeof(snapshot_name), &name_len);
    
    // 调用真正的快照删除实现
    bool success = qemu_delete_snapshot_by_name(vm_name, snapshot_name);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 解析VM配置参数
static VMConfig ParseVMConfig(napi_env env, napi_value config, bool &ok) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> ParseVMConfig 开始 <<<");
    
    VMConfig vmConfig = {};
    ok = false;
    
    // 检查 config 参数是否有效
    napi_valuetype configType;
    if (napi_typeof(env, config, &configType) != napi_ok || configType != napi_object) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> 配置参数无效或不是对象 <<<");
        return vmConfig;
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> 配置参数类型检查通过 <<<");
    
    // 获取name
    napi_value nameValue;
    if (napi_get_named_property(env, config, "name", &nameValue) != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> 获取 name 属性失败 <<<");
        HilogPrint("QEMU: ParseVMConfig failed - cannot get name property");
        return vmConfig;
    }
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> 获取 name 属性成功，准备读取字符串 <<<");
    
    if (!NapiGetStringUtf8(env, nameValue, vmConfig.name)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> 读取 name 字符串失败 <<<");
        HilogPrint("QEMU: ParseVMConfig failed - cannot get name string");
        return vmConfig;
    }
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_PARSE", ">>> name = %{public}s <<<", vmConfig.name.c_str());
    HilogPrint("QEMU: ParseVMConfig got name: " + vmConfig.name);

    // 获取来宾系统类型（可选，ArkTS 侧传入 osType）
    napi_value osTypeValue;
    if (napi_get_named_property(env, config, "osType", &osTypeValue) == napi_ok) {
        std::string osType;
        if (NapiGetStringUtf8(env, osTypeValue, osType)) {
            vmConfig.osType = osType;
            HilogPrint("QEMU: ParseVMConfig got osType: " + osType);
        }
    }
    
    // 获取架构类型（可选，默认为 aarch64）
    napi_value archValue;
    if (napi_get_named_property(env, config, "archType", &archValue) == napi_ok) {
        std::string arch;
        if (NapiGetStringUtf8(env, archValue, arch)) {
            vmConfig.archType = arch;
        }
    } else {
        vmConfig.archType = "aarch64"; // 默认使用 aarch64（鸿蒙版 UTM 推荐）
    }
    
    // 获取isoPath（可选）
    napi_value isoValue;
    if (napi_get_named_property(env, config, "isoPath", &isoValue) == napi_ok) {
        std::string iso;
        if (NapiGetStringUtf8(env, isoValue, iso)) {
            vmConfig.isoPath = iso;
        }
    }
    
    // 获取数值参数
    // ============ 获取配置值并强制安全默认值 ============
    napi_value diskSizeValue, memoryValue, cpuValue;
    
    // 磁盘大小
    vmConfig.diskSizeGB = 32; // 安全默认值
    if (napi_get_named_property(env, config, "diskSizeGB", &diskSizeValue) == napi_ok) {
        int32_t diskVal = 0;
        napi_get_value_int32(env, diskSizeValue, &diskVal);
        if (diskVal > 0) {
            vmConfig.diskSizeGB = diskVal;
        }
    }
    
    // 内存大小 - 最小 512MB，默认 2048MB
    vmConfig.memoryMB = 2048; // 安全默认值
    if (napi_get_named_property(env, config, "memoryMB", &memoryValue) == napi_ok) {
        int32_t memVal = 0;
        napi_get_value_int32(env, memoryValue, &memVal);
        if (memVal >= 512) {
            vmConfig.memoryMB = memVal;
        } else if (memVal > 0) {
            vmConfig.memoryMB = 512; // 强制最小值
            HilogPrint("QEMU: Warning - memoryMB too small, using 512MB minimum");
        }
    }
    
    // CPU 核心数 - 最小 1，默认 2
    vmConfig.cpuCount = 2; // 安全默认值
    if (napi_get_named_property(env, config, "cpuCount", &cpuValue) == napi_ok) {
        int32_t cpuVal = 0;
        napi_get_value_int32(env, cpuValue, &cpuVal);
        if (cpuVal >= 1) {
            vmConfig.cpuCount = cpuVal;
        } else {
            HilogPrint("QEMU: Warning - cpuCount invalid, using 2 cores default");
        }
    }

    // CPU 型号（可选）
    napi_value cpuModelValue;
    if (napi_get_named_property(env, config, "cpuModel", &cpuModelValue) == napi_ok) {
        std::string cpuModel;
        if (NapiGetStringUtf8(env, cpuModelValue, cpuModel)) {
            vmConfig.cpuModel = cpuModel;
            HilogPrint("QEMU: ParseVMConfig got cpuModel: " + cpuModel);
        }
    }
    
    // 打印最终使用的配置值
    HilogPrint("QEMU: VM config - CPU=" + std::to_string(vmConfig.cpuCount) + 
               " MEM=" + std::to_string(vmConfig.memoryMB) + "MB" +
               " DISK=" + std::to_string(vmConfig.diskSizeGB) + "GB");
    
    // 获取加速器类型
    napi_value accelValue;
    if (napi_get_named_property(env, config, "accel", &accelValue) == napi_ok) {
        std::string accel;
        if (NapiGetStringUtf8(env, accelValue, accel)) {
            vmConfig.accel = accel;
        }
    } else {
        // 自动检测：支持KVM则使用KVM，否则使用TCG
        vmConfig.accel = kvmSupported() ? "kvm" : "tcg,thread=multi";
    }
    
    // 获取显示类型
    napi_value displayValue;
    if (napi_get_named_property(env, config, "display", &displayValue) == napi_ok) {
        std::string display;
        if (NapiGetStringUtf8(env, displayValue, display)) {
            vmConfig.display = display;
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

    // 获取安装模式标志（可选，默认 false）
    vmConfig.installMode = false;
    napi_value installModeValue;
    if (napi_get_named_property(env, config, "installMode", &installModeValue) == napi_ok) {
        bool installMode = false;
        if (napi_get_value_bool(env, installModeValue, &installMode) == napi_ok) {
            vmConfig.installMode = installMode;
            HilogPrint(std::string("QEMU: ParseVMConfig installMode = ") + (installMode ? "true" : "false"));
        }
    }
    
    // 获取 UEFI 固件路径（可选）
    napi_value efiFirmwareValue;
    if (napi_get_named_property(env, config, "efiFirmware", &efiFirmwareValue) == napi_ok) {
        std::string efiFirmware;
        if (NapiGetStringUtf8(env, efiFirmwareValue, efiFirmware)) {
            vmConfig.efiFirmware = efiFirmware;
            HilogPrint("QEMU: ParseVMConfig got efiFirmware: " + efiFirmware);
        }
    }
    
    // 获取共享目录路径（可选）
    napi_value sharedDirValue;
    if (napi_get_named_property(env, config, "sharedDir", &sharedDirValue) == napi_ok) {
        std::string sharedDir;
        if (NapiGetStringUtf8(env, sharedDirValue, sharedDir)) {
            vmConfig.sharedDir = sharedDir;
        }
    }
    
    // 获取 QEMU 数据目录路径（由 KeymapsManager 提供，包含 keymaps）
    napi_value qemuDataDirValue;
    if (napi_get_named_property(env, config, "qemuDataDir", &qemuDataDirValue) == napi_ok) {
        std::string qemuDataDir;
        if (NapiGetStringUtf8(env, qemuDataDirValue, qemuDataDir)) {
            vmConfig.qemuDataDir = qemuDataDir;
            HilogPrint("QEMU: ParseVMConfig got qemuDataDir: " + qemuDataDir);
        }
    }
    // ArkTS 是否确认 keymaps 可用
    napi_value keymapsAvailValue;
    if (napi_get_named_property(env, config, "keymapsAvailable", &keymapsAvailValue) == napi_ok) {
        bool km = false;
        if (napi_get_value_bool(env, keymapsAvailValue, &km) == napi_ok) {
            vmConfig.keymapsAvailable = km;
            HilogPrint(std::string("QEMU: ParseVMConfig keymapsAvailable = ") + (km ? "true" : "false"));
        }
    }

    // 获取高级硬件配置：机器 / 显卡 / 网卡 / 声卡
    napi_value machineValue;
    if (napi_get_named_property(env, config, "machine", &machineValue) == napi_ok) {
        std::string machine;
        if (NapiGetStringUtf8(env, machineValue, machine)) {
            vmConfig.machine = machine;
            HilogPrint("QEMU: ParseVMConfig got machine: " + machine);
        }
    }

    napi_value displayDeviceValue;
    if (napi_get_named_property(env, config, "displayDevice", &displayDeviceValue) == napi_ok) {
        std::string displayDev;
        if (NapiGetStringUtf8(env, displayDeviceValue, displayDev)) {
            vmConfig.displayDevice = displayDev;
            HilogPrint("QEMU: ParseVMConfig got displayDevice: " + displayDev);
        }
    }

    napi_value networkDeviceValue;
    if (napi_get_named_property(env, config, "networkDevice", &networkDeviceValue) == napi_ok) {
        std::string netDev;
        if (NapiGetStringUtf8(env, networkDeviceValue, netDev)) {
            vmConfig.networkDevice = netDev;
            HilogPrint("QEMU: ParseVMConfig got networkDevice: " + netDev);
        }
    }

    napi_value audioDeviceValue;
    if (napi_get_named_property(env, config, "audioDevice", &audioDeviceValue) == napi_ok) {
        std::string audioDev;
        if (NapiGetStringUtf8(env, audioDeviceValue, audioDev)) {
            vmConfig.audioDevice = audioDev;
            HilogPrint("QEMU: ParseVMConfig got audioDevice: " + audioDev);
        }
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

static bool PreflightOpen(const std::string& label, const std::string& path, int flags)
{
    if (path.empty()) {
        HilogPrint("QEMU: [PREFLIGHT] " + label + " path is empty");
        return false;
    }
    int fd = open(path.c_str(), flags);
    if (fd < 0) {
        HilogPrint("QEMU: [PREFLIGHT] open(" + label + ") failed: " + path +
                   " flags=" + std::to_string(flags) + " errno=" + std::to_string(errno) +
                   " (" + std::string(strerror(errno)) + ")");
        return false;
    }
    close(fd);
    HilogPrint("QEMU: [PREFLIGHT] open(" + label + ") ok: " + path);
    return true;
}

static bool PreflightQcow2Header(const std::string& path)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    unsigned char magic[4] = {0, 0, 0, 0};
    ssize_t r = read(fd, magic, sizeof(magic));
    close(fd);
    if (r != 4) {
        HilogPrint("QEMU: [PREFLIGHT] qcow2 header read failed: " + path + " r=" + std::to_string(r));
        return false;
    }
    // 'QFI\xfb'
    if (!(magic[0] == 'Q' && magic[1] == 'F' && magic[2] == 'I' && magic[3] == 0xFB)) {
        std::string hex = "0x" + std::to_string((int)magic[0]) + "," + std::to_string((int)magic[1]) + "," +
                          std::to_string((int)magic[2]) + "," + std::to_string((int)magic[3]);
        HilogPrint("QEMU: [PREFLIGHT] qcow2 magic mismatch: " + path + " magic=" + hex);
        return false;
    }
    HilogPrint("QEMU: [PREFLIGHT] qcow2 magic ok: " + path);
    return true;
}

// 复制文件（覆盖/截断写入）。用于把 UEFI VARS 模板复制到每个 VM 的私有 vars 文件中。
static bool CopyFileTruncate(const std::string& src, const std::string& dst)
{
    int in = open(src.c_str(), O_RDONLY);
    if (in < 0) return false;

    // 确保目标目录存在
    size_t pos = dst.find_last_of('/');
    if (pos != std::string::npos) {
        std::string dir = dst.substr(0, pos);
        if (!dir.empty()) {
            (void)CreateDirectories(dir);
        }
    }

    int out = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        close(in);
        return false;
    }

    char buf[8192];
    bool ok = true;
    while (true) {
        ssize_t r = read(in, buf, sizeof(buf));
        if (r == 0) break;
        if (r < 0) { ok = false; break; }
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(out, buf + off, static_cast<size_t>(r - off));
            if (w <= 0) { ok = false; break; }
            off += w;
        }
        if (!ok) break;
    }

    (void)fsync(out);
    close(out);
    close(in);
    return ok;
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

// 创建/更新 VM 高级硬件偏好文件（vmPerfence.json）
static bool CreateVmPerfenceFile(const VMConfig& config)
{
    try {
        std::string vmDir = config.vmDir;
        std::string perfPath = vmDir + "/vmPerfence.json";

        if (!CreateDirectories(vmDir)) {
            return false;
        }

        std::ofstream perf(perfPath);
        if (!perf) return false;

        // 简单 JSON，记录高级硬件配置，供后续 UI / 调试使用
        perf << "{\n";
        perf << "  \"machine\": \"" << config.machine << "\",\n";
        perf << "  \"displayDevice\": \"" << config.displayDevice << "\",\n";
        perf << "  \"networkDevice\": \"" << config.networkDevice << "\",\n";
        perf << "  \"audioDevice\": \"" << config.audioDevice << "\"\n";
        perf << "}\n";

        perf.close();
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
// QCOW2 文件头结构 (简化版)
#pragma pack(push, 1)
struct Qcow2Header {
    uint32_t magic;                // 0x514649fb
    uint32_t version;              // 3
    uint64_t backing_file_offset;  // 0
    uint32_t backing_file_size;    // 0
    uint32_t cluster_bits;         // 16 (64KB)
    uint64_t size;                 // disk size in bytes
    uint32_t crypt_method;         // 0
    uint32_t l1_size;              // L1 table entries
    uint64_t l1_table_offset;      // offset to L1 table
    uint64_t refcount_table_offset;// offset to refcount table
    uint32_t refcount_table_clusters; // 1
    uint32_t nb_snapshots;         // 0
    uint64_t snapshots_offset;     // 0
    // Version 3 additions
    uint64_t incompatible_features; // 0
    uint64_t compatible_features;   // 0
    uint64_t autoclear_features;    // 0
    uint32_t refcount_order;        // 4 (16-bit refcounts)
    uint32_t header_length;         // 104
};
#pragma pack(pop)

// 字节序转换（大端）
static uint32_t be32(uint32_t val) {
    return ((val & 0xff) << 24) | ((val & 0xff00) << 8) | ((val & 0xff0000) >> 8) | ((val & 0xff000000) >> 24);
}

static uint64_t be64(uint64_t val) {
    return ((uint64_t)be32(val & 0xffffffff) << 32) | be32(val >> 32);
}

static uint32_t ReadBe32(const unsigned char* p)
{
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

static uint64_t ReadBe64(const unsigned char* p)
{
    uint64_t hi = ReadBe32(p);
    uint64_t lo = ReadBe32(p + 4);
    return (hi << 32) | lo;
}

static bool IsQcow2Magic(const unsigned char magic[4])
{
    return magic[0] == 'Q' && magic[1] == 'F' && magic[2] == 'I' && magic[3] == 0xFB;
}

// 轻量 qcow2 健康检查：避免 “旧版内置 qcow2 伪实现” 生成的镜像触发 QEMU bdrv_open fatal→exit(1)
// 规则：qcow2 必须有有效的 refcount table entry[0]（不应为 0），否则 QEMU 会认为镜像损坏并拒绝以 rw 打开。
static bool PreflightQcow2RefcountTable(const std::string& path)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;

    unsigned char headerBuf[104] = {0};
    ssize_t r = read(fd, headerBuf, sizeof(headerBuf));
    if (r < 32) {
        close(fd);
        return false;
    }

    if (!IsQcow2Magic(headerBuf)) {
        close(fd);
        return true; // 非 qcow2：这条检查不适用
    }

    uint32_t clusterBits = ReadBe32(headerBuf + 20);
    uint64_t refcountTableOffset = ReadBe64(headerBuf + 48);

    if (clusterBits < 9 || clusterBits > 22) {
        HilogPrint("QEMU: [PREFLIGHT] qcow2 invalid clusterBits=" + std::to_string(clusterBits) + " path=" + path);
        close(fd);
        return false;
    }

    const uint64_t clusterSize = 1ULL << clusterBits;
    if (refcountTableOffset == 0 || (refcountTableOffset % clusterSize) != 0) {
        HilogPrint("QEMU: [PREFLIGHT] qcow2 invalid refcount_table_offset=" + std::to_string(refcountTableOffset) +
                   " clusterSize=" + std::to_string(clusterSize) + " path=" + path);
        close(fd);
        return false;
    }

    // 读取 refcount table 的第 1 个条目（8字节，big-endian offset）
    if (lseek(fd, static_cast<off_t>(refcountTableOffset), SEEK_SET) < 0) {
        close(fd);
        return false;
    }
    unsigned char ent[8] = {0};
    r = read(fd, ent, sizeof(ent));
    close(fd);
    if (r != 8) return false;

    uint64_t firstRefcountBlock = ReadBe64(ent);
    if (firstRefcountBlock == 0) {
        HilogPrint("QEMU: [PREFLIGHT] qcow2 refcount table entry[0]==0 (image likely corrupt / legacy stub). path=" + path);
        return false;
    }

    return true;
}

static bool IsQcow2FileQuick(const std::string& path)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    unsigned char magic[4] = {0, 0, 0, 0};
    ssize_t r = read(fd, magic, sizeof(magic));
    close(fd);
    if (r != 4) return false;
    return IsQcow2Magic(magic);
}

static bool CreateRawSparseDisk(const std::string& diskPath, uint64_t sizeBytes)
{
    int fd = open(diskPath.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) return false;
    int rc = ftruncate(fd, static_cast<off_t>(sizeBytes));
    close(fd);
    return rc == 0;
}

static bool CreateVirtualDisk(const std::string& diskPath, int sizeGB) {
    try {
        std::string dirPath = diskPath.substr(0, diskPath.find_last_of('/'));
        if (!CreateDirectories(dirPath)) {
            return false;
        }
        
        // 默认创建 raw sparse：稳定、简单，且避免错误的“内置 qcow2 伪实现”导致 QEMU 判定镜像损坏并 exit(1)
        uint64_t sizeBytes = static_cast<uint64_t>(sizeGB) * 1024ULL * 1024ULL * 1024ULL;
        if (!CreateRawSparseDisk(diskPath, sizeBytes)) {
            HilogPrint("QEMU: Failed to create raw sparse disk: " + diskPath + " errno=" + std::to_string(errno));
            return false;
        }
        HilogPrint("QEMU: Created RAW sparse disk: " + diskPath + " (" + std::to_string(sizeGB) + "GB)");
        return true;
    } catch (...) {
        return false;
    }
}

// 构建QEMU命令行参数
static std::vector<std::string> BuildQemuArgs(const VMConfig& config) {
    std::vector<std::string> args;
    bool scsiControllerAdded = false;
    bool xhciControllerAdded = false;
    bool sataControllerAdded = false;
    // ============================================================
    // 来宾 OS 类型（用于做最小化兼容策略）
    // - Windows PE/安装程序通常没有 virtio-blk 驱动
    // - Linux 通常自带 virtio 驱动
    // ============================================================
    auto toLower = [](std::string s) -> std::string {
        for (auto &ch : s) {
            ch = static_cast<char>(::tolower(static_cast<unsigned char>(ch)));
        }
        return s;
    };
    std::string osHint = config.osType;
    if (osHint.empty()) {
        osHint = config.name;
    }
    if (osHint.empty()) {
        osHint = config.isoPath;
    }
    const std::string osLower = toLower(osHint);
    const bool isWindowsGuest =
        (!osLower.empty() && (osLower == "windows" || osLower.find("windows") != std::string::npos ||
                              osLower == "win" || osLower.find("win") == 0));
    HilogPrint(std::string("QEMU: [OS] osType=") + (config.osType.empty() ? "(empty)" : config.osType) +
               " inferredWindows=" + (isWindowsGuest ? "true" : "false"));
    // install 模式下，某些固件会按“设备枚举顺序”而不是 bootindex 来选择默认启动项。
    // 由于我们的 disk 配置在 ISO 之前，固件可能先尝试从硬盘启动，导致一直停在 TianoCore。
    // 因此：在 aarch64+virt 的 install 模式下，将硬盘参数延后到 ISO 之后再追加，以提高 ISO 启动概率。
    const bool deferDiskForInstallBoot =
        config.installMode &&
        config.archType == "aarch64" &&
        (config.machine.empty() || config.machine == "virt") &&
        !config.isoPath.empty();
    std::vector<std::string> deferredDiskArgs;

    // 一些 Windows/WinPE 镜像在 aarch64 virt 下对 XHCI/USB-storage 支持不稳定，
    // 会出现安装程序提示 “A media driver your computer needs is missing...”
    // 因此提供 AHCI(SATA) 作为更通用的安装介质/磁盘承载方式（Windows 免驱）。
    auto ensureSataController = [&]() {
        if (sataControllerAdded) return;
        args.push_back("-device");
        args.push_back("ich9-ahci,id=ahci");
        sataControllerAdded = true;
        HilogPrint("QEMU: [HW] SATA controller added: ich9-ahci,id=ahci");
    };
    
    // 根据架构选择QEMU二进制文件
    if (config.archType == "x86_64") {
        args.push_back("qemu-system-x86_64");
    } else if (config.archType == "i386") {
        args.push_back("qemu-system-i386");
    } else {
        args.push_back("qemu-system-aarch64"); // 默认 aarch64
    }
    
    // ============================================================
    // 设置 QEMU 数据目录 (-L 参数)
    // 这是修复 VNC 崩溃的关键：VNC 初始化需要 keymaps/en-us 文件
    // KeymapsManager.ets 会将 rawfile/keymaps 复制到沙盒目录
    // ============================================================
    
    // 优先使用从 ArkTS 传入的 qemuDataDir（由 KeymapsManager 提供）
    // 重要：HarmonyOS 沙盒文件系统在 C++ 层的 stat() 可能无法正确访问
    // 因此我们信任 ArkTS 层（KeymapsManager）的验证结果
    std::string qemuDataDir = config.qemuDataDir;
    
    HilogPrint("QEMU: [VNC_DEBUG] config.qemuDataDir = " + (qemuDataDir.empty() ? "(empty)" : qemuDataDir));
    
    // 如果 ArkTS 提供了 qemuDataDir，信任它（ArkTS 层已经验证过 keymaps 存在）
    // 注意：C++ 的 stat() 在 HarmonyOS 沙盒中可能返回错误的结果
    if (!qemuDataDir.empty()) {
        std::string keymapTest = qemuDataDir + "/keymaps/en-us";
        // 仅记录日志，不清空 qemuDataDir（信任 ArkTS 层的验证）
        if (FileExists(keymapTest)) {
            HilogPrint(std::string("QEMU: [VNC_DEBUG] C++ stat() confirms keymaps at: ") + qemuDataDir);
        } else {
            // C++ 的 stat() 可能在沙盒中失败，但 ArkTS 层已确认文件存在
            // 继续使用 ArkTS 提供的路径
            HilogPrint(std::string("QEMU: [VNC_DEBUG] C++ stat() failed for: ") + keymapTest);
            HilogPrint("QEMU: [VNC_DEBUG] Trusting ArkTS - keymaps should exist at: " + qemuDataDir);
            // 不再清空 qemuDataDir！
        }
    }
    
    // 仅当 ArkTS 没有提供 qemuDataDir 时，才尝试搜索默认位置
    if (qemuDataDir.empty()) {
        HilogPrint("QEMU: [VNC_DEBUG] ArkTS did not provide qemuDataDir, searching default locations...");
        
        std::vector<std::string> dataSearchPaths = {
            // 首选：KeymapsManager 复制的目标位置
            "/data/storage/el2/base/haps/entry/files/qemu_data",
            // 备选：不同的 filesDir 格式
            "/data/app/el2/100/base/com.cloudshin.aetherengine/haps/entry/files/qemu_data",
            // rawfile 直接访问（可能在某些设备上可用）
            "/data/storage/el1/bundle/entry/resources/rawfile",
            "/data/storage/el2/base/haps/entry/resources/rawfile",
        };
        
        for (const auto& path : dataSearchPaths) {
            std::string keymapTest = path + "/keymaps/en-us";
            HilogPrint(std::string("QEMU: [VNC_DEBUG] Checking: ") + keymapTest);
            if (FileExists(keymapTest)) {
                qemuDataDir = path;
                HilogPrint(std::string("QEMU: [VNC_DEBUG] FOUND keymaps at: ") + path);
                break;
            } else {
                HilogPrint(std::string("QEMU: [VNC_DEBUG] NOT FOUND: ") + keymapTest);
            }
        }
    }
    
    if (!qemuDataDir.empty()) {
        args.push_back("-L");
        args.push_back(qemuDataDir);
        HilogPrint(std::string("QEMU: Using data directory for VNC: ") + qemuDataDir);
    } else {
        HilogPrint("QEMU: WARNING - keymaps directory not found!");
        HilogPrint("QEMU: VNC will be DISABLED, falling back to headless mode");
        // 仍然设置一个默认路径（QEMU需要-L参数）
        args.push_back("-L");
        args.push_back("/data/storage/el2/base/haps/entry/files/qemu_data");
    }
    
    // 根据架构设置机器类型和CPU
    // 注意：当前 libqemu_full.so 仅编译了 aarch64 目标
    // x86_64/i386 需要重新编译 QEMU 才能支持
    if (config.archType == "x86_64" || config.archType == "i386") {
        // x86 架构目前不支持，打印警告并回退到 aarch64 virt
        HilogPrint("QEMU: WARNING - x86/x86_64 architecture is not supported in current build");
        HilogPrint("QEMU: WARNING - Falling back to aarch64 virt machine");
        args.push_back("-machine");
        // Windows on ARM 通常需要 ACPI；对大多数 Linux 也兼容
        args.push_back("virt,gic-version=3,acpi=on");
        args.push_back("-cpu");
        args.push_back("cortex-a72");
    } else {
        // aarch64 配置，支持从创建向导传入的 machine
        std::string machine = config.machine.empty() ? "virt" : config.machine;
        HilogPrint(std::string("QEMU: [HW] Machine = ") + machine);

        args.push_back("-machine");
        if (machine == "virt") {
            // 注意：virtualization=on 在 TCG 模式下可能导致问题
            // 仅在 KVM 模式下启用嵌套虚拟化
            if (config.accel == "kvm") {
                args.push_back("virt,gic-version=3,virtualization=on,acpi=on");
            } else {
                args.push_back("virt,gic-version=3,acpi=on");
            }
        } else {
            // 其他机器类型（如 raspi3b/raspi4b）直接传递，保持最小假设
            args.push_back(machine);
        }
        
        // aarch64+virt：补齐固件/Windows 常用能力
        // 1) RNG：EDK2/Windows 启动阶段会尝试初始化 TRNG；没有 RNG 时会打印 ArmTrngLib init failed
        // 2) TCG 兼容：Windows ARM 镜像对 CPU feature 较敏感，TCG 下用 -cpu max 更稳（性能另说）
        const bool isTcg = (config.accel.find("tcg") != std::string::npos);
        if (machine == "virt") {
            // 生成运行期唯一的 RNG ID，避免在同一进程多次启动时出现 Duplicate ID 错误
            auto sanitizeId = [](const std::string &name) -> std::string {
                std::string out;
                out.reserve(name.size());
                for (char c : name) {
                    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
                        out.push_back(c);
                    } else if (c == '-' || c == '_' || c == '.') {
                        out.push_back(c);
                    } else {
                        out.push_back('_');
                    }
                }
                if (out.empty()) out = "vm";
                return out;
            };
            const uint32_t uniq = g_id_suffix_counter.fetch_add(1, std::memory_order_relaxed) + 1;
            const std::string rngId = "rng_hmos_" + sanitizeId(config.name) + "_" + std::to_string(uniq);

            // RNG backend
            args.push_back("-object");
            args.push_back("rng-random,id=" + rngId + ",filename=/dev/urandom");
            args.push_back("-device");
            args.push_back("virtio-rng-device,rng=" + rngId);
            HilogPrint("QEMU: [HW] RNG enabled: rng-random(id=" + rngId + ") + virtio-rng-device (MMIO)");

            // TPM2 (Windows 11 / UEFI TCG2)
            // - HarmonyOS 构建：QEMU 侧提供“内置最小 TPM2”兜底（见 QEMU tpm_emulator.c 的 OHOS patch）
            //   这样即使没有 swtpm 外部进程，也不会因为缺少 chardev 导致 QEMU 直接 exit(1) 把 App 带崩。
            // - 设备模型选择（重要：避免 QEMU/ACPI 崩溃）：
            //   - aarch64 + virt + acpi=on：必须使用 tpm-tis-device（SysBusDevice）
            //     * QEMU 的 ARM virt ACPI 代码会把 tpm_find() 强转为 SysBusDevice 并走 platform-bus 分配 MMIO
            //     * tpm-crb 在 QEMU 里是 TYPE_DEVICE，且会固定映射到 0xFED40000，不是 sysbus 设备
            //     * 在我们当前构建（未启用 CONFIG_QOM_CAST_DEBUG）下，这个强转不会报错而会导致 NULL 解引用崩溃：
            //       memory_region_is_mapped(NULL) <- platform_bus_get_mmio_addr()
            //   - 其他机器/平台：才考虑 tpm-crb（更贴近 PC/Win11 常见 CRB 接口）
            // - backend 使用 type=emulator；在 HarmonyOS 构建里我们提供了“内置最小 TPM2”实现（无需 swtpm 进程）
            // 启用 TPM 后端（HarmonyOS：缺省不传 chardev，会走内置 minimal TPM2）
            args.push_back("-tpmdev");
            args.push_back("emulator,id=tpm0");
            args.push_back("-device");

            // aarch64 virt + ACPI：使用 tpm-tis-device（sysbus）更稳，避免 CRB 在 ARM virt 下的映射/类型问题
            if (machine == "virt") {
                args.push_back("tpm-tis-device,tpmdev=tpm0");
                HilogPrint("QEMU: [HW] TPM2 enabled: tpm-tis-device (virt/acpi safe, builtin backend on OHOS)");
            } else {
                // 其他机器：保守同样使用 TIS
                args.push_back("tpm-tis-device,tpmdev=tpm0");
                HilogPrint("QEMU: [HW] TPM2 enabled: tpm-tis-device (tpmdev=emulator,id=tpm0)");
            }
        }

        // CPU 选择优先级：用户指定(cpuModel) > 默认策略
        auto normalizeCpu = [](const std::string& s) -> std::string {
            std::string t = s;
            // trim
            while (!t.empty() && (t.front() == ' ' || t.front() == '\t' || t.front() == '\n' || t.front() == '\r')) t.erase(t.begin());
            while (!t.empty() && (t.back() == ' ' || t.back() == '\t' || t.back() == '\n' || t.back() == '\r')) t.pop_back();
            return t;
        };
        const std::string requestedCpu = normalizeCpu(config.cpuModel);
        const auto isAllowedCpu = [](const std::string& m) -> bool {
            if (m.empty()) return false;
            // 白名单：避免用户填错导致 qemu_init 直接失败（HarmonyOS 下失败代价很高）
            return m == "max" ||
                   m == "cortex-a72" ||
                   m == "cortex-a57" ||
                   m == "cortex-a53" ||
                   m == "neoverse-n1";
        };

        args.push_back("-cpu");
        if (!requestedCpu.empty()) {
            if (requestedCpu == "auto") {
                // fallthrough to default policy
            } else if (isAllowedCpu(requestedCpu)) {
                args.push_back(requestedCpu);
                HilogPrint("QEMU: [HW] CPU model selected by user: " + requestedCpu);
            } else {
                HilogPrint("QEMU: [HW] ⚠️ cpuModel not allowed/unknown, fallback to default policy: " + requestedCpu);
            }
        }
        if (args.back() == "-cpu") {
            // 还没 push 具体型号（走默认策略）
            if (machine == "virt" && isTcg) {
                args.push_back("max");
                HilogPrint("QEMU: [HW] CPU=max selected for TCG compatibility");
            } else {
                args.push_back("cortex-a72");
            }
        }
    }
    
    args.push_back("-smp");
    args.push_back(std::to_string(config.cpuCount));
    
    args.push_back("-m");
    args.push_back(std::to_string(config.memoryMB));
    
    // 加速器配置
    args.push_back("-accel");
    args.push_back(config.accel);
    
    // UEFI/BIOS 固件配置
    std::string firmwarePath = config.efiFirmware;
    HilogPrint("QEMU: [FIRMWARE] ArkTS 传入的固件路径: " + (firmwarePath.empty() ? "(空)" : firmwarePath));
    
    // 如果未指定固件路径，尝试自动查找
    if (firmwarePath.empty()) {
        HilogPrint("QEMU: [FIRMWARE] 固件路径为空，开始自动搜索...");
        std::string firmwareFileName;
    if (config.archType == "x86_64" || config.archType == "i386") {
            firmwareFileName = "OVMF_CODE.fd"; // x86 UEFI 固件
    } else {
            firmwareFileName = "edk2-aarch64-code.fd"; // ARM64 UEFI 固件
    }
    
        std::vector<std::string> searchPaths = {
            // rawfile/ 目录（通过 FirmwareManager 复制到 files）
            "/data/storage/el1/bundle/entry/resources/rawfile/" + firmwareFileName,
            "/data/storage/el2/base/haps/entry/resources/rawfile/" + firmwareFileName,
            // files/ 目录（FirmwareManager 复制的目标位置）
            "/data/storage/el2/base/haps/entry/files/" + firmwareFileName,
            "/data/storage/el2/base/haps/entry/files/firmware/" + firmwareFileName,
            firmwareFileName  // 作为fallback
        };
    
        for (const auto& path : searchPaths) {
        if (FileExists(path)) {
                firmwarePath = path;
                HilogPrint(std::string("QEMU: Found firmware at: ") + path);
            break;
        }
    }
    }
    
    // 配置固件
    // 注意：HarmonyOS 沙盒文件系统在 C++ 层的 FileExists() 可能返回错误结果
    // 如果 ArkTS 层（FirmwareManager）已确认固件存在，我们应该信任它，但仍需验证可读性
    auto try_firmware_path = [&](std::string path) -> bool {
        if (path.empty()) return false;
        // 先尝试 stat
        if (!FileExists(path)) {
            HilogPrint("QEMU: [FIRMWARE] C++ stat() failed for: " + path);
        }
        // 再尝试 open/read
        int fwFd = open(path.c_str(), O_RDONLY);
        if (fwFd < 0) {
            HilogPrint("QEMU: [FIRMWARE] open() failed: " + path + " errno=" + std::to_string(errno));
            return false;
        }
        char buffer[1];
        ssize_t r = read(fwFd, buffer, 0);
        close(fwFd);
        if (r < 0) {
            HilogPrint("QEMU: [FIRMWARE] open ok but read failed: " + path + " errno=" + std::to_string(errno));
            return false;
        }
        HilogPrint("QEMU: [FIRMWARE] Verified readable: " + path);
        firmwarePath = path;
        return true;
    };

    bool firmwareExists = false;

    // 先尝试 ArkTS 传入的路径
    if (!firmwarePath.empty()) {
        firmwareExists = try_firmware_path(firmwarePath);
    }

    // 如果 ArkTS 路径不可读，尝试自动搜索内置/默认路径
    if (!firmwareExists) {
        std::string firmwareFileName;
        if (config.archType == "x86_64" || config.archType == "i386") {
            firmwareFileName = "OVMF_CODE.fd";
        } else {
            firmwareFileName = "edk2-aarch64-code.fd";
        }
        std::vector<std::string> searchPaths = {
            "/data/storage/el1/bundle/entry/resources/rawfile/" + firmwareFileName,
            "/data/storage/el2/base/haps/entry/resources/rawfile/" + firmwareFileName,
            "/data/storage/el2/base/haps/entry/files/" + firmwareFileName,
            "/data/storage/el2/base/haps/entry/files/firmware/" + firmwareFileName,
            firmwareFileName  // fallback
        };
        for (const auto& p : searchPaths) {
            if (try_firmware_path(p)) {
                firmwareExists = true;
                break;
            }
        }
    }

    HilogPrint("QEMU: [FIRMWARE] 验证结果: " + std::string(firmwareExists ? "成功" : "失败"));
    HilogPrint("QEMU: [FIRMWARE] 最终固件路径: " + (firmwarePath.empty() ? "(空)" : firmwarePath));

    if (firmwareExists) {
        if (config.archType == "aarch64") {
            // ARM64 使用 pflash 方式加载 UEFI
            // 注意：仅挂 CODE 盘在部分场景会导致 UEFI 无法保存变量/引导异常，因此尽量同时挂 VARS 盘（unit=1，可写）
            args.push_back("-drive");
            args.push_back("file=" + firmwarePath + ",if=pflash,format=raw,unit=0,readonly=on");
            HilogPrint(std::string("QEMU: [FIRMWARE] 添加 pflash(CODE) 参数: ") + firmwarePath);

            // 尝试自动定位 VARS
            auto simple_dirname = [](const std::string& p) -> std::string {
                size_t pos = p.find_last_of('/');
                if (pos == std::string::npos) return std::string();
                return p.substr(0, pos);
            };
            std::string fwDir = simple_dirname(firmwarePath);
            std::vector<std::string> varsCandidates;
            // 工程 rawfile 里当前是 edk2-arm-vars.fd（不是 edk2-aarch64-vars.fd），两者都兼容尝试
            if (!fwDir.empty()) {
                varsCandidates.push_back(fwDir + "/edk2-arm-vars.fd");
                varsCandidates.push_back(fwDir + "/edk2-aarch64-vars.fd");
            }
            varsCandidates.push_back("edk2-arm-vars.fd");
            varsCandidates.push_back("edk2-aarch64-vars.fd");

            std::string varsTemplatePath;
            for (const auto& cand : varsCandidates) {
                if (cand.empty()) continue;
                int fd = open(cand.c_str(), O_RDONLY);
                if (fd < 0) continue;
                // 轻量验证：读 0 字节（不移动文件指针），确认句柄可用
                char tmp[1];
                ssize_t r = read(fd, tmp, 0);
                close(fd);
                if (r < 0) continue;
                varsTemplatePath = cand;
                break;
            }

            if (!varsTemplatePath.empty()) {
                // 关键修复：UEFI VARS 不能全局复用，否则 BootOrder/启动项会被“记住”，
                // 导致反复先从硬盘启动、按键没接住就回固件（你看到的 TianoCore 卡住）。
                // 这里把 VARS 做成“每个 VM 独立一份”：
                // - 默认：若不存在则从模板复制一份
                // - 安装模式：强制重置（每次挂载 ISO 安装都用干净的 BootOrder）
                std::string vmVarsPath = config.vmDir + "/edk2-vars.fd";
                bool needReset = config.installMode || !FileExists(vmVarsPath);
                if (needReset) {
                    bool copied = CopyFileTruncate(varsTemplatePath, vmVarsPath);
                    HilogPrint(std::string("QEMU: [FIRMWARE] VARS reset=") + (needReset ? "true" : "false") +
                               " template=" + varsTemplatePath + " -> " + vmVarsPath + " copied=" + (copied ? "true" : "false"));
                    if (!copied) {
                        // 兜底：复制失败时仍尝试使用模板（可能不可写，但至少不至于启动失败）
                        HilogPrint("QEMU: [FIRMWARE] ⚠️ VARS copy failed, fallback to template vars (may be read-only): " + varsTemplatePath);
                        vmVarsPath = varsTemplatePath;
                    }
                } else {
                    HilogPrint("QEMU: [FIRMWARE] Using existing per-VM VARS: " + vmVarsPath);
                }

                // 预检测：VARS 必须可写，否则 QEMU pflash 打开失败会直接 fatal→exit(1)
                (void)PreflightOpen("VARS(pflash,rw)", vmVarsPath, O_RDWR);

                args.push_back("-drive");
                args.push_back("file=" + vmVarsPath + ",if=pflash,format=raw,unit=1");
                HilogPrint(std::string("QEMU: [FIRMWARE] 添加 pflash(VARS) 参数: ") + vmVarsPath);
            } else {
                HilogPrint("QEMU: [FIRMWARE] ⚠️ 未找到 VARS 固件(edk2-arm-vars.fd)，继续仅使用 CODE 盘");
            }
        } else {
            // x86 使用 -bios 参数
            args.push_back("-bios");
            args.push_back(firmwarePath);
            HilogPrint(std::string("QEMU: [FIRMWARE] 添加 -bios 参数: ") + firmwarePath);
        }
    } else {
        HilogPrint("QEMU: [FIRMWARE] ⚠️ 固件不可用！VM 可能无法启动");
        HilogPrint("QEMU: [FIRMWARE] archType=" + config.archType);
    }
    
    // 磁盘配置
    // 注意：OHOS 版 QEMU 禁用了 linux-aio，简化磁盘参数避免崩溃
    if (FileExists(config.diskPath)) {
        const bool isQcow2 = IsQcow2FileQuick(config.diskPath);
        // 预检测：disk 打不开会导致 bdrv_open fatal→exit(1)
        (void)PreflightOpen(std::string("DISK(") + (isQcow2 ? "qcow2" : "raw") + ",rw)", config.diskPath, O_RDWR);
        if (isQcow2) {
            (void)PreflightQcow2Header(config.diskPath);
            // 额外 sanity：refcount table 不能是“全 0”。StartVm 已经会拦截并 reject，这里只打印日志。
            (void)PreflightQcow2RefcountTable(config.diskPath);
        }
        // 默认：virtio-blk-device 是 MMIO 版本，在 ARM virt 上更稳定
        deferredDiskArgs.push_back("-drive");
        deferredDiskArgs.push_back("file=" + config.diskPath + ",if=none,id=hd0,format=" +
                                   std::string(isQcow2 ? "qcow2" : "raw") + ",cache=writeback");
        deferredDiskArgs.push_back("-device");
        if (isWindowsGuest && config.archType == "aarch64" &&
            (config.machine.empty() || config.machine == "virt")) {
            // Windows on ARM virt：优先 SATA(AHCI) 以避免某些 PE/安装程序缺驱动导致“不显示磁盘/提示加载驱动”
            ensureSataController();
            std::string dev = "ide-hd,drive=hd0,bus=ahci.1";
            // 提供 bootindex：ISO=0，Disk=1；非安装模式则 Disk=0
            if (config.installMode && !config.isoPath.empty()) {
                dev += ",bootindex=1";
            } else {
                dev += ",bootindex=0";
            }
            deferredDiskArgs.push_back(dev);
            HilogPrint("QEMU: Disk configured with SATA(AHCI): " + config.diskPath);
        } else if (isWindowsGuest) {
            // NVMe：Windows 通常免驱（非 virt 或其他平台保持原策略）
            deferredDiskArgs.push_back("nvme,drive=hd0,serial=QEMUHMOS0001");
            HilogPrint("QEMU: Disk configured with NVMe: " + config.diskPath);
        } else {
        // 非 Windows：virtio-blk-device 是 MMIO 版本，在 ARM virt 上更稳定。
        // 关键：只有在存在 ISO 时才把硬盘放到 bootindex=1；否则硬盘必须是 0，
        // 否则部分固件/版本会导致“没有 boot option → 直接进 UEFI Shell”。
        std::string dev = "virtio-blk-device,drive=hd0";
        if (config.installMode && !config.isoPath.empty()) {
            dev += ",bootindex=1";
        } else {
            dev += ",bootindex=0";
        }
        deferredDiskArgs.push_back(dev);
        HilogPrint("QEMU: Disk configured with virtio-blk-device: " + config.diskPath);
        }
    } else {
        HilogPrint("QEMU: WARNING - Disk file not found: " + config.diskPath);
    }
    
    // ISO光驱配置
    // 注意：HarmonyOS 沙箱机制下，/storage/Users/currentUser/Download/ 等公共目录
    // 在 NAPI 层可能可以访问，但 QEMU 进程无法直接访问
    // 如果 ISO 在公共目录，需要先复制到沙箱目录
    if (!config.isoPath.empty()) {
        std::string isoPath = config.isoPath;
        bool isoAccessible = false;
        
        // 检查是否是 URI 格式（如 file://docs/storage/...），需要转换
        if (isoPath.find("file://") == 0) {
            HilogPrint("QEMU: [ISO] ISO path has file:// prefix, normalizing: " + isoPath);
            // 常见形式：file:///data/xxx 或 file://data/xxx
            isoPath = isoPath.substr(std::string("file://").size());
            // file:/// 开头会变成 /...（OK）；file://data/... 会变成 data/...（可能缺少 /），尽量补齐
            if (!isoPath.empty() && isoPath[0] != '/' && isoPath.find("data/") == 0) {
                isoPath = "/" + isoPath;
            }
            HilogPrint("QEMU: [ISO] ISO normalized path: " + isoPath);
        }
        
        // 检查是否是公共目录路径（沙箱外）
        // 仅将 /storage/* 视为公共目录；/data/storage/el2/base/haps/entry/files/* 属于应用沙箱，应视为内部路径
        bool isPublicPath = (isoPath.find("/storage/Users/") != std::string::npos ||
                            isoPath.find("/storage/media/") != std::string::npos);
        if (isPublicPath) {
            HilogPrint("QEMU: [WARN] ISO is in public directory (sandbox issue possible): " + isoPath);
        }

        // 可靠性说明：
        // - HarmonyOS 环境下，stat(FileExists) 有时会误报（尤其是沙箱路径/命名空间差异）
        // - 因此这里不以 FileExists 作为前置条件，直接以 open/read 作为最终可访问性判断
        if (!FileExists(isoPath)) {
            HilogPrint("QEMU: [WARN] ISO stat failed (FileExists=false): " + isoPath);
        }

        int isoFd = open(isoPath.c_str(), O_RDONLY);
        if (isoFd >= 0) {
            char testBuf[16];
            ssize_t readBytes = read(isoFd, testBuf, sizeof(testBuf));
            close(isoFd);

            if (readBytes > 0) {
                isoAccessible = true;
                HilogPrint("QEMU: [ISO] Verified readable: " + isoPath);
            } else {
                HilogPrint("QEMU: [WARN] ISO open succeeded but read failed: " + isoPath +
                           " readBytes=" + std::to_string(readBytes) + " errno=" + std::to_string(errno));
            }
        } else {
            HilogPrint("QEMU: [WARN] ISO open failed: " + isoPath + " errno=" + std::to_string(errno) +
                       " (" + std::string(strerror(errno)) + ")");
        }
        
        if (isoAccessible) {
            (void)PreflightOpen("ISO(raw,ro)", isoPath, O_RDONLY);
            // 重要：你反馈的现象是“UEFI Shell 里 map -r 看不到 ISO”，说明固件根本没有识别到光驱设备。
            // 在 aarch64 virt + edk2 场景里，最稳的方式是使用 virtio-blk-device（MMIO 版本），
            // 让固件通过 VirtioBlkDxe 识别 ISO（对应的文件系统由 UEFI 的 ISO9660 驱动提供）。
            //
            // 注意：ich9-ahci + ide-cd 依赖固件包含 AHCI/ATAPI 驱动，部分组合会导致 ISO 完全不可见。
            if (config.archType == "aarch64" && (config.machine.empty() || config.machine == "virt")) {
                if (isWindowsGuest) {
                    // Windows PE/安装程序：
                    // - 部分镜像对 XHCI/USB-storage 支持不稳定，会弹出 “A media driver ... is missing”
                    // - 这里优先用 SATA CDROM (AHCI) 提供安装介质（Windows 免驱）
                    ensureSataController();
                    args.push_back("-drive");
                    args.push_back("file=" + isoPath + ",if=none,format=raw,id=cd0,readonly=on,media=cdrom");
                    args.push_back("-device");
                    args.push_back("ide-cd,drive=cd0,bus=ahci.0,bootindex=0");
                    HilogPrint("QEMU: [ISO] Windows guest - ISO configured via SATA CDROM (AHCI): " + isoPath);

                    // 同时保留 USB-storage 作为固件/兼容性兜底（只读重复打开同一 ISO）
                    if (!xhciControllerAdded) {
                        args.push_back("-device");
                        args.push_back("qemu-xhci,id=xhci");
                        xhciControllerAdded = true;
                        HilogPrint("QEMU: [HW] XHCI controller added for USB fallback: qemu-xhci,id=xhci");
                    }
                    args.push_back("-drive");
                    args.push_back("file=" + isoPath + ",if=none,format=raw,id=usbstick,readonly=on");
                    args.push_back("-device");
                    args.push_back("usb-storage,bus=xhci.0,drive=usbstick,bootindex=2");
                    HilogPrint("QEMU: [ISO] Added USB-storage fallback for ISO (XHCI): " + isoPath);

                    // 打开 boot menu 便于调试；启动优先级由 bootindex 控制
                    args.push_back("-boot");
                    args.push_back("menu=on");
                } else {
                    // Linux 等来宾：最稳路径是 virtio-blk-device（MMIO），固件通常自带 VirtioBlkDxe。
                // 注意：不要使用 media=cdrom，避免块设备/光驱类型不匹配导致 fatal→exit(1)
                args.push_back("-drive");
                args.push_back("file=" + isoPath + ",if=none,format=raw,id=cd0,readonly=on");
                args.push_back("-device");
                args.push_back("virtio-blk-device,drive=cd0,bootindex=0");
                HilogPrint("QEMU: [ISO] ISO configured via virtio-blk-device (MMIO): " + isoPath);

                // 打开 boot menu 便于调试；启动优先级由 bootindex 控制
                args.push_back("-boot");
                args.push_back("menu=on");

                // 兼容性兜底：再额外挂一个 USB-storage（有些固件对 USB 更友好）
                // 注意：usb-storage 依赖 xhci.0 bus，因此必须先创建 qemu-xhci
                if (!xhciControllerAdded) {
                    args.push_back("-device");
                    args.push_back("qemu-xhci,id=xhci");
                    xhciControllerAdded = true;
                    HilogPrint("QEMU: [HW] XHCI controller added for USB fallback: qemu-xhci,id=xhci");
                }
                args.push_back("-drive");
                args.push_back("file=" + isoPath + ",if=none,format=raw,id=usbstick,readonly=on");
                args.push_back("-device");
                args.push_back("usb-storage,bus=xhci.0,drive=usbstick,bootindex=2");
                HilogPrint("QEMU: [ISO] Added USB-storage fallback for ISO: " + isoPath);
                }
            } else {
                // 其他架构/机型：保留传统 -cdrom 兼容路径
                args.push_back("-cdrom");
                args.push_back(isoPath);
                // 有 ISO 时也尽量从光驱启动
                args.push_back("-boot");
                args.push_back("order=dc,menu=on");
                HilogPrint("QEMU: [ISO] CDROM configured: " + isoPath);
            }
        } else {
            // ISO 不可访问，跳过 CDROM 配置
            // 这样 QEMU 不会因为打开 ISO 失败而 abort
            HilogPrint("QEMU: [WARN] ISO not accessible, SKIPPING CDROM to prevent crash: " + isoPath);
            HilogPrint("QEMU: [WARN] 提示：请将 ISO 文件复制到应用沙箱目录，或使用应用内文件选择器");
            WriteLog(config.logPath, "[WARNING] ISO file not accessible from QEMU process: " + isoPath);
            WriteLog(config.logPath, "[WARNING] CDROM skipped. Copy ISO to app sandbox or use internal file picker.");
        }
    } else {
        HilogPrint("QEMU: [ISO] No ISO path configured, skipping CDROM");
    }

    // install 模式下，为提高“默认从 ISO 引导”概率，把硬盘参数延后到 ISO 之后再追加
    if (!deferredDiskArgs.empty()) {
        if (deferDiskForInstallBoot) {
            HilogPrint("QEMU: [BOOT] Deferring DISK args until after ISO for install boot priority");
        }
        args.insert(args.end(), deferredDiskArgs.begin(), deferredDiskArgs.end());
    }

    // 启用 QEMU 自身的调试日志，方便定位崩溃原因
    // 注意：不要把 QEMU -D 输出写到 config.logPath(qemu.log)，因为 QEMU 会打开并可能清空该文件，
    // 这会把我们 WriteLog 记录的启动/退出信息覆盖掉，导致“导出 qemu.log 为空”。
    if (!config.vmDir.empty()) {
        const std::string qemuDebugLogPath = config.vmDir + "/qemu_debug.log";
        args.push_back("-D");
        args.push_back(qemuDebugLogPath);
        // 只打开少量关键项，避免日志过大：
        // - guest_errors: 来宾侧错误（如未实现指令/设备）
        // - cpu_reset:   捕获来宾触发重启（用于判断“转圈后重启/黑屏”到底是卡死还是 reboot）
        args.push_back("-d");
        args.push_back("guest_errors,cpu_reset");
        HilogPrint(std::string("QEMU: [DEBUG] QEMU debug log enabled: ") + qemuDebugLogPath);
        if (!config.logPath.empty()) {
            WriteLog(config.logPath, "[DEBUG] QEMU debug log enabled: " + qemuDebugLogPath + " (-d guest_errors,cpu_reset)");
        }
    }
    
    // ============================================================
    // 网络配置
    // - 增强启动(RDP): 需要完整端口转发（RDP 3389, SSH 22, etc）
    // - 普通启动(VNC): 基础网络即可
    // - 调试模式 / 用户选择无网卡: 关闭网络
    // ============================================================
    
    // 判断是否需要增强网络（通过display参数推断启动模式）
    bool needEnhancedNetwork = !config.nographic && 
                               config.display.find("websocket") == std::string::npos;

    // 从高级配置中读取网卡类型
    std::string netDev = config.networkDevice;
    if (netDev.empty()) {
        // 默认使用 virtio-net-device (MMIO 版本) - ARM virt 机器的最佳选择
        netDev = "virtio-net-device";
        HilogPrint("QEMU: [NET] Using default virtio-net-device (MMIO)");
    }
    
    // 自动转换 PCI 版本到 MMIO 版本（PCI 版本在 ARM virt 上有问题）
    if (netDev == "virtio-net-pci") {
        HilogPrint("QEMU: [NET] Converting virtio-net-pci to virtio-net-device (MMIO)");
        netDev = "virtio-net-device";
    }
    bool netDisabled = (netDev == "none");

    // 构建网卡设备参数
    // 对于 ARM virt 机器，优先使用 MMIO 版本的 virtio 设备（更稳定）
    // PCI 版本（virtio-*-pci）在某些配置下有初始化问题
    auto buildNetDeviceArg = [&](const std::string& dev) -> std::string {
        if (dev == "virtio-net" || dev == "virtio-net-pci" || dev == "virtio-net-device") {
            // 使用 MMIO 版本而不是 PCI 版本
            HilogPrint("QEMU: [NET] Using virtio-net-device (MMIO) for ARM virt");
            return "virtio-net-device,netdev=n0";
        } else if (dev == "e1000") {
            HilogPrint("QEMU: [NET] Using e1000 network device");
            return "e1000,netdev=n0";
        } else if (dev == "e1000e") {
            HilogPrint("QEMU: [NET] Using e1000e network device");
            return "e1000e,netdev=n0";
        } else if (dev == "rtl8139") {
            HilogPrint("QEMU: [NET] Using rtl8139 network device");
            return "rtl8139,netdev=n0";
        } else if (dev == "ne2k_pci") {
            HilogPrint("QEMU: [NET] Using ne2k_pci network device");
            return "ne2k_pci,netdev=n0";
        } else if (dev == "vmxnet3") {
            HilogPrint("QEMU: [NET] Using vmxnet3 network device");
            return "vmxnet3,netdev=n0";
        } else if (dev == "usb-net") {
            HilogPrint("QEMU: [NET] Using usb-net network device");
            return "usb-net,netdev=n0";
        }
        // 未知设备：直接使用用户输入的值
        HilogPrint(std::string("QEMU: [NET] Using custom network device: ") + dev);
        return dev + ",netdev=n0";
    };
    
    if (config.nographic || netDisabled) {
        // 调试模式或用户显式关闭网络：禁用网络
        HilogPrint("QEMU: [NET] Network disabled (nographic or user disabled)");
        args.push_back("-net");
        args.push_back("none");
    } else if (needEnhancedNetwork) {
        // 增强启动：完整端口转发（支持RDP/SSH/HTTP等）
        HilogPrint(std::string("QEMU: [NET] Enhanced mode - full port forwarding enabled, netDev=") + netDev);
        std::string netdev = "user,id=n0";
        netdev += ",hostfwd=tcp:127.0.0.1:3390-:3389";  // RDP
        netdev += ",hostfwd=tcp:127.0.0.1:2222-:22";    // SSH
        netdev += ",hostfwd=tcp:127.0.0.1:8080-:80";    // HTTP
        netdev += ",hostfwd=tcp:127.0.0.1:8443-:443";   // HTTPS
    
        args.push_back("-netdev");
        args.push_back(netdev);
    
        // 添加网卡设备（根据高级设置选择具体型号）
        args.push_back("-device");
        args.push_back(buildNetDeviceArg(netDev));
    } else {
        // 普通启动(VNC)：基础用户网络
        HilogPrint(std::string("QEMU: [NET] Standard mode - basic user network, netDev=") + netDev);
        args.push_back("-netdev");
        args.push_back("user,id=n0");
        
        // 添加网卡设备
        args.push_back("-device");
        args.push_back(buildNetDeviceArg(netDev));
    }
    
    // ============================================================
    // 显示 / 控制台配置
    // - 当 config.nographic=true 时：完全无头 + 串口通过 stdio（TTL 调试用）
    // - 当 config.nographic=false 时：使用 VNC 显示（需要 keymaps 文件支持）
    // ============================================================
    // 
    // VNC 崩溃修复说明：
    // VNC 初始化时需要加载 keymaps/en-us 键盘映射文件，否则会 abort。
    // 解决方案：通过 -L 参数指定包含 keymaps 的数据目录。
    // 如果 keymaps 不存在，则回退到 -display none + virtio-gpu + screendump
    // ============================================================
    
    if (config.nographic) {
        HilogPrint("QEMU: [DEBUG] Headless mode enabled (nographic + serial TCP)");
        args.push_back("-nographic");
        // 串口使用TCP socket，可以通过 telnet localhost 4321 连接
        args.push_back("-serial");
        args.push_back("tcp:127.0.0.1:4321,server,nowait");
        HilogPrint("QEMU: [DEBUG] Serial console on tcp:127.0.0.1:4321");
        // 额外兜底：把串口内容落盘，便于排查“卡在 TianoCore/UEFI 阶段”
        // 注意：路径包含空格也没关系（argv 单独一项，不会被再次 split）
        args.push_back("-serial");
        args.push_back("file:" + config.vmDir + "/serial.log");
        HilogPrint("QEMU: [DEBUG] Serial log file: " + config.vmDir + "/serial.log");
    } else {
        // 检查 keymaps 是否可用，决定是否启用 VNC
        bool vncAvailable = false;
        std::string displayConfig = config.display;
        if (displayConfig.empty()) {
            displayConfig = "vnc=0.0.0.0:1";  // 默认 VNC 监听在 5901 端口（0.0.0.0 允许其他应用连接）
        }

        // keymaps 存在才认为 VNC 可用
        // 必须在 C++ 层实际验证文件存在
        if (!qemuDataDir.empty()) {
            std::string keymapPath = qemuDataDir + "/keymaps/en-us";
            
            // 用 fopen 验证文件存在且可读
            FILE* f = fopen(keymapPath.c_str(), "r");
            if (f) {
                // 检查文件大小
                fseek(f, 0, SEEK_END);
                long size = ftell(f);
                fclose(f);
                
                if (size > 1000) {  // en-us 应该 > 1KB
                vncAvailable = true;
                    HilogPrint("QEMU: [VNC_DEBUG] keymaps VERIFIED: " + keymapPath + " (" + std::to_string(size) + " bytes)");
            } else {
                    HilogPrint("QEMU: [VNC_DEBUG] keymaps file too small: " + std::to_string(size) + " bytes");
            }
        } else {
                HilogPrint("QEMU: [VNC_DEBUG] keymaps NOT FOUND: " + keymapPath);
                HilogPrint("QEMU: [VNC_DEBUG] errno=" + std::to_string(errno) + " (" + std::string(strerror(errno)) + ")");
            }
        } else {
            HilogPrint("QEMU: [VNC_DEBUG] qemuDataDir empty, VNC disabled");
        }
        
        if (vncAvailable) {
            // VNC 可用：使用 VNC 显示
            HilogPrint("QEMU: [DEBUG] VNC enabled (keymaps available)");
            
            // 解析显示配置
            
            // 检查是否是 VNC 配置
            if (displayConfig.find("vnc") != std::string::npos) {
                // 使用 -vnc 参数
                // 格式：-vnc <host>:<display>,websocket=<port>
                // (noVNC 已移除) 仅保留原生 VNC (RFB)
                std::string vncArg = displayConfig;
                if (vncArg.substr(0, 4) == "vnc=") {
                    vncArg = vncArg.substr(4);  // 移除 "vnc=" 前缀
                }
                
                // (noVNC 已移除) 不再支持 websocket 方式，若包含则移除，强制使用 RFB
                const std::string wsKey = "websocket=";
                size_t wsPos = vncArg.find(wsKey);
                if (wsPos != std::string::npos) {
                    // 删除 ",websocket=xxxx" 或 "websocket=xxxx" 片段（尽量宽容）
                    size_t start = wsPos;
                    if (start > 0 && vncArg[start - 1] == ',') start -= 1;
                    size_t end = vncArg.find(',', wsPos);
                    if (end == std::string::npos) end = vncArg.size();
                    vncArg.erase(start, end - start);
                    HilogPrint(std::string("QEMU: [WARN] websocket parameter removed (noVNC removed), vncArg=") + vncArg);
                } else {
                    HilogPrint(std::string("QEMU: [DEBUG] VNC display (RFB): ") + vncArg);
                }
                
                args.push_back("-vnc");
                args.push_back(vncArg);
            } else {
                // 其他显示类型
                args.push_back("-display");
                args.push_back(displayConfig);
            }
        
            HilogPrint("QEMU: [DEBUG] VNC mode enabled");
        } else {
            // VNC 不可用：回退到无显示模式
            HilogPrint("QEMU: [DEBUG] VNC disabled (keymaps not found), using headless mode");
            args.push_back("-display");
            args.push_back("none");
            // 不添加任何显示设备，避免崩溃
            displayConfig = "none";  // 标记为无显示模式
        }
       
        // ============================================================
        // 显卡设备选择（关键修复点）
        // ARM64 virt 机器如果没有提供可被 UEFI/来宾识别的图形设备(GOP/framebuffer)，
        // VNC 看到的往往是黑底白字的文本控制台（例如 “Parallel Console”）。
        // 因此：当启用 VNC 且用户未指定时，为 aarch64 默认添加 virtio-gpu-device(MMIO)，
        // 这是 virt 机器上最常见/最兼容的图形设备路径之一。
        // ============================================================
        std::string effectiveDisplayDev = config.displayDevice;

        // 安装阶段(aarch64)兜底：强制使用 ramfb，避免 EDK2/TianoCore 阶段
        // virtio-gpu 无 GOP 导致 “Display Output Is Not Active”。
        // 注意：这里只影响本次启动参数，不会修改用户持久化的显示设备偏好。
        if (config.installMode && config.archType == "aarch64") {
            if (effectiveDisplayDev != "ramfb") {
                HilogPrint(std::string("QEMU: [HW] install(aarch64) force display device = ramfb (requested=") +
                           (config.displayDevice.empty() ? "(empty)" : config.displayDevice) + ")");
            }
            effectiveDisplayDev = "ramfb";
        }
        if (displayConfig != "none") {
            // 注意：UI 侧历史上默认会传 'none'，但这会导致 VNC 只能看到串口控制台（Parallel Console）。
            // 对于 aarch64 + VNC，我们把 'none' 也当作“未指定”，自动选择可用的图形设备。
            if (effectiveDisplayDev.empty() || effectiveDisplayDev == "auto" ||
                (config.archType == "aarch64" && effectiveDisplayDev == "none")) {
                if (config.archType == "aarch64") {
                    effectiveDisplayDev = "virtio-gpu";
                    HilogPrint("QEMU: [HW] aarch64 VNC default display device = virtio-gpu-device (via virtio-gpu)");
                }
            }
        }

        // 根据高级设置选择显卡设备（仅在启用图形时）
        // 直接使用用户选择的设备，不做强制回退
        // 如果设备不兼容，QEMU 会报错，用户可以据此选择其他设备
        if (displayConfig != "none" && !effectiveDisplayDev.empty() && effectiveDisplayDev != "none") {
            std::string displayDev = effectiveDisplayDev;
            std::string qemuDisplayDev;

            if (displayDev == "virtio-gpu" || displayDev == "virtio-gpu-pci") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "virtio-gpu-device";
                    HilogPrint("QEMU: [HW] Using virtio-gpu-device (MMIO) as display device (aarch64)");
                } else {
                    qemuDisplayDev = "virtio-gpu-pci";
                    HilogPrint("QEMU: [HW] Using virtio-gpu-pci as display device");
                }
            } else if (displayDev == "virtio-gpu-gl" || displayDev == "virtio-gpu-gl-pci") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "ramfb";
                    HilogPrint("QEMU: [HW] WARNING: virtio-gpu-gl not recommended on aarch64, fallback to ramfb");
                } else {
                    qemuDisplayDev = "virtio-gpu-gl-pci";
                    HilogPrint("QEMU: [HW] Using virtio-gpu-gl-pci as display device");
                }
            } else if (displayDev == "ramfb") {
                qemuDisplayDev = "ramfb";
                HilogPrint("QEMU: [HW] Using ramfb as display device");
            } else if (displayDev == "virtio-vga") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "ramfb";
                    HilogPrint("QEMU: [HW] WARNING: virtio-vga is PCI/x86 oriented, fallback to ramfb on aarch64");
                } else {
                    qemuDisplayDev = "virtio-vga";
                    HilogPrint("QEMU: [HW] Using virtio-vga as display device (user selected)");
                }
            } else if (displayDev == "qxl-vga") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "ramfb";
                    HilogPrint("QEMU: [HW] WARNING: qxl-vga is PCI/x86 oriented, fallback to ramfb on aarch64");
                } else {
                    qemuDisplayDev = "qxl-vga";
                    HilogPrint("QEMU: [HW] Using qxl-vga as display device (user selected)");
                }
            } else if (displayDev == "cirrus-vga") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "ramfb";
                    HilogPrint("QEMU: [HW] WARNING: cirrus-vga is PCI/x86 oriented, fallback to ramfb on aarch64");
                } else {
                    qemuDisplayDev = "cirrus-vga";
                    HilogPrint("QEMU: [HW] Using cirrus-vga as display device (user selected)");
                }
            } else if (displayDev == "VGA") {
                if (config.archType == "aarch64") {
                    qemuDisplayDev = "ramfb";
                    HilogPrint("QEMU: [HW] WARNING: VGA is PCI/x86 oriented, fallback to ramfb on aarch64");
                } else {
                    qemuDisplayDev = "VGA";
                    HilogPrint("QEMU: [HW] Using VGA as display device (user selected)");
                }
            } else {
                // 未知设备：直接使用用户输入的值
                qemuDisplayDev = displayDev;
                HilogPrint(std::string("QEMU: [HW] Using custom display device: ") + displayDev);
            }

            if (!qemuDisplayDev.empty()) {
                args.push_back("-device");
                args.push_back(qemuDisplayDev);
                HilogPrint(std::string("QEMU: [HW] Final display device: ") + qemuDisplayDev + " (requested=" +
                           (config.displayDevice.empty() ? "(empty)" : config.displayDevice) + ")");
            }
        } else {
            HilogPrint("QEMU: [HW] No extra display device configured");
        }

        // ============================================================
        // 输入设备（关键修复点）
        //
        // 现象：VNC 能显示画面，但鼠标/键盘不工作。
        // 原因：VNC 只是远程显示与“输入注入”的通道，但 QEMU 内必须有可接收输入事件的设备。
        // 对于 aarch64 的 virt 机型，如果不显式添加 USB/virtio 输入设备，来宾侧可能完全收不到输入。
        //
        // 处理：在启用图形输出（displayConfig != "none"）且 machine=virt 时，默认挂载：
        //   - qemu-xhci (USB 控制器)
        //   - usb-tablet (绝对坐标指针，鼠标更顺滑)
        //   - usb-kbd (键盘)
        //
        // 注意：仅对 virt 自动启用，避免对其他 machine 造成兼容性风险。
        // ============================================================
        if (displayConfig != "none") {
            std::string machine = config.machine.empty() ? "virt" : config.machine;
            if (machine == "virt") {
                if (!xhciControllerAdded) {
                    args.push_back("-device");
                    args.push_back("qemu-xhci,id=xhci");
                    xhciControllerAdded = true;
                }
                args.push_back("-device");
                args.push_back("usb-tablet,bus=xhci.0");
                args.push_back("-device");
                args.push_back("usb-kbd,bus=xhci.0");
                HilogPrint("QEMU: [HW] USB input enabled for VNC: qemu-xhci + usb-tablet + usb-kbd");
            } else {
                HilogPrint("QEMU: [HW] NOTE: USB input auto-config is only enabled for machine=virt; current machine=" +
                           machine + " (VNC input may be unavailable unless you add input devices manually)");
            }
        }

        // 串口绑定到 TCP socket，用户可以通过网络连接进行交互
        // 格式：telnet localhost 4321
        args.push_back("-serial");
        args.push_back("tcp:127.0.0.1:4321,server,nowait");
        HilogPrint("QEMU: [DEBUG] Serial console on tcp:127.0.0.1:4321");
        // 同时把串口落盘，排查 UEFI/Windows 引导卡点
        args.push_back("-serial");
        args.push_back("file:" + config.vmDir + "/serial.log");
        HilogPrint("QEMU: [DEBUG] Serial log file: " + config.vmDir + "/serial.log");
    }

    // 声卡配置
    // 注意：sb16, es1370, gus, adlib, cs4231a 是 ISA 设备，只存在于 x86 架构
    // 在 ARM64 (qemu-system-aarch64) 上使用会导致崩溃
    if (!config.audioDevice.empty() && config.audioDevice != "none") {
        // 使用自定义 HarmonyOS 音频后端（OHAudio/AudioKit），让 VNC 也能听到声音，并支持麦克风回传。
        const std::string audiodevId = "snd0";
        args.push_back("-audiodev");
        args.push_back("aether-soundkit-hmos,id=" + audiodevId +
                       ",out.frequency=48000,out.channels=2,out.format=s16" +
                       ",in.frequency=48000,in.channels=1,in.format=s16");
        HilogPrint("QEMU: [HW] Audio backend = aether-soundkit-hmos (audiodev id=" + audiodevId + ")");

        std::string audioDev = config.audioDevice;
        
        // ISA 设备黑名单（x86-only，在 ARM64 会崩溃）
        bool isIsaDevice = (audioDev == "sb16" || audioDev == "es1370" || 
                           audioDev == "gus" || audioDev == "adlib" || 
                           audioDev == "cs4231a");
        
        if (isIsaDevice && config.archType != "x86_64" && config.archType != "i386") {
            // ISA 设备在 ARM64 上不可用，跳过并记录警告
            HilogPrint("QEMU: [WARNING] Audio device '" + audioDev + "' is ISA/x86-only, SKIPPING on ARM64 to prevent crash!");
        } else if (audioDev == "hda" || audioDev == "intel-hda") {
            // intel-hda 是 HDA 控制器，需要搭配 hda-duplex codec 才能工作
            args.push_back("-device");
            args.push_back("intel-hda");
            args.push_back("-device");
            args.push_back("hda-duplex,audiodev=" + audiodevId);
            HilogPrint("QEMU: [HW] Audio device = HDA (intel-hda + hda-duplex)");
        } else if (audioDev == "ich9-intel-hda" || audioDev == "ich9-hda") {
            args.push_back("-device");
            args.push_back("ich9-intel-hda");
            args.push_back("-device");
            args.push_back("hda-duplex,audiodev=" + audiodevId);
            HilogPrint("QEMU: [HW] Audio device = ICH9 HDA (ich9-intel-hda + hda-duplex)");
        } else if (audioDev == "ac97") {
            args.push_back("-device");
            args.push_back("AC97,audiodev=" + audiodevId);
            HilogPrint("QEMU: [HW] Audio device = AC97");
        } else if (audioDev == "sb16" || audioDev == "es1370") {
            // 如果是 x86 架构，允许使用 ISA 设备
            args.push_back("-device");
            args.push_back(audioDev);
            HilogPrint("QEMU: [HW] Audio device = " + audioDev + " (ISA device, x86 mode)");
        } else {
            // 其他设备：直接使用用户输入的值
            args.push_back("-device");
            args.push_back(audioDev);
            HilogPrint(std::string("QEMU: [HW] Audio device = ") + audioDev + " (custom)");
        }
    } else {
        HilogPrint("QEMU: [HW] Audio disabled (no audio device)");
    }
    
    // 共享目录配置 (virtio-9p)
    // 暂时禁用，因为 virtio-9p 在某些情况下可能导致设备初始化失败
    // TODO: 在稳定后重新启用
    // std::string sharedPath = config.sharedDir;
    // if (sharedPath.empty()) {
    //     sharedPath = "/data/storage/el2/base/com.cloudshin.aetherengine/files/虚拟机磁盘/" + config.name;
    // }
    // struct stat st;
    // if (stat(sharedPath.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
    //     args.push_back("-fsdev");
    //     args.push_back("local,id=shared0,path=" + sharedPath + ",security_model=mapped-xattr");
    //     args.push_back("-device");
    //     args.push_back("virtio-9p-pci,fsdev=shared0,mount_tag=hostshare");
    // }
    HilogPrint("QEMU: [DEBUG] Shared folder disabled for stability");

    // QMP 监控接口 (用于查询 VM 状态)
    std::string qmpSocketPath = "/data/storage/el2/base/haps/entry/files/vms/" + config.name + "/qmp.sock";
    args.push_back("-qmp");
    args.push_back("unix:" + qmpSocketPath + ",server,nowait");
    
    // 监控接口：采用 QMP + guest 串口，主 monitor 关闭
    args.push_back("-monitor");
    args.push_back("none");
    
    // 暂时禁用 QEMU 日志，避免潜在的文件系统问题
    // args.push_back("-d");
    // args.push_back("guest_errors,unimp");
    
    return args;
}

// 写入日志
// 封装：同时写文件与Hilogs，便于 grep QEMU
static void HilogPrint(const std::string& message)
{
    // 添加空指针保护 - 确保 message 内容有效
    if (message.empty()) {
        return;  // 空消息不打印
    }
    
    const char* msg = message.c_str();
    if (!msg) {
        return;  // 极端情况保护
    }
    
#if defined(__OHOS__)
    // 使用 OH_LOG_Print
    // 注意：不检查 &OH_LOG_Print != nullptr，因为这个检查总是 true
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "QEMU_CORE", "%{public}s", msg);
    return;
#endif
    // 回退：stderr 也会被系统日志采集
    std::fprintf(stderr, "[QEMU_CORE] %s\n", msg);
}

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

        // 输出到系统日志，便于 on-device 调试
        HilogPrint(formattedMessage);
    } catch (...) {
        // 忽略日志写入错误
    }
}

// 动态加载 QEMU 核心库并调用其 API
//
// 注意：在 OHOS 侧，我们用 dlopen + dlsym 访问 QEMU 核心入口。
// 但 QEMU 的 qemu_init/qemu_main_loop/qemu_cleanup 等符号可能不在 dynsym（nm 可见，但 nm -D 看不到），
// 因此 QEMU 核心库会额外导出一组 qemu_hmos_* shim 符号供我们 fallback。
using qemu_init_fn = void (*)(int argc, char **argv);
using qemu_main_loop_fn = int (*)(void);
using qemu_cleanup_fn = void (*)(int status);
using qemu_shutdown_fn = void (*)(int reason);
using qemu_hmos_get_last_exit_code_fn = int (*)(void);
using qemu_hmos_clear_last_exit_code_fn = void (*)(void);

static void *g_qemu_core_handle = nullptr;
static qemu_init_fn g_qemu_core_qemu_init = nullptr;
static qemu_main_loop_fn g_qemu_core_main_loop = nullptr;
static qemu_cleanup_fn g_qemu_core_cleanup = nullptr;
static qemu_shutdown_fn g_qemu_core_shutdown = nullptr;
static qemu_hmos_get_last_exit_code_fn g_qemu_core_get_last_exit_code = nullptr;
static qemu_hmos_clear_last_exit_code_fn g_qemu_core_clear_last_exit_code = nullptr;
static bool g_qemu_initialized = false;

// 读取 dlerror() 的安全封装，避免重复调用导致 nullptr
static std::string SafeDlError()
{
    const char* err = dlerror();
    return err ? std::string(err) : std::string("unknown error");
}

static std::string Dirname(const std::string& path)
{
    size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) return std::string();
    return path.substr(0, pos);
}

// Threadsafe function 回调：在主线程中 resolve/reject Promise
static void VmStartCallbackOnMainThread(napi_env env, napi_value js_callback, void* context, void* data)
{
    (void)js_callback;
    (void)context;
    
    VmStartCallbackData* callbackData = static_cast<VmStartCallbackData*>(data);
    if (!callbackData) return;
    
    napi_value result;
    if (callbackData->error == VmStartError::SUCCESS) {
        // 成功：resolve 返回 exitCode
        napi_create_object(env, &result);
        napi_value exitCodeVal, vmNameVal;
        napi_create_int32(env, callbackData->exitCode, &exitCodeVal);
        napi_create_string_utf8(env, callbackData->vmName.c_str(), NAPI_AUTO_LENGTH, &vmNameVal);
        napi_set_named_property(env, result, "exitCode", exitCodeVal);
        napi_set_named_property(env, result, "vmName", vmNameVal);
        napi_resolve_deferred(env, callbackData->deferred, result);
    } else {
        // 失败：reject 返回错误信息
        napi_value errorObj;
        napi_create_object(env, &errorObj);
        
        napi_value codeVal, messageVal, vmNameVal;
        napi_create_int32(env, static_cast<int>(callbackData->error), &codeVal);
        napi_create_string_utf8(env, callbackData->errorMessage.c_str(), NAPI_AUTO_LENGTH, &messageVal);
        napi_create_string_utf8(env, callbackData->vmName.c_str(), NAPI_AUTO_LENGTH, &vmNameVal);
        
        napi_set_named_property(env, errorObj, "code", codeVal);
        napi_set_named_property(env, errorObj, "message", messageVal);
        napi_set_named_property(env, errorObj, "vmName", vmNameVal);
        
        napi_reject_deferred(env, callbackData->deferred, errorObj);
    }
    
    delete callbackData;
}

// 辅助函数：在 VM 线程中调用 threadsafe function
static void NotifyVmStartResult(const std::string& vmName, VmStartError error, int exitCode, const std::string& errorMessage)
{
    std::lock_guard<std::mutex> lock(g_vmMutex);
    auto it = g_vmStartCallbacks.find(vmName);
    if (it == g_vmStartCallbacks.end()) return;
    
    auto* data = new VmStartCallbackData();
    data->env = it->second.env;
    data->deferred = it->second.deferred;
    data->vmName = vmName;
    data->error = error;
    data->exitCode = exitCode;
    data->errorMessage = errorMessage;
    
    napi_call_threadsafe_function(it->second.tsfn, data, napi_tsfn_blocking);
    napi_release_threadsafe_function(it->second.tsfn, napi_tsfn_release);
    g_vmStartCallbacks.erase(it);
}

static void TryLoadCoreFromSelfDir(const std::string& logPath)
{
    if (g_qemu_core_handle) return;
    Dl_info info{};
    if (dladdr((void*)&TryLoadCoreFromSelfDir, &info) != 0 && info.dli_fname) {
        std::string self = info.dli_fname;
        std::string dir = Dirname(self);
        if (!dir.empty()) {
            std::string abs = dir + "/libqemu_full.so";
            g_qemu_core_handle = dlopen(abs.c_str(), RTLD_NOW);
            if (g_qemu_core_handle) {
                WriteLog(logPath, std::string("[QEMU] dlopen from self dir: ") + abs);
            } else {
                WriteLog(logPath, std::string("[QEMU] dlopen self dir failed: ") + SafeDlError());
            }
        }
    }
}

// 当前加载的架构（用于避免重复加载相同架构）
static std::string g_loaded_arch;

// 根据架构获取 .so 文件名
static std::string GetQemuLibName(const std::string& archType) {
    // 支持的架构: aarch64, x86_64, i386
    if (archType == "x86_64" || archType == "x86-64") {
        return "libqemu_x86_64.so";
    } else if (archType == "i386" || archType == "x86" || archType == "i686") {
        return "libqemu_i386.so";
    } else {
        // 默认使用 ARM64
        return "libqemu_aarch64.so";
    }
}

// ============ 诊断：详细追踪 dlopen 过程 ============
// 支持多架构加载：根据 archType 加载对应的 libqemu_{arch}.so
static void EnsureQemuCoreLoaded(const std::string& logPath, const std::string& archType = "aarch64")
{
    std::string libName = GetQemuLibName(archType);
    
    // 如果已经加载了相同架构的库，直接返回
    if (g_qemu_core_qemu_init && g_loaded_arch == archType) {
        HilogPrint("QEMU: Library already loaded for arch: " + archType);
        return;
    }
    
    // 如果加载了不同架构的库，需要先卸载
    if (g_qemu_core_handle && g_loaded_arch != archType) {
        HilogPrint("QEMU: Unloading previous library for arch: " + g_loaded_arch);
        WriteLog(logPath, "[QEMU] Switching architecture from " + g_loaded_arch + " to " + archType);
        
        // 清理之前加载的函数指针
        g_qemu_core_qemu_init = nullptr;
        g_qemu_core_main_loop = nullptr;
        g_qemu_core_cleanup = nullptr;
        g_qemu_core_shutdown = nullptr;
        g_qemu_core_get_last_exit_code = nullptr;
        g_qemu_core_clear_last_exit_code = nullptr;
        
        // 卸载之前的库
        dlclose(g_qemu_core_handle);
        g_qemu_core_handle = nullptr;
        g_loaded_arch.clear();
    }
    
    if (g_qemu_core_qemu_init) return;
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", "========== 开始加载 %s ==========", libName.c_str());
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", "目标架构: %s", archType.c_str());
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", "警告: 此操作将执行 ~748 个 constructor 函数");
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", "如果下一条日志没出现，说明 dlopen 导致崩溃");
    
    HilogPrint("QEMU: Starting core library loading process for " + archType);
    WriteLog(logPath, "[QEMU] Loading library: " + libName + " for arch: " + archType);
    
    // 直接按名称加载，前提是 core so 已随 HAP 打包
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", ">>> 即将调用 dlopen(\"%s\", RTLD_NOW) <<<", libName.c_str());
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", ">>> 如果没有后续日志，崩溃发生在 dlopen/constructor 中 <<<");
    
    HilogPrint("QEMU: Attempting dlopen " + libName);
    g_qemu_core_handle = dlopen(libName.c_str(), RTLD_NOW);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", ">>> dlopen 返回: %p <<<", g_qemu_core_handle);
    
    // 如果直接加载失败，尝试兼容性名称 libqemu_full.so
    if (!g_qemu_core_handle && archType == "aarch64") {
        HilogPrint("QEMU: Trying fallback libqemu_full.so");
        g_qemu_core_handle = dlopen("libqemu_full.so", RTLD_NOW);
    }
    
    if (!g_qemu_core_handle) {
        std::string err = SafeDlError();
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_LOAD", "dlopen 失败: %s", err.c_str());
        WriteLog(logPath, std::string("[QEMU] dlopen " + libName + " failed: ") + err);
        HilogPrint(std::string("QEMU: dlopen " + libName + " failed: ") + err);
        
        // ============ 优先从 files 目录加载（ArkTS 层已提取 rawfile 到此处）============
        std::string filesPath = "/data/storage/el2/base/haps/entry/files/" + libName;
        HilogPrint("QEMU: Attempting dlopen from files: " + filesPath);
        g_qemu_core_handle = dlopen(filesPath.c_str(), RTLD_NOW);
        if (g_qemu_core_handle) {
            WriteLog(logPath, std::string("[QEMU] dlopen from files SUCCESS: ") + filesPath);
            HilogPrint("QEMU: Successfully loaded from files dir!");
        } else {
            std::string filesErr = SafeDlError();
            WriteLog(logPath, std::string("[QEMU] dlopen files failed: ") + filesErr);
            HilogPrint(std::string("QEMU: dlopen files failed: ") + filesErr);
            
            // 尝试从当前模块同目录加载
            HilogPrint("QEMU: Attempting TryLoadCoreFromSelfDir");
            TryLoadCoreFromSelfDir(logPath);
            if (!g_qemu_core_handle) {
                // 尝试从应用libs目录加载（可能因命名空间被拒绝）
                std::string libsPath = "/data/app/el2/100/base/com.cloudshin.aetherengine/haps/entry/libs/arm64-v8a/" + libName;
                HilogPrint("QEMU: Attempting dlopen from libs: " + libsPath);
                g_qemu_core_handle = dlopen(libsPath.c_str(), RTLD_NOW);
                if (g_qemu_core_handle) {
                    WriteLog(logPath, std::string("[QEMU] dlopen from libs: ") + libsPath);
                    HilogPrint("QEMU: Successfully loaded from libs");
                } else {
                    std::string libsErr = SafeDlError();
                    WriteLog(logPath, std::string("[QEMU] dlopen libs failed: ") + libsErr);
                    HilogPrint(std::string("QEMU: dlopen libs failed: ") + libsErr);
                    
                    // 所有尝试都失败了
                    WriteLog(logPath, "[QEMU] Core library not loaded. Aborting start.");
                    WriteLog(logPath, "[QEMU] Please ensure " + libName + " is properly installed in the app bundle.");
                    return;
                }
            } else {
                HilogPrint("QEMU: Successfully loaded from self dir");
            }
        }
    } else {
        HilogPrint("QEMU: Successfully loaded " + libName + " directly");
    }
    
    // 记录已加载的架构
    g_loaded_arch = archType;

    // ============ 诊断：详细追踪 dlsym 过程 ============
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> 开始 dlsym 查找符号 <<<");
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> handle = %p <<<", g_qemu_core_handle);
    
    // 清除之前的错误
    dlerror();
    
    // 加载 QEMU API 符号 - 逐个加载并检查
    // 说明：qemu_init/qemu_main_loop/qemu_cleanup 可能不在 dynsym，
    //      优先查原始符号，失败则回退到 qemu_hmos_* shim。
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> 查找 qemu_init (or shim) <<<");
    // 关键：在 OHOS 上必须优先使用 shim（它在 QEMU core so 内部拦截 exit(1)，避免 appspawn SIGABRT）
    g_qemu_core_qemu_init = reinterpret_cast<qemu_init_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_qemu_init"));
    if (!g_qemu_core_qemu_init) {
        g_qemu_core_qemu_init = reinterpret_cast<qemu_init_fn>(dlsym(g_qemu_core_handle, "qemu_init"));
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> qemu_init = %p <<<", (void*)g_qemu_core_qemu_init);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> 查找 qemu_main_loop (or shim) <<<");
    g_qemu_core_main_loop = reinterpret_cast<qemu_main_loop_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_qemu_main_loop"));
    if (!g_qemu_core_main_loop) {
    g_qemu_core_main_loop = reinterpret_cast<qemu_main_loop_fn>(dlsym(g_qemu_core_handle, "qemu_main_loop"));
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> qemu_main_loop = %p <<<", (void*)g_qemu_core_main_loop);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> 查找 qemu_cleanup (or shim) <<<");
    g_qemu_core_cleanup = reinterpret_cast<qemu_cleanup_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_qemu_cleanup"));
    if (!g_qemu_core_cleanup) {
    g_qemu_core_cleanup = reinterpret_cast<qemu_cleanup_fn>(dlsym(g_qemu_core_handle, "qemu_cleanup"));
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> qemu_cleanup = %p <<<", (void*)g_qemu_core_cleanup);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> 查找 qemu_system_shutdown_request (or shim) <<<");
    g_qemu_core_shutdown =
        reinterpret_cast<qemu_shutdown_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_qemu_system_shutdown_request"));
    if (!g_qemu_core_shutdown) {
    g_qemu_core_shutdown = reinterpret_cast<qemu_shutdown_fn>(dlsym(g_qemu_core_handle, "qemu_system_shutdown_request"));
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> qemu_system_shutdown_request = %p <<<", (void*)g_qemu_core_shutdown);

    // 可选：从 QEMU core shim 里读取 “是否触发 exit(1)” 的信息
    g_qemu_core_get_last_exit_code =
        reinterpret_cast<qemu_hmos_get_last_exit_code_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_get_last_exit_code"));
    g_qemu_core_clear_last_exit_code =
        reinterpret_cast<qemu_hmos_clear_last_exit_code_fn>(dlsym(g_qemu_core_handle, "qemu_hmos_clear_last_exit_code"));
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_SYM", ">>> dlsym 完成 <<<");

    // 添加详细的调试日志
    if (!g_qemu_core_qemu_init) {
        std::string err = SafeDlError();
        WriteLog(logPath, std::string("[QEMU] dlsym qemu_init (and shim) failed: ") + err);
        HilogPrint(std::string("QEMU: dlsym qemu_init (and shim) failed: ") + err);
    } else {
        WriteLog(logPath, "[QEMU] Successfully loaded qemu_init symbol (or shim)");
        HilogPrint("QEMU: Successfully loaded qemu_init symbol (or shim)");
    }

    if (!g_qemu_core_main_loop) {
        std::string err = SafeDlError();
        WriteLog(logPath, std::string("[QEMU] dlsym qemu_main_loop failed: ") + err);
        HilogPrint(std::string("QEMU: dlsym qemu_main_loop failed: ") + err);
    } else {
        WriteLog(logPath, "[QEMU] Successfully loaded qemu_main_loop symbol");
        HilogPrint("QEMU: Successfully loaded qemu_main_loop symbol");
    }

    if (!g_qemu_core_cleanup) {
        WriteLog(logPath, "[QEMU] dlsym qemu_cleanup failed (optional)");
    }

    if (!g_qemu_core_shutdown) {
        WriteLog(logPath, "[QEMU] dlsym qemu_system_shutdown_request failed (optional)");
    }
}

static int QemuCoreMainOrStub(int argc, char** argv)
{
    // 提取日志路径用于记录
    std::string logPath;
    for (int i = 0; i < argc - 1; i++) {
        if (std::string(argv[i]) == "-serial" && i + 1 < argc) {
            std::string serialArg = argv[i + 1];
            if (serialArg.rfind("file:", 0) == 0) {
                logPath = serialArg.substr(5);
                break;
            }
        }
    }
    if (logPath.empty()) logPath = g_current_log_path;

    // 使用全局变量中保存的架构类型
    std::string archType = g_current_arch_type.empty() ? "aarch64" : g_current_arch_type;
    EnsureQemuCoreLoaded(logPath, archType);
    if (g_qemu_core_qemu_init && g_qemu_core_main_loop) {
        WriteLog(logPath, "[QEMU] Core library loaded, initializing QEMU...");
        HilogPrint("QEMU: Core library loaded successfully");
        
        // 打印所有启动参数便于调试
        HilogPrint("QEMU: Command line arguments (" + std::to_string(argc) + " args):");
        for (int i = 0; i < argc; i++) {
            HilogPrint("QEMU:   argv[" + std::to_string(i) + "] = " + std::string(argv[i]));
        }
        
        // 使用新的 QEMU API：先 init，再 main_loop
        HilogPrint("QEMU: Calling qemu_init now...");
        WriteLog(logPath, "[QEMU] Calling qemu_init...");
        
        // ============ 添加崩溃保护和详细诊断 ============
        // 在调用 qemu_init 前同步日志
        fflush(stdout);
        fflush(stderr);
        
        // 注意：不要在这里安装自定义 signal handler（尤其不要在 handler 里调用日志/分配内存/锁），
        // 这会在某些设备/场景下造成二次崩溃或死锁，反而让“闪退”更难定位。
        
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_INIT", 
            ">>> 即将调用 qemu_init，参数数量: %d <<<", argc);
        
        // ============ 设置 QEMU 环境变量 ============
        // 这些环境变量可能有助于 QEMU 正常初始化
        // 默认禁用旧式音频后端（避免 OHOS 上误选 OSS/SDL 等导致启动失败）。
        // 当命令行包含 -audiodev 时，说明我们显式启用了音频后端（如 aether-soundkit-hmos），此时不要强制禁音。
        bool hasAudiodev = false;
        for (int i = 0; i < argc; i++) {
            if (std::string(argv[i]) == "-audiodev") {
                hasAudiodev = true;
                break;
            }
        }
        if (!hasAudiodev) {
            setenv("QEMU_AUDIO_DRV", "none", 1);  // 禁用音频（无 audiodev 时）
        }
        setenv("DISPLAY", "", 1);  // 无显示环境
        
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_INIT", 
            ">>> 环境变量已设置 <<<");
        
        // ============ 使用用户的实际配置 ============
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_INIT", 
            ">>> 使用用户配置，%d 个参数 <<<", argc);
        
        // 打印每个参数用于调试
        for (int i = 0; i < argc; i++) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_ARG", 
                "[%d] = %s", i, argv[i]);
        }
        
        // 关键修复：拦截 QEMU 内部的 exit(1)，避免被 appspawn 杀进程
        g_tls_in_qemu = true;
        g_tls_exit_code = 0;
        int jumped = setjmp(g_tls_exit_jmp);
        if (jumped != 0) {
            int code = g_tls_exit_code;
            g_tls_in_qemu = false;

            std::string msg = "QEMU called exit(" + std::to_string(code) + ") during init/mainloop; converted to failure to avoid appspawn crash";
            HilogPrint("QEMU: [FATAL] " + msg);
            WriteLog(logPath, "[QEMU] [FATAL] " + msg);
            return (code == 0) ? -1 : code;
        }

        // 如果 QEMU core 内部 shim 支持记录 exit code，则先清空一次
        if (g_qemu_core_clear_last_exit_code) {
            g_qemu_core_clear_last_exit_code();
        }

        // 直接使用用户配置（如果 QEMU 内部调用 exit，会被上面的 setjmp 捕获）
        g_qemu_core_qemu_init(argc, argv);

        // 关键：在 OHOS 上，QEMU 有可能在 qemu_init 里直接 exit(1)；我们用 core shim 兜底捕获后，
        // qemu_init 会“正常返回”。因此这里必须额外检查一次 exit_code。
        if (g_qemu_core_get_last_exit_code) {
            int coreExit = g_qemu_core_get_last_exit_code();
            if (coreExit != 0) {
        g_tls_in_qemu = false;
                std::string msg =
                    "QEMU core requested exit(" + std::to_string(coreExit) + ") during qemu_init; converted to failure to avoid appspawn crash";
                HilogPrint("QEMU: [FATAL] " + msg);
                WriteLog(logPath, "[QEMU] [FATAL] " + msg);
                return coreExit;
            }
        }
        
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_INIT", 
            ">>> qemu_init 返回成功！<<<");
        
        g_qemu_initialized = true;
        
        HilogPrint("QEMU: qemu_init completed, entering main loop...");
        WriteLog(logPath, "[QEMU] qemu_init completed, entering qemu_main_loop...");
        int result = g_qemu_core_main_loop();
        
        // 主循环结束，进行清理
        WriteLog(logPath, "[QEMU] qemu_main_loop returned: " + std::to_string(result));
        HilogPrint("QEMU: qemu_main_loop returned: " + std::to_string(result));
        
        if (g_qemu_core_cleanup) {
            HilogPrint("QEMU: Calling qemu_cleanup...");
            WriteLog(logPath, "[QEMU] Calling qemu_cleanup...");
            g_qemu_core_cleanup(result);
            WriteLog(logPath, "[QEMU] qemu_cleanup completed");
        }
        g_qemu_initialized = false;
        g_tls_in_qemu = false;
        
        return result;
    }

    // Fallback: 仅日志模拟，方便界面验证
    WriteLog(logPath, "[QEMU] Core library missing, running stub loop");
    HilogPrint("QEMU: ERROR - Core library not loaded");
    // 重置关闭请求标志
    g_qemu_shutdown_requested = false;
    
    // 解析参数获取日志路径
    // 上面已获取 logPath
    
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
    
    // 无核心库，立即失败，避免误导UI
    return -1;
}

// QEMU关闭请求实现
extern "C" void qemu_system_shutdown_request(int reason) {
    if (g_qemu_core_shutdown) {
        g_qemu_core_shutdown(reason);
        return;
    }
    WriteLog(g_current_log_path, "[QEMU] 收到关闭请求(Stub)，原因代码: " + std::to_string(reason));
    g_qemu_shutdown_requested = true;
}

// NAPI函数实现
static napi_value GetVersion(napi_env env, napi_callback_info info) {
    (void)info; // unused
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
    // 兼容旧接口：不再通过 syscall 启用/探测 JIT
    napi_get_boolean(env, false, &out);
    return out;
}

static napi_value KvmSupported(napi_env env, napi_callback_info info) {
    (void)info; // unused
    napi_value out;
    napi_get_boolean(env, kvmSupported(), &out);
    return out;
}

static napi_value StartVm(napi_env env, napi_callback_info info) {
    // ============ 诊断：在任何操作之前打印日志 ============
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_START", ">>> StartVm 函数入口 <<<");
    
    HilogPrint("QEMU: StartVm function called!");
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_START", ">>> 获取参数成功, argc=%{public}zu <<<", argc);

    napi_value retBool;
    napi_get_boolean(env, false, &retBool);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "No config provided");
        return retBool;
    }
    
    bool ok = false;
    VMConfig config = ParseVMConfig(env, argv[0], ok);
    if (!ok) {
        napi_throw_error(env, nullptr, "Invalid config");
        return retBool;
    }
    
    std::lock_guard<std::mutex> lock(g_vmMutex);
    
    // 检查VM是否已在运行
    if (g_vmRunning.find(config.name) != g_vmRunning.end() && g_vmRunning[config.name]->load()) {
        HilogPrint("QEMU: VM '" + config.name + "' is already running");
        napi_throw_error(env, nullptr, "VM is already running");
        return retBool;
    }
    
    HilogPrint("QEMU: Starting VM '" + config.name + "' with accel=" + config.accel + " display=" + config.display);
    
    // 创建VM目录结构
    if (!CreateVMDirectory(config.name)) {
        WriteLog(config.logPath, "Failed to create VM directory for: " + config.name);
        napi_throw_error(env, nullptr, "Failed to create VM directory");
        return retBool;
    }
    WriteLog(config.logPath, "VM directory created for: " + config.name);
    
    // 创建VM配置文件
    if (!CreateVMConfigFile(config)) {
        WriteLog(config.logPath, "Failed to create VM config file for: " + config.name);
        napi_throw_error(env, nullptr, "Failed to create VM config file");
        return retBool;
    }
    WriteLog(config.logPath, "VM config file created for: " + config.name);

    // 创建 VM 高级硬件偏好文件（vmPerfence.json），忽略失败
    if (!CreateVmPerfenceFile(config)) {
        WriteLog(config.logPath, "Warning: Failed to create vmPerfence.json for: " + config.name);
    } else {
        WriteLog(config.logPath, "VM perfence file created for: " + config.name);
    }
    
    // 更新VM状态为准备中
    UpdateVMStatus(config.name, "preparing");
    
    // 创建虚拟磁盘
    if (!FileExists(config.diskPath)) {
        WriteLog(config.logPath, "Creating virtual disk: " + config.diskPath);
        if (!CreateVirtualDisk(config.diskPath, config.diskSizeGB)) {
            WriteLog(config.logPath, "Failed to create virtual disk");
            UpdateVMStatus(config.name, "failed");
            napi_throw_error(env, nullptr, "Failed to create virtual disk");
            return retBool;
        }
        WriteLog(config.logPath, "Virtual disk created successfully");
    }

    // 启动前关键预检：避免 QEMU 在解析 -drive 时因 qcow2 镜像损坏直接 exit(1) → appspawn SIGABRT
    // - raw disk：无需 qcow2 预检
    // - qcow2 disk：必须有有效 refcount table，否则视为损坏（常见于旧版内置 qcow2 伪实现生成的镜像）
    if (FileExists(config.diskPath) && IsQcow2FileQuick(config.diskPath)) {
        if (!PreflightQcow2RefcountTable(config.diskPath)) {
            UpdateVMStatus(config.name, "failed");
            napi_throw_error(env, nullptr,
                             "Disk image is corrupt (qcow2 refcount table invalid). 请到「磁盘空间管理 → 新建/覆盖」重建磁盘后再启动。");
            return retBool;
        }
    }
    
    // ========== 打印用户选择的设备配置 ==========
    WriteLog(config.logPath, "========== Device Configuration ==========");
    WriteLog(config.logPath, "[CONFIG] Machine: " + (config.machine.empty() ? "virt (default)" : config.machine));
    WriteLog(config.logPath, "[CONFIG] Display Device: " + (config.displayDevice.empty() ? "none (default)" : config.displayDevice));
    WriteLog(config.logPath, "[CONFIG] Network Device: " + (config.networkDevice.empty() ? "virtio-net (default)" : config.networkDevice));
    WriteLog(config.logPath, "[CONFIG] Audio Device: " + (config.audioDevice.empty() ? "none (default)" : config.audioDevice));
    WriteLog(config.logPath, "[CONFIG] Memory: " + std::to_string(config.memoryMB) + " MB");
    WriteLog(config.logPath, "[CONFIG] CPU Count: " + std::to_string(config.cpuCount));
    WriteLog(config.logPath, "[CONFIG] QEMU Data Dir: " + (config.qemuDataDir.empty() ? "(not set)" : config.qemuDataDir));
    WriteLog(config.logPath, "==========================================");
    
    // 构建QEMU参数
    std::vector<std::string> args = BuildQemuArgs(config);
    std::string cmdStr = "Starting VM with command: ";
    for (const auto& arg : args) {
        cmdStr += arg + " ";
    }
    WriteLog(config.logPath, cmdStr);
    HilogPrint("QEMU: " + cmdStr);

    // 检查关键文件是否存在
    WriteLog(config.logPath, "Checking VM files...");
    WriteLog(config.logPath, "Disk path: " + config.diskPath + " (exists: " + (FileExists(config.diskPath) ? "yes" : "no") + ")");
    HilogPrint("QEMU: Disk exists: " + std::string(FileExists(config.diskPath) ? "yes" : "no"));
    
    // 初始化日志缓冲区
    g_vmLogBuffers[config.name].clear();
    // 确保互斥锁存在（map会自动创建）
    g_vmLogMutexes[config.name];
    
    // 设置全局变量供QEMU函数使用
    g_current_vm_name = config.name;
    g_current_log_path = config.logPath;
    g_current_arch_type = config.archType.empty() ? "aarch64" : config.archType;
    
    // 启动前确保核心库可用（根据架构加载对应的 .so）
    std::string archType = config.archType.empty() ? "aarch64" : config.archType;
    WriteLog(config.logPath, "[QEMU] Loading QEMU core for architecture: " + archType);
    EnsureQemuCoreLoaded(config.logPath, archType);
    if (!g_qemu_core_qemu_init || !g_qemu_core_main_loop) {
        WriteLog(config.logPath, "[QEMU] Core library not loaded. Aborting start.");
        std::string libName = GetQemuLibName(archType);
        WriteLog(config.logPath, "[QEMU] Please ensure " + libName + " is properly installed in the app bundle.");
        UpdateVMStatus(config.name, "failed");
        napi_throw_error(env, nullptr, (libName + " not found or failed to load. Please check app installation.").c_str());
        return retBool;
    }

    // 启动VM线程
    if (g_vmRunning.find(config.name) == g_vmRunning.end()) {
        g_vmRunning[config.name] = new std::atomic<bool>(false);
    }
    g_vmRunning[config.name]->store(true);
    
    // 更新VM状态为运行中
    UpdateVMStatus(config.name, "running");
    
    // 保存 vmName 用于在回调中使用
    std::string vmName = config.name;
    
    g_vmThreads[config.name] = std::thread([config, args, vmName]() {
        std::vector<char*> cargs;
        for (const auto &s : args) {
            cargs.push_back(const_cast<char*>(s.c_str()));
        }

        // 在进入 QEMU 主循环前启动 stdout/stderr/stdin 捕获（并把 stdout/stderr 落盘到 VM 目录）
        g_logCapture = std::make_unique<CaptureQemuOutput>(config.vmDir);

        WriteLog(config.logPath, "VM thread started");
        // 这里也通过 Hilog 打一条，方便在设备上直接看到 VM 主线程已启动
        HilogPrint("QEMU: VM thread started for VM '" + vmName + "'");
        int exitCode = QemuCoreMainOrStub(static_cast<int>(cargs.size()), cargs.data());
        WriteLog(config.logPath, "VM exited with code: " + std::to_string(exitCode));

        // 退出后释放捕获器，恢复文件描述符并释放 JS 回调
        g_logCapture.reset();
        
        // 更新VM状态为已停止
        UpdateVMStatus(config.name, "stopped");
        g_vmRunning[config.name]->store(false);
        
        // 通知 ArkTS 层 VM 已退出
        VmStartError error = (exitCode == 0) ? VmStartError::SUCCESS : VmStartError::LOOP_CRASHED;
        std::string errorMsg = (exitCode == 0) ? "" : "VM exited with code " + std::to_string(exitCode);
        NotifyVmStartResult(vmName, error, exitCode, errorMsg);
    });

    napi_get_boolean(env, true, &retBool);
    return retBool;
}

// Forward declaration: used by StopVm() background watchdog thread.
static std::string QueryVmStatusViaQmp(const std::string& vmName);

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
    std::string vmName;
    if (!NapiGetStringUtf8(env, argv[0], vmName)) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    std::lock_guard<std::mutex> lock(g_vmMutex);
    
    if (g_vmRunning.find(vmName) != g_vmRunning.end() && g_vmRunning[vmName]->load()) {
        // 更新VM状态为停止中
        UpdateVMStatus(vmName, "stopping");

        std::string logPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmName + "/qemu.log";
        WriteLog(logPath, "StopVm requested by user (non-blocking)");

        // 先发“优雅关机”请求（不会阻塞）
        qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST);

        // 关键修复：不要在 NAPI 调用里 join VM 线程（会卡死 UI）
        // 把 join 放到后台线程里做；超时则通过 QMP 发送 quit 强制退出。
        std::thread vmThread;
        auto itTh = g_vmThreads.find(vmName);
        if (itTh != g_vmThreads.end()) {
            vmThread = std::move(itTh->second);
            g_vmThreads.erase(itTh);
        }

        // QMP: send {"execute":"quit"} to force exit
        auto sendQmpQuit = [](const std::string& name) -> bool {
            std::string socketPath = "/data/storage/el2/base/haps/entry/files/vms/" + name + "/qmp.sock";
            int sock = socket(AF_UNIX, SOCK_STREAM, 0);
            if (sock < 0) return false;

            struct timeval tv;
            tv.tv_sec = 2;
            tv.tv_usec = 0;
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

            struct sockaddr_un addr;
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);

            if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
                close(sock);
                return false;
            }

            char buffer[4096];
            ssize_t n = recv(sock, buffer, sizeof(buffer) - 1, 0); // greeting
            if (n <= 0) {
                close(sock);
                return false;
            }
            buffer[n] = '\0';

            const char* capCmd = "{\"execute\": \"qmp_capabilities\"}\n";
            if (send(sock, capCmd, strlen(capCmd), 0) <= 0) {
                close(sock);
                return false;
            }
            n = recv(sock, buffer, sizeof(buffer) - 1, 0); // capabilities response (ignore content)
            (void)n;

            const char* quitCmd = "{\"execute\": \"quit\"}\n";
            (void)send(sock, quitCmd, strlen(quitCmd), 0);
            close(sock);
            return true;
        };

        // 后台等待退出/强制退出
        std::thread([vmName, logPath, vmThread = std::move(vmThread), sendQmpQuit]() mutable {
            // 等待一小段时间让 guest 自己关机
            const auto start = std::chrono::steady_clock::now();
            bool forced = false;

            while (true) {
                // 这里不加全局锁：仅通过 QMP 看状态（失败则认为仍需等待）
                std::string st = QueryVmStatusViaQmp(vmName);
                if (st == "stopped" || st == "shutdown") {
                    break;
                }

                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::steady_clock::now() - start).count();

                if (!forced && elapsed >= 5) {
                    // 超时：强制退出
                    forced = true;
                    bool ok = sendQmpQuit(vmName);
                    WriteLog(logPath, std::string("[STOP] Timeout reached, sent QMP quit: ") + (ok ? "ok" : "failed"));
                    HilogPrint(std::string("QEMU: [STOP] Timeout, QMP quit sent: ") + (ok ? "ok" : "failed"));
                }

                if (elapsed >= 12) {
                    // 再给一点宽限；避免无休止等待
                    WriteLog(logPath, "[STOP] Force stop watchdog reached 12s, giving up waiting (thread may still exit later)");
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
            }

            if (vmThread.joinable()) {
                vmThread.join();
            }

            {
                std::lock_guard<std::mutex> lk(g_vmMutex);
                auto it = g_vmRunning.find(vmName);
                if (it != g_vmRunning.end() && it->second) {
                    it->second->store(false);
                }
            }
            UpdateVMStatus(vmName, "stopped");
            WriteLog(logPath, "[STOP] VM stopped (non-blocking stop handler done)");
        }).detach();
    }
    
    napi_get_boolean(env, true, &result);
    return result;
}

// ============================================================
// 磁盘工具：qemu-img 创建/扩容（以及内置 QCOW2 创建兜底）
// 仅允许在 VM 停止时使用（UI 层也应拦截，但 Native 侧再做一次保护）
// ============================================================

static bool IsVmRunningLocked(const std::string& vmName) {
    auto it = g_vmRunning.find(vmName);
    if (it == g_vmRunning.end() || !it->second) return false;
    return it->second->load();
}

// qemuImgCreateDisk(vmName: string, sizeGB: number, overwrite?: boolean): boolean
static napi_value QemuImgCreateDisk(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value out;
    napi_get_boolean(env, false, &out);

    if (argc < 2) return out;

    std::string vmName;
    if (!NapiGetStringUtf8(env, argv[0], vmName) || vmName.empty()) return out;

    int32_t sizeGB = 0;
    napi_get_value_int32(env, argv[1], &sizeGB);
    if (sizeGB <= 0) return out;

    bool overwrite = false;
    if (argc >= 3) {
        napi_get_value_bool(env, argv[2], &overwrite);
    }

    std::lock_guard<std::mutex> lock(g_vmMutex);
    if (IsVmRunningLocked(vmName)) {
        HilogPrint("QEMU: [DISK] Refuse create disk while VM running: " + vmName);
        return out;
    }

    const std::string vmDir = "/data/storage/el2/base/haps/entry/files/vms/" + vmName;
    const std::string diskPath = vmDir + "/disk.qcow2";

    if (!overwrite && FileExists(diskPath)) {
        HilogPrint("QEMU: [DISK] disk already exists, overwrite=false: " + diskPath);
        napi_get_boolean(env, true, &out);
        return out;
    }

    // 确保目录存在
    if (!CreateDirectories(vmDir)) {
        HilogPrint("QEMU: [DISK] failed to create vmDir: " + vmDir);
        return out;
    }

    // 走内置 QCOW2 创建（不依赖外部工具）
    if (!CreateVirtualDisk(diskPath, sizeGB)) {
        HilogPrint("QEMU: [DISK] CreateVirtualDisk failed: " + diskPath);
        return out;
    }

    HilogPrint("QEMU: [DISK] created disk: " + diskPath + " (" + std::to_string(sizeGB) + "GB)");
    napi_get_boolean(env, true, &out);
    return out;
}

// qemuImgResizeDisk(vmName: string, newSizeGB: number): boolean
static napi_value QemuImgResizeDisk(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value out;
    napi_get_boolean(env, false, &out);

    if (argc < 2) return out;

    std::string vmName;
    if (!NapiGetStringUtf8(env, argv[0], vmName) || vmName.empty()) return out;

    int32_t newSizeGB = 0;
    napi_get_value_int32(env, argv[1], &newSizeGB);
    if (newSizeGB <= 0) return out;

    std::lock_guard<std::mutex> lock(g_vmMutex);
    if (IsVmRunningLocked(vmName)) {
        HilogPrint("QEMU: [DISK] Refuse resize disk while VM running: " + vmName);
        return out;
    }

    const std::string vmDir = "/data/storage/el2/base/haps/entry/files/vms/" + vmName;
    const std::string diskPath = vmDir + "/disk.qcow2";

    if (!FileExists(diskPath)) {
        HilogPrint("QEMU: [DISK] disk not found: " + diskPath);
        return out;
    }

    // 优先走 qemu-img（符合你的诉求：用 qemu-img 扩容）
    // 注意：如果运行环境缺少 qemu-img，这里会失败，UI 会提示用户。
    std::string cmd = "qemu-img resize \"" + diskPath + "\" " + std::to_string(newSizeGB) + "G";
    HilogPrint("QEMU: [DISK] exec: " + cmd);
    int rc = system(cmd.c_str());
    if (rc != 0) {
        HilogPrint("QEMU: [DISK] qemu-img resize failed rc=" + std::to_string(rc));
        // 兜底：raw 磁盘可以直接用 ftruncate 扩容/缩小；qcow2 必须依赖 qemu-img
        if (!IsQcow2FileQuick(diskPath)) {
            const uint64_t newSizeBytes = static_cast<uint64_t>(newSizeGB) * 1024ULL * 1024ULL * 1024ULL;
            int fd = open(diskPath.c_str(), O_RDWR);
            if (fd < 0) {
                HilogPrint("QEMU: [DISK] raw fallback resize open failed errno=" + std::to_string(errno));
                return out;
            }
            int trc = ftruncate(fd, static_cast<off_t>(newSizeBytes));
            close(fd);
            if (trc != 0) {
                HilogPrint("QEMU: [DISK] raw fallback ftruncate failed errno=" + std::to_string(errno));
                return out;
            }
            HilogPrint("QEMU: [DISK] raw fallback resized disk to " + std::to_string(newSizeGB) + "GB: " + diskPath);
            napi_get_boolean(env, true, &out);
            return out;
        }

        return out;
    }

    HilogPrint("QEMU: [DISK] resized disk to " + std::to_string(newSizeGB) + "GB: " + diskPath);
    napi_get_boolean(env, true, &out);
    return out;
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
    std::string vmName;
    if (!NapiGetStringUtf8(env, argv[0], vmName)) {
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

// 通过 QMP Unix socket 查询 VM 真实状态
static std::string QueryVmStatusViaQmp(const std::string& vmName) {
    std::string socketPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmName + "/qmp.sock";
    
    // 创建 Unix socket
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        HilogPrint("QMP: Failed to create socket");
        return "unknown";
    }
    
    // 设置非阻塞超时
    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    
    // 连接到 QMP socket
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);
    
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sock);
        HilogPrint("QMP: Failed to connect to " + socketPath);
        return "stopped";  // 无法连接说明 VM 未运行
    }
    
    // 读取 QMP greeting
    char buffer[4096];
    ssize_t n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(sock);
        return "unknown";
    }
    buffer[n] = '\0';
    
    // 发送 qmp_capabilities 命令进入命令模式
    const char* capCmd = "{\"execute\": \"qmp_capabilities\"}\n";
    if (send(sock, capCmd, strlen(capCmd), 0) <= 0) {
        close(sock);
        return "unknown";
    }
    
    // 读取响应
    n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(sock);
        return "unknown";
    }
    buffer[n] = '\0';
    
    // 发送 query-status 命令
    const char* statusCmd = "{\"execute\": \"query-status\"}\n";
    if (send(sock, statusCmd, strlen(statusCmd), 0) <= 0) {
        close(sock);
        return "unknown";
    }
    
    // 读取状态响应
    n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    close(sock);
    
    if (n <= 0) {
        return "unknown";
    }
    buffer[n] = '\0';
    
    std::string response(buffer);
    HilogPrint("QMP: Status response: " + response);
    
    // 简单解析 JSON 响应
    // 响应格式: {"return": {"running": true, "status": "running", ...}}
    if (response.find("\"running\": true") != std::string::npos || 
        response.find("\"running\":true") != std::string::npos) {
        return "running";
    } else if (response.find("\"status\": \"paused\"") != std::string::npos ||
               response.find("\"status\":\"paused\"") != std::string::npos) {
        return "paused";
    } else if (response.find("\"status\": \"shutdown\"") != std::string::npos ||
               response.find("\"status\":\"shutdown\"") != std::string::npos) {
        return "shutdown";
    } else if (response.find("\"status\": \"prelaunch\"") != std::string::npos) {
        return "starting";
    }
    
    return "stopped";
}

static napi_value GetVmStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing VM name parameter");
        return nullptr;
    }
    
    // 获取VM名称
    std::string vmName;
    if (!NapiGetStringUtf8(env, argv[0], vmName)) {
        napi_throw_error(env, nullptr, "Failed to get VM name");
        return nullptr;
    }
    
    std::string status = "stopped";
    
    // 加锁访问 g_vmRunning，避免数据竞争
    {
        std::lock_guard<std::mutex> lock(g_vmMutex);
        // 首先检查本地运行状态标志
        auto it = g_vmRunning.find(vmName);
        if (it != g_vmRunning.end() && it->second && it->second->load()) {
            // VM 线程在运行，尝试通过 QMP 获取真实状态
            status = QueryVmStatusViaQmp(vmName);
            
            // 如果 QMP 查询失败但线程还在运行，返回 running
            if (status == "stopped" || status == "unknown") {
                status = "running";
            }
        }
    }

    napi_value result;
    napi_create_string_utf8(env, status.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// ============================================================
// QMP screendump - 通过 QMP 获取屏幕截图
// 由于 VNC 后端崩溃，使用 -display none + virtio-gpu + screendump 作为替代方案
// ============================================================

static bool TakeScreenshotViaQmp(const std::string& vmName, const std::string& outputPath) {
    std::string socketPath = "/data/storage/el2/base/haps/entry/files/vms/" + vmName + "/qmp.sock";
    
    HilogPrint("QMP: Taking screenshot for VM: " + vmName);
    HilogPrint("QMP: Output path: " + outputPath);
    
    // 创建 Unix socket
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        HilogPrint("QMP screendump: Failed to create socket");
        return false;
    }
    
    // 设置超时
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    
    // 连接到 QMP socket
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);
    
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sock);
        HilogPrint("QMP screendump: Failed to connect to socket");
        return false;
    }
    
    char buffer[4096];
    ssize_t n;
    
    // 读取 QMP greeting
    n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(sock);
        HilogPrint("QMP screendump: Failed to read greeting");
        return false;
    }
    buffer[n] = '\0';
    HilogPrint(std::string("QMP greeting: ") + buffer);
    
    // 发送 qmp_capabilities
    const char* capCmd = "{\"execute\": \"qmp_capabilities\"}\n";
    if (send(sock, capCmd, strlen(capCmd), 0) <= 0) {
        close(sock);
        HilogPrint("QMP screendump: Failed to send qmp_capabilities");
        return false;
    }
    
    n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        close(sock);
        HilogPrint("QMP screendump: Failed to read capabilities response");
        return false;
    }
    buffer[n] = '\0';
    HilogPrint(std::string("QMP capabilities response: ") + buffer);
    
    // 发送 screendump 命令
    // 格式: {"execute": "screendump", "arguments": {"filename": "/path/to/file.ppm"}}
    std::string screendumpCmd = "{\"execute\": \"screendump\", \"arguments\": {\"filename\": \"" + outputPath + "\"}}\n";
    HilogPrint("QMP screendump command: " + screendumpCmd);
    
    if (send(sock, screendumpCmd.c_str(), screendumpCmd.length(), 0) <= 0) {
        close(sock);
        HilogPrint("QMP screendump: Failed to send screendump command");
        return false;
    }
    
    // 等待响应
    n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    close(sock);
    
    if (n <= 0) {
        HilogPrint("QMP screendump: No response");
        return false;
    }
    buffer[n] = '\0';
    HilogPrint(std::string("QMP screendump response: ") + buffer);
    
    // 检查响应是否成功
    std::string response(buffer);
    if (response.find("\"return\"") != std::string::npos && 
        response.find("\"error\"") == std::string::npos) {
        HilogPrint("QMP screendump: Success");
        return true;
    }
    
    HilogPrint("QMP screendump: Failed - " + response);
    return false;
}

static napi_value TakeScreenshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Missing parameters: vmName, outputPath");
        return nullptr;
    }
    
    std::string vmName, outputPath;
    if (!NapiGetStringUtf8(env, argv[0], vmName) || !NapiGetStringUtf8(env, argv[1], outputPath)) {
        napi_throw_error(env, nullptr, "Failed to get string parameters");
        return nullptr;
    }
    
    bool success = TakeScreenshotViaQmp(vmName, outputPath);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

// 创建RDP客户端
static napi_value CreateRdpClient(napi_env env, napi_callback_info info) {
    (void)info;  // 添加
    napi_value result;
    napi_create_object(env, &result);
    
    // 生成唯一的客户端ID
    static int client_counter = 0;
    std::string client_id = "rdp_client_" + std::to_string(++client_counter);
    
    // 创建RDP客户端
    rdp_client_handle_t client = rdp_client_create();
    
    // 存储客户端句柄
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        g_rdp_clients[client_id] = client;
    }
    
    // 设置客户端ID
    napi_value id_value;
    napi_create_string_utf8(env, client_id.c_str(), NAPI_AUTO_LENGTH, &id_value);
    napi_set_named_property(env, result, "id", id_value);
    
    return result;
}

// 连接RDP
static napi_value ConnectRdp(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Missing parameters: clientId and config");
        return nullptr;
    }
    
    // 获取客户端ID
    std::string client_id;
    if (!NapiGetStringUtf8(env, argv[0], client_id)) {
        napi_throw_error(env, nullptr, "Failed to get client ID");
        return nullptr;
    }
    
    // 获取配置对象
    napi_value config = argv[1];
    
    // 解析配置参数
    rdp_connection_config_t rdp_config = {};
    
    // 主机地址
    std::string hostStr;
    napi_value host_value;
    if (napi_get_named_property(env, config, "host", &host_value) == napi_ok) {
        NapiGetStringUtf8(env, host_value, hostStr);
        if (!hostStr.empty()) rdp_config.host = hostStr.c_str();
    }
    
    // 端口
    napi_value port_value;
    if (napi_get_named_property(env, config, "port", &port_value) == napi_ok) {
        int32_t port;
        if (napi_get_value_int32(env, port_value, &port) == napi_ok) {
            rdp_config.port = port;
        }
    }
    
    // 用户名
    std::string usernameStr;
    napi_value username_value;
    if (napi_get_named_property(env, config, "username", &username_value) == napi_ok) {
        NapiGetStringUtf8(env, username_value, usernameStr);
        if (!usernameStr.empty()) rdp_config.username = usernameStr.c_str();
    }
    
    // 密码
    std::string passwordStr;
    napi_value password_value;
    if (napi_get_named_property(env, config, "password", &password_value) == napi_ok) {
        NapiGetStringUtf8(env, password_value, passwordStr);
        if (!passwordStr.empty()) rdp_config.password = passwordStr.c_str();
    }
    
    // 显示设置
    napi_value width_value;
    if (napi_get_named_property(env, config, "width", &width_value) == napi_ok) {
        int32_t width;
        if (napi_get_value_int32(env, width_value, &width) == napi_ok) {
            rdp_config.width = width;
        }
    }
    
    napi_value height_value;
    if (napi_get_named_property(env, config, "height", &height_value) == napi_ok) {
        int32_t height;
        if (napi_get_value_int32(env, height_value, &height) == napi_ok) {
            rdp_config.height = height;
        }
    }
    
    // 查找客户端
    rdp_client_handle_t client = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        if (g_rdp_clients.find(client_id) != g_rdp_clients.end()) {
            client = g_rdp_clients[client_id];
        }
    }
    
    if (!client) {
        napi_throw_error(env, nullptr, "RDP client not found");
        return nullptr;
    }
    
    // 尝试连接
    int result = qemu_rdp_client_connect(client, &rdp_config);
    
    napi_value result_value;
    napi_create_int32(env, result, &result_value);
    
    return result_value;
}

// 断开RDP连接
static napi_value DisconnectRdp(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing client ID parameter");
        return nullptr;
    }
    
    // 获取客户端ID
    std::string client_id;
    if (!NapiGetStringUtf8(env, argv[0], client_id)) {
        napi_throw_error(env, nullptr, "Failed to get client ID");
        return nullptr;
    }
    
    // 查找并断开客户端
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        if (g_rdp_clients.find(client_id) != g_rdp_clients.end()) {
            qemu_rdp_client_disconnect(g_rdp_clients[client_id]);
        }
    }
    
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

// 获取RDP连接状态
static napi_value GetRdpStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing client ID parameter");
        return nullptr;
    }
    
    // 获取客户端ID
    std::string client_id;
    if (!NapiGetStringUtf8(env, argv[0], client_id)) {
        napi_throw_error(env, nullptr, "Failed to get client ID");
        return nullptr;
    }
    
    // 查找客户端
    rdp_client_handle_t client = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        if (g_rdp_clients.find(client_id) != g_rdp_clients.end()) {
            client = g_rdp_clients[client_id];
        }
    }
    
    if (!client) {
        napi_throw_error(env, nullptr, "RDP client not found");
        return nullptr;
    }
    
    // 获取状态
    rdp_connection_state_t state = rdp_client_get_state(client);
    
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(state), &result);
    
    return result;
}

// 发送 RDP 键盘事件（供 ArkTS 虚拟键盘使用）
// key: 目前沿用 X11 keysym（与 VNC 一致），后续如需可在 native 内做 scanCode 映射
static napi_value RdpSendKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_error(env, nullptr, "Missing parameters: clientId, key, down");
        return nullptr;
    }

    std::string client_id;
    if (!NapiGetStringUtf8(env, argv[0], client_id)) {
        napi_throw_error(env, nullptr, "Failed to get client ID");
        return nullptr;
    }

    int32_t key = 0;
    if (napi_get_value_int32(env, argv[1], &key) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get key");
        return nullptr;
    }

    bool down = false;
    if (napi_get_value_bool(env, argv[2], &down) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get down");
        return nullptr;
    }

    rdp_client_handle_t client = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        auto it = g_rdp_clients.find(client_id);
        if (it != g_rdp_clients.end()) {
            client = it->second;
        }
    }

    if (!client) {
        napi_throw_error(env, nullptr, "RDP client not found");
        return nullptr;
    }

    int ret = rdp_client_send_keyboard_event(client, static_cast<int>(key), down ? 1 : 0);

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

// 检测核心库存在性（真实检测，不加载到全局）
// ============ 诊断工具：追踪 dlopen 崩溃位置 ============
// 这个函数会详细记录 dlopen 过程中的每一步
static napi_value CheckCoreLib(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_create_object(env, &result);

    auto set_bool = [&](const char* name, bool v){ napi_value b; napi_get_boolean(env, v, &b); napi_set_named_property(env, result, name, b); };
    auto set_str = [&](const char* name, const std::string& s){ napi_value v; napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, result, name, v); };

    // ============ 添加详细的崩溃诊断日志 ============
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "========== CheckCoreLib 开始 ==========");
    
    // 已加载到全局？
    bool alreadyLoaded = g_qemu_core_qemu_init != nullptr && g_qemu_core_main_loop != nullptr;
    set_bool("loaded", alreadyLoaded);
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤0: 检查是否已加载 = %s", alreadyLoaded ? "是" : "否");

    // 获取库路径
    Dl_info dlinfo{};
    std::string selfDir;
    if (dladdr((void*)&CheckCoreLib, &dlinfo) != 0 && dlinfo.dli_fname) {
        std::string soPath = dlinfo.dli_fname;
        auto pos = soPath.find_last_of('/');
        if (pos != std::string::npos) {
            selfDir = soPath.substr(0, pos);
        }
    }
    set_str("selfDir", selfDir);
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤1: 库目录 = %s", selfDir.c_str());

    // ============ 关键测试：使用 RTLD_NOLOAD 检查是否已在内存中 ============
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤2: 尝试 RTLD_NOLOAD（不触发constructor）...");
    void* h_noload = dlopen("libqemu_full.so", RTLD_LAZY | RTLD_NOLOAD);
    if (h_noload) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤2: 库已在内存中！");
        set_bool("alreadyInMemory", true);
        dlclose(h_noload);
    } else {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤2: 库未在内存中，需要加载");
        set_bool("alreadyInMemory", false);
    }

    // ============ 暂时跳过实际的 dlopen 以避免崩溃 ============
    // 如果需要测试 dlopen，取消下面的注释
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤3: 跳过 dlopen 以避免崩溃");
    set_bool("foundLd", false);
    set_bool("foundSelfDir", false);
    set_bool("foundFiles", false);
    set_bool("symFound", false);
    set_str("errLd", "dlopen 被跳过以避免崩溃（748个constructor）");
    
    /*
    // ============ 危险区域：实际的 dlopen 调用 ============
    // 取消注释以测试
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤3: 准备调用 dlopen（危险！）...");
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", ">>> 如果下一条日志没出现，说明 dlopen/constructor 导致崩溃 <<<");
    
    void* h1 = dlopen("libqemu_full.so", RTLD_LAZY);
    
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤4: dlopen 返回 = %p", h1);
    set_bool("foundLd", h1 != nullptr);
    
    if (!h1) {
        const char* err = dlerror();
        set_str("errLd", err ? std::string(err) : std::string(""));
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤4: dlopen 失败: %s", err ? err : "unknown");
    } else {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤5: dlopen 成功，尝试 dlsym...");
        void* sym_init = dlsym(h1, "qemu_init");
        void* sym_loop = dlsym(h1, "qemu_main_loop");
        set_bool("symFound", sym_init != nullptr && sym_loop != nullptr);
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤5: qemu_init=%p, qemu_main_loop=%p", sym_init, sym_loop);
        
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤6: 准备 dlclose...");
        dlclose(h1);
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "步骤6: dlclose 完成");
    }
    */

    // 从 files 目录
    std::string filesPath = "/data/storage/el2/base/haps/entry/files/libqemu_full.so";
    bool existsFiles = FileExists(filesPath);
    set_bool("existsFilesPath", existsFiles);
    set_str("filesPath", filesPath);

    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "QEMU_DIAG", "========== CheckCoreLib 结束 ==========");
    return result;
}

// 销毁RDP客户端
static napi_value DestroyRdpClient(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Missing client ID parameter");
        return nullptr;
    }
    
    // 获取客户端ID
    std::string client_id;
    if (!NapiGetStringUtf8(env, argv[0], client_id)) {
        napi_throw_error(env, nullptr, "Failed to get client ID");
        return nullptr;
    }
    
    // 查找并销毁客户端
    {
        std::lock_guard<std::mutex> lock(g_rdp_mutex);
        if (g_rdp_clients.find(client_id) != g_rdp_clients.end()) {
            rdp_client_destroy(g_rdp_clients[client_id]);
            g_rdp_clients.erase(client_id);
        }
    }
    
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

// ================== RDP 超时处理和强制关闭 ==================

// 检查 RDP 连接是否超时（返回超时秒数，0表示未超时）
static napi_value RdpCheckTimeout(napi_env env, napi_callback_info info) {
    (void)info;
    int timeout_sec = rdp_check_timeout();
    napi_value result;
    napi_create_int32(env, timeout_sec, &result);
    return result;
}

// 设置 RDP 超时时间（秒）
static napi_value RdpSetTimeout(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc >= 1) {
        int32_t seconds = 30;
        napi_get_value_int32(env, argv[0], &seconds);
        rdp_set_timeout(seconds);
    }
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 请求取消 RDP 连接
static napi_value RdpRequestCancel(napi_env env, napi_callback_info info) {
    (void)info;
    rdp_request_cancel();
    HilogPrint("RDP cancel requested");
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 强制清理 RDP 连接（即使线程卡住也能清理）
static napi_value RdpForceCleanup(napi_env env, napi_callback_info info) {
    (void)info;
    HilogPrint("RDP force cleanup initiated");
    rdp_force_cleanup();
    HilogPrint("RDP force cleanup completed");
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 获取 RDP 状态字符串 (disconnected/connecting/connected/timeout/cancelling)
static napi_value RdpGetStatusString(napi_env env, napi_callback_info info) {
    (void)info;
    const char* status = rdp_get_status_string();
    
    napi_value result;
    napi_create_string_utf8(env, status, strlen(status), &result);
    return result;
}

// ----------------------------- Native VNC (LibVNCClient) -----------------------------
#ifdef LIBVNC_HAVE_CLIENT
#include "third_party/libvncclient/include/rfb/rfbclient.h"
#endif

static std::mutex g_vnc_mutex;
static int g_vnc_next_id = 1;

struct VncSession {
    int id = 0;
#ifdef LIBVNC_HAVE_CLIENT
    rfbClient* client = nullptr;
#endif
    // 保护 client/worker/render_worker 等生命周期对象（仅短时间持锁）
    std::mutex lifecycle_mtx;
#ifdef LIBVNC_HAVE_CLIENT
    // 连接/断开必须避免阻塞 UI 线程：把耗时的 rfbClientConnect/rfbClientInitialise 放到后台线程
    std::atomic<bool> connecting{false};
    std::atomic<uint32_t> connect_seq{0};
#endif
#if defined(__OHOS__)
    // XComponent 直绘：NativeWindow 必须在同一线程内创建/使用/销毁，避免 FlushBuffer 崩溃
    std::thread render_worker;
    std::atomic<bool> render_running{false};
    std::condition_variable render_cv;
    std::mutex render_cv_mtx;

    // 由 ArkTS/NAPI 更新：仅写“期望的 surface”，由 render 线程创建/销毁 window
    std::mutex surface_mtx;
    uint64_t pending_surface_id = 0;
    int pending_surface_w = 0;
    int pending_surface_h = 0;
    std::atomic<bool> surface_dirty{false};

    // 由 VNC 回调更新：最新 BGRA 帧（render 线程消费并 flush）
    std::mutex frame_mtx;
    int fb_w = 0;
    int fb_h = 0;
    std::vector<uint8_t> fb_bgra;
    std::atomic<bool> frame_dirty{false};
#endif
    std::thread worker;
    std::atomic<bool> running;  // 在构造函数中初始化
    int width = 0;
    int height = 0;
    std::vector<uint8_t> frame; // RGBA8888 (ArkTS 可直接 createPixelMap，无需再做 BGRA->RGBA 转换)
    uint32_t seq = 0;           // frame 序号（每次更新递增）
    bool dirty = false;         // 是否有新帧
    std::mutex mtx;
    
    VncSession() : running(false) {}
};

static std::map<int, std::unique_ptr<VncSession>> g_vnc_sessions;
#ifdef LIBVNC_HAVE_CLIENT
// libvncclient 的 clientData 需要一个“唯一 tag”作为 key
static int g_vnc_clientdata_tag = 0;
#endif

#if defined(__OHOS__)
static void VncRenderWorker(VncSession* s)
{
    if (!s) return;

    OHNativeWindow* window = nullptr;
    uint64_t curSurfaceId = 0;
    int curW = 0;
    int curH = 0;

    s->render_running.store(true);

    auto cleanupWindow = [&]() {
        if (window) {
            OH_NativeWindow_DestroyNativeWindow(window);
            window = nullptr;
            curSurfaceId = 0;
            curW = 0;
            curH = 0;
        }
    };

    while (s->render_running.load()) {
        // 等待新帧/新surface/停止
        {
            std::unique_lock<std::mutex> lk(s->render_cv_mtx);
            s->render_cv.wait_for(lk, std::chrono::milliseconds(50), [&]() {
                return !s->render_running.load() || s->surface_dirty.load() || s->frame_dirty.load();
            });
        }
        if (!s->render_running.load()) break;

        // 1) 处理 surface 更新（在 render 线程内创建/销毁 window）
        if (s->surface_dirty.exchange(false)) {
            uint64_t targetId = 0;
            int targetW = 0;
            int targetH = 0;
            {
                std::lock_guard<std::mutex> lk(s->surface_mtx);
                targetId = s->pending_surface_id;
                targetW = s->pending_surface_w;
                targetH = s->pending_surface_h;
            }

            // surface 变更：先清旧 window
            cleanupWindow();

            if (targetId != 0) {
                OHNativeWindow* win = nullptr;
                if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(targetId, &win) == 0 && win) {
                    (void)OH_NativeWindow_NativeWindowHandleOpt(win, SET_BUFFER_GEOMETRY, targetW, targetH);
                    (void)OH_NativeWindow_NativeWindowHandleOpt(win, SET_FORMAT, (int)NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
                    // 关键：显式要求 CPU 可写的 buffer（否则 MapPlanes/GetImageLayout 可能失败，甚至 FlushBuffer 崩）
                    const uint64_t usage = (uint64_t)(
                        NATIVEBUFFER_USAGE_CPU_READ |
                        NATIVEBUFFER_USAGE_CPU_WRITE |
                        NATIVEBUFFER_USAGE_CPU_READ_OFTEN |
                        NATIVEBUFFER_USAGE_MEM_DMA
                    );
                    (void)OH_NativeWindow_NativeWindowHandleOpt(win, SET_USAGE, usage);
                    window = win;
                    curSurfaceId = targetId;
                    curW = targetW;
                    curH = targetH;
                    HilogPrint("VNC: RenderWorker bound surfaceId=" + std::to_string(curSurfaceId) +
                        " size=" + std::to_string(curW) + "x" + std::to_string(curH));
                } else {
                    HilogPrint("VNC: RenderWorker failed to create window from surfaceId=" + std::to_string(targetId));
                }
            }
        }

        // 2) 处理帧渲染
        if (!window) {
            // 没有 surface，丢弃 dirty 帧标记即可（避免堆积）
            if (s->frame_dirty.load()) s->frame_dirty.store(false);
            continue;
        }

        if (s->frame_dirty.exchange(false)) {
            int w = 0;
            int h = 0;
            std::vector<uint8_t> bgra;
            {
                std::lock_guard<std::mutex> lk(s->frame_mtx);
                w = s->fb_w;
                h = s->fb_h;
                bgra = s->fb_bgra;
            }
            if (w <= 0 || h <= 0 || bgra.empty()) continue;

            if (curW != w || curH != h) {
                (void)OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, w, h);
                (void)OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT, (int)NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
                curW = w;
                curH = h;
            }

            OHNativeWindowBuffer* wndBuf = nullptr;
            int fenceFd = -1;
            if (OH_NativeWindow_NativeWindowRequestBuffer(window, &wndBuf, &fenceFd) != 0 || !wndBuf) {
                HilogPrint("VNC: RenderWorker RequestBuffer failed, drop surface");
                cleanupWindow();
                continue;
            }
            // RequestBuffer 返回的 fence 表示该 buffer 何时可写；不等待可能导致偶发内存踩踏/闪退
            if (fenceFd >= 0) {
                struct pollfd pfd;
                pfd.fd = fenceFd;
                pfd.events = POLLIN;
                pfd.revents = 0;
                const int prc = poll(&pfd, 1, 200); // 最多等 200ms
                close(fenceFd);
                fenceFd = -1;
                if (prc <= 0) {
                    (void)OH_NativeWindow_NativeWindowAbortBuffer(window, wndBuf);
                    continue;
                }
            }

            OH_NativeBuffer* nb = nullptr;
            if (OH_NativeBuffer_FromNativeWindowBuffer(wndBuf, &nb) != 0 || !nb) {
                (void)OH_NativeWindow_NativeWindowAbortBuffer(window, wndBuf);
                continue;
            }

            // 在该机型上 MapPlanes 会频繁失败（50007000），因此直接用 GetConfig 拿 stride + Map
            OH_NativeBuffer_Config cfg{};
            OH_NativeBuffer_GetConfig(nb, &cfg);
            const int dstW = (cfg.width > 0) ? cfg.width : w;
            const int dstH = (cfg.height > 0) ? cfg.height : h;
            const uint32_t rowStride = (cfg.stride > 0) ? (uint32_t)cfg.stride : (uint32_t)dstW * 4;

            void* virAddr = nullptr;
            if (OH_NativeBuffer_Map(nb, &virAddr) != 0 || !virAddr) {
                virAddr = nullptr;
            }

            if (!virAddr) {
                (void)OH_NativeWindow_NativeWindowAbortBuffer(window, wndBuf);
                continue;
            }

            const uint8_t* src = bgra.data();
            uint8_t* dst = reinterpret_cast<uint8_t*>(virAddr);
            const int copyW = std::min(w, dstW);
            const int copyH = std::min(h, dstH);
            const size_t srcRow = (size_t)copyW * 4;
            const size_t dstRow = (size_t)rowStride;
            if (dstRow < srcRow) {
                // stride 不合理，避免越界写导致系统层崩溃
                (void)OH_NativeBuffer_Unmap(nb);
                (void)OH_NativeWindow_NativeWindowAbortBuffer(window, wndBuf);
                HilogPrint("VNC: RenderWorker invalid stride=" + std::to_string(dstRow) +
                    " < srcRow=" + std::to_string(srcRow) + ", abort buffer");
                continue;
            }
            for (int yy = 0; yy < copyH; yy++) {
                std::memcpy(dst + (size_t)yy * dstRow, src + (size_t)yy * (size_t)w * 4, srcRow);
            }
            (void)OH_NativeBuffer_Unmap(nb);

            Region::Rect rect{ 0, 0, (uint32_t)copyW, (uint32_t)copyH };
            Region region{ &rect, 1 };
            const int flushRc = OH_NativeWindow_NativeWindowFlushBuffer(window, wndBuf, -1, region);
            if (flushRc != 0) {
                HilogPrint("VNC: RenderWorker FlushBuffer rc=" + std::to_string(flushRc) + ", drop surface");
                cleanupWindow();
                continue;
            }
            // 注意：FromNativeWindowBuffer() 并未声明需要 Unreference。为避免破坏 BufferQueue 引用计数，这里不做 Unreference。
        }
    }

    cleanupWindow();
    s->render_running.store(false);
}
#endif

static napi_value VncAvailable(napi_env env, napi_callback_info info) {
    (void)info;  // 添加
    napi_value out;
#ifdef LIBVNC_HAVE_CLIENT
    napi_get_boolean(env, true, &out);
#else
    napi_get_boolean(env, false, &out);
#endif
    return out;
}

static napi_value VncCreate(napi_env env, napi_callback_info info) {
    (void)info;  // 添加
    std::lock_guard<std::mutex> lock(g_vnc_mutex);
    int id = g_vnc_next_id++;
    auto s = std::make_unique<VncSession>();
    s->id = id;
    g_vnc_sessions[id] = std::move(s);
    napi_value out; napi_create_int32(env, id, &out); return out;
}

#ifdef LIBVNC_HAVE_CLIENT
static rfbBool VncMallocFB(rfbClient* cl)
{
    if (!cl) return false;
    // Ensure 32bpp
    cl->format.bitsPerPixel = 32;
    cl->format.depth = 24;
    cl->format.bigEndian = 0;
    cl->format.trueColour = 1;
    cl->format.redMax = 255; cl->format.greenMax = 255; cl->format.blueMax = 255;
    cl->format.redShift = 16; cl->format.greenShift = 8; cl->format.blueShift = 0;

    const int w = cl->width;
    const int h = cl->height;
    const size_t bytes = (size_t)w * (size_t)h * 4;
    if (cl->frameBuffer) free(cl->frameBuffer);
    cl->frameBuffer = (uint8_t*)malloc(bytes);
    if (!cl->frameBuffer) return false;

    // 通过 clientData 直接拿到 session（避免全局 map 扫描 & 线程竞争）
    VncSession* s = reinterpret_cast<VncSession*>(rfbClientGetClientData(cl, &g_vnc_clientdata_tag));
    if (s) {
        std::lock_guard<std::mutex> lk(s->mtx);
        s->width = w;
        s->height = h;
        s->frame.resize(bytes);
    }
    return true;
}

static void VncGotUpdate(rfbClient* cl, int x, int y, int w, int h)
{
    (void)x; (void)y; (void)w; (void)h; // unused parameters
    if (!cl || !cl->frameBuffer) return;
    VncSession* s = reinterpret_cast<VncSession*>(rfbClientGetClientData(cl, &g_vnc_clientdata_tag));
    if (!s) return;
            // 把 BGRA 帧投递给 render 线程（NativeWindow 的 create/flush 必须在同一线程内完成）
#if defined(__OHOS__)
            {
                std::lock_guard<std::mutex> lk2(s->frame_mtx);
                const int ww = cl->width;
                const int hh = cl->height;
                const size_t bytes = (size_t)ww * (size_t)hh * 4;
                s->fb_w = ww;
                s->fb_h = hh;
                s->fb_bgra.resize(bytes);
                std::memcpy(s->fb_bgra.data(), cl->frameBuffer, bytes);
                s->frame_dirty.store(true);
            }
            s->render_cv.notify_one();
#else
            std::lock_guard<std::mutex> lk(s->mtx);
            if (s->width != cl->width || s->height != cl->height) {
                s->width = cl->width; s->height = cl->height; s->frame.resize((size_t)s->width * s->height * 4);
            }
            const int ww = cl->width;
            const int hh = cl->height;
            const size_t bytes = (size_t)ww * (size_t)hh * 4;
            if (s->frame.size() >= bytes) {
                const uint8_t* src = reinterpret_cast<const uint8_t*>(cl->frameBuffer);
                uint8_t* dst = s->frame.data();
                for (size_t i = 0; i < bytes; i += 4) {
                    dst[i + 0] = src[i + 2];
                    dst[i + 1] = src[i + 1];
                    dst[i + 2] = src[i + 0];
                    dst[i + 3] = 255;
                }
                s->seq++;
                s->dirty = true;
            }
#endif
            // 关键：继续请求下一帧（增量更新）。否则很多 VNC 服务端不会主动推送后续帧，
            // Viewer 会一直停在 "Display Output Is Not Active"。
            SendFramebufferUpdateRequest(cl, 0, 0, cl->width, cl->height, TRUE);
}

static void VncWorker(VncSession* s)
{
    if (!s) return;
#ifdef LIBVNC_HAVE_CLIENT
    // 重要：把 client 指针缓存到本地，避免断开时把 s->client 置空导致 worker 线程读到 nullptr
    rfbClient* cl = s->client;
    if (!cl) return;
#else
    return;
#endif
    s->running.store(true);
    while (s->running.load()) {
        int ret = WaitForMessage(cl, 100000); // 100ms
        if (ret < 0) break;
        if (ret > 0) {
            if (!HandleRFBServerMessage(cl)) {
                break;
            }
        }
    }
    s->running.store(false);
}
#endif

// 断开并清理（后台线程调用）：保证不阻塞 UI 线程
#ifdef LIBVNC_HAVE_CLIENT
static void VncStopAndCleanupAsync(VncSession* s)
{
    if (!s) return;

    std::thread tWorker;
#if defined(__OHOS__)
    std::thread tRender;
#endif
    rfbClient* oldClient = nullptr;

    {
        // 只短时间持锁：摘下 thread/client 指针，避免与 UI 线程并发访问产生数据竞争
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        s->running.store(false);
#if defined(__OHOS__)
        s->render_running.store(false);
        s->render_cv.notify_all();
#endif

        if (s->worker.joinable()) tWorker = std::move(s->worker);
#if defined(__OHOS__)
        if (s->render_worker.joinable()) tRender = std::move(s->render_worker);
#endif

        oldClient = s->client;
        s->client = nullptr;
    }

    if (tWorker.joinable()) tWorker.join();
#if defined(__OHOS__)
    if (tRender.joinable()) tRender.join();
#endif
    if (oldClient) {
        rfbClientCleanup(oldClient);
    }

#if defined(__OHOS__)
    {
        std::lock_guard<std::mutex> lk1(s->surface_mtx);
        s->pending_surface_id = 0;
        s->pending_surface_w = 0;
        s->pending_surface_h = 0;
        s->surface_dirty.store(false);
    }
    {
        std::lock_guard<std::mutex> lk2(s->frame_mtx);
        s->fb_w = 0;
        s->fb_h = 0;
        s->fb_bgra.clear();
        s->frame_dirty.store(false);
    }
#endif

    {
        std::lock_guard<std::mutex> lk(s->mtx);
        s->width = 0;
        s->height = 0;
        s->frame.clear();
        s->seq = 0;
        s->dirty = false;
    }
}

static void VncConnectAsync(VncSession* s, uint32_t seq, std::string host, int port)
{
    if (!s) return;

    // 先把旧连接/线程清掉（不阻塞 UI）
    VncStopAndCleanupAsync(s);

    // 如果期间被取消/更新了请求，则直接退出
    if (seq != s->connect_seq.load()) {
        s->connecting.store(false);
        return;
    }

    rfbClient* cl = rfbGetClient(8, 3, 4); // 32-bit truecolor
    if (!cl) {
        s->connecting.store(false);
        return;
    }
    rfbClientSetClientData(cl, &g_vnc_clientdata_tag, s);
    cl->MallocFrameBuffer = VncMallocFB;
    cl->GotFrameBufferUpdate = VncGotUpdate;
    cl->canHandleNewFBSize = 1;
    cl->appData.shareDesktop = TRUE;
    // Some HarmonyOS builds/packaged libvncclient variants may not fully support "tight"
    // and can log "Unknown encoding 'tight'" during negotiation, causing unstable/blank
    // rendering. Force a conservative, widely-supported encoding set.
    //
    // Note: we've observed libvncclient logging "Unknown encoding '<full string>'" when
    // a list is supplied, so we keep it to the most compatible baseline first.
    cl->appData.encodingsString = "raw";
    HilogPrint(std::string("VNC: forcing encodingsString=") + cl->appData.encodingsString);
    cl->serverHost = strdup(host.c_str());
    cl->serverPort = port;

    if (!rfbClientConnect(cl)) {
        rfbClientCleanup(cl);
        s->connecting.store(false);
        return;
    }
    if (!rfbClientInitialise(cl)) {
        rfbClientCleanup(cl);
        s->connecting.store(false);
        return;
    }

    // 连接完成后先请求一次全量帧，触发服务端开始发送画面
    SendFramebufferUpdateRequest(cl, 0, 0, cl->width, cl->height, FALSE);

    if (seq != s->connect_seq.load()) {
        rfbClientCleanup(cl);
        s->connecting.store(false);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        // 期间可能又被取消
        if (seq != s->connect_seq.load()) {
            // 不挂到 session 上，交给下面 cleanup
        } else {
        s->client = cl;
        s->worker = std::thread(VncWorker, s);
            cl = nullptr; // ownership moved to session
        }
    }
    if (cl) rfbClientCleanup(cl);

    s->connecting.store(false);
}
#endif

static napi_value VncConnect(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out; napi_get_boolean(env, false, &out);
    if (argc < 3) return out;
    int32_t id = 0; napi_get_value_int32(env, argv[0], &id);
    std::string host; if (!NapiGetStringUtf8(env, argv[1], host)) return out;
    int32_t port = 0; napi_get_value_int32(env, argv[2], &port);

    VncSession* s = nullptr; // unused placeholder
    {
        std::lock_guard<std::mutex> lock(g_vnc_mutex);
        if (g_vnc_sessions.find(id) == g_vnc_sessions.end()) return out;
        s = g_vnc_sessions[id].get();
    }

#ifdef LIBVNC_HAVE_CLIENT
    if (!s) return out;

    // 已连接：直接返回 true
    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        if (s->client != nullptr) {
    napi_get_boolean(env, true, &out);
            return out;
        }
    }

    // 正在连接：立即返回 false（避免阻塞 UI 线程）
    if (s->connecting.load()) {
        return out;
    }

    // 启动后台连接线程
    s->connecting.store(true);
    const uint32_t seq = s->connect_seq.fetch_add(1) + 1;
    HilogPrint("VNC: async connect requested id=" + std::to_string(id) + " " + host + ":" + std::to_string(port));
    try {
        std::thread([s, seq, host, port]() mutable {
            VncConnectAsync(s, seq, std::move(host), port);
        }).detach();
    } catch (...) {
        s->connecting.store(false);
    }
#else
    (void)host; (void)port;
    // Client lib not available
#endif
    return out;
}

static napi_value VncDisconnect(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) return nullptr;
    int32_t id = 0; napi_get_value_int32(env, argv[0], &id);
    VncSession* sess = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_vnc_mutex);
        auto it = g_vnc_sessions.find(id);
        if (it != g_vnc_sessions.end()) {
            sess = it->second.get();
        }
    }
#ifdef LIBVNC_HAVE_CLIENT
    if (sess) {
        // 取消正在进行的 connect（通过 seq 递增），并在后台做 stop/join/cleanup
        sess->connect_seq.fetch_add(1);
        HilogPrint("VNC: async disconnect requested id=" + std::to_string(id));
        try {
            std::thread([sess]() {
                VncStopAndCleanupAsync(sess);
            }).detach();
        } catch (...) {
            // ignore
        }
    }
#else
    (void)sess;
#endif
    napi_value out; napi_get_boolean(env, true, &out); return out;
}

static napi_value VncSetSurface(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    napi_get_boolean(env, false, &out);
    if (argc < 4) return out;

    int32_t id = 0;
    napi_get_value_int32(env, argv[0], &id);
    std::string surfaceIdStr;
    if (!NapiGetStringUtf8(env, argv[1], surfaceIdStr)) return out;
    int32_t w = 0;
    int32_t h = 0;
    napi_get_value_int32(env, argv[2], &w);
    napi_get_value_int32(env, argv[3], &h);
    if (w <= 0 || h <= 0) return out;

#if defined(__OHOS__)
    uint64_t surfaceId = 0;
    try {
        surfaceId = std::stoull(surfaceIdStr, nullptr, 0);
    } catch (...) {
        return out;
    }

    VncSession* sess = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_vnc_mutex);
        auto it = g_vnc_sessions.find(id);
        if (it == g_vnc_sessions.end()) return out;
        sess = it->second.get();
    }
    if (!sess) return out;

    // 只更新 pending surface，让 render 线程在同一线程内创建/flush，避免 FlushBuffer 崩溃
    {
        std::lock_guard<std::mutex> lk(sess->surface_mtx);
        sess->pending_surface_id = surfaceId;
        sess->pending_surface_w = w;
        sess->pending_surface_h = h;
        sess->surface_dirty.store(true);
    }

    // render_worker 的 thread 对象也受生命周期锁保护，避免与异步 disconnect/cleanup 并发 move/join 产生数据竞争
    {
        std::lock_guard<std::mutex> lk(sess->lifecycle_mtx);
    if (!sess->render_running.load()) {
        sess->render_running.store(true);
        sess->render_worker = std::thread(VncRenderWorker, sess);
        }
    }
    sess->render_cv.notify_one();

    napi_get_boolean(env, true, &out);
    return out;
#else
    (void)surfaceIdStr;
    (void)w;
    (void)h;
    return out;
#endif
}

static napi_value VncClearSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out;
    napi_get_boolean(env, true, &out);
    if (argc < 1) return out;

    int32_t id = 0;
    napi_get_value_int32(env, argv[0], &id);

#if defined(__OHOS__)
    VncSession* sess = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_vnc_mutex);
        auto it = g_vnc_sessions.find(id);
        if (it == g_vnc_sessions.end()) return out;
        sess = it->second.get();
    }
    if (!sess) return out;

    {
        std::lock_guard<std::mutex> lk(sess->surface_mtx);
        sess->pending_surface_id = 0;
        sess->pending_surface_w = 0;
        sess->pending_surface_h = 0;
        sess->surface_dirty.store(true);
    }
    sess->render_cv.notify_one();
#endif

    return out;
}

static napi_value VncGetFrame(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value outNull; napi_get_null(env, &outNull);
    if (argc < 1) return outNull;
    int32_t id = 0; napi_get_value_int32(env, argv[0], &id);
    std::lock_guard<std::mutex> lock(g_vnc_mutex);
    auto it = g_vnc_sessions.find(id);
    if (it == g_vnc_sessions.end()) return outNull;
    auto& s = it->second;
    std::lock_guard<std::mutex> lk(s->mtx);
    if (s->width <= 0 || s->height <= 0 || s->frame.empty()) return outNull;
    // 没有新帧就返回 null，避免 ArkTS 侧空转渲染
    if (!s->dirty) return outNull;
    s->dirty = false;

    napi_value obj; napi_create_object(env, &obj);
    napi_value w, h; napi_create_int32(env, s->width, &w); napi_create_int32(env, s->height, &h);
    napi_set_named_property(env, obj, "width", w);
    napi_set_named_property(env, obj, "height", h);
    napi_value seq; napi_create_uint32(env, s->seq, &seq);
    napi_set_named_property(env, obj, "seq", seq);

    void* data = nullptr; size_t len = s->frame.size();
    napi_value ab;
    napi_create_arraybuffer(env, len, &data, &ab);
    if (data && len) std::memcpy(data, s->frame.data(), len);
    napi_set_named_property(env, obj, "pixels", ab);
    return obj;
}
// --------------------------------------------------------------------------------------------

static napi_value VncGetInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value wVal, hVal, cVal;
    napi_create_int32(env, 0, &wVal);
    napi_create_int32(env, 0, &hVal);
    napi_get_boolean(env, false, &cVal);
    napi_set_named_property(env, obj, "width", wVal);
    napi_set_named_property(env, obj, "height", hVal);
    napi_set_named_property(env, obj, "connected", cVal);

    if (argc < 1) return obj;
    int32_t id = 0;
    napi_get_value_int32(env, argv[0], &id);

#ifdef LIBVNC_HAVE_CLIENT
    std::lock_guard<std::mutex> lock(g_vnc_mutex);
    auto it = g_vnc_sessions.find(id);
    if (it == g_vnc_sessions.end()) return obj;
    VncSession* s = it->second.get();
    if (!s) return obj;

    int w = 0;
    int h = 0;
#if defined(__OHOS__)
    // OHOS: 优先读取 rfbClient 的实时宽高（SetDesktopSize 后会立刻更新），
    // 避免仅靠 GotFrameBufferUpdate 导致宽高同步滞后 -> 坐标映射偏移 -> “点不了”。
    rfbClient* cl = nullptr;
    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        cl = s->client;
    }
    if (cl) {
        w = cl->width;
        h = cl->height;
    }
#endif
#if defined(__OHOS__)
    {
        std::lock_guard<std::mutex> lk(s->frame_mtx);
        if (w <= 0) w = s->fb_w;
        if (h <= 0) h = s->fb_h;
    }
#else
    {
        std::lock_guard<std::mutex> lk(s->mtx);
        w = s->width;
        h = s->height;
    }
#endif

    napi_create_int32(env, w, &wVal);
    napi_create_int32(env, h, &hVal);
    napi_set_named_property(env, obj, "width", wVal);
    napi_set_named_property(env, obj, "height", hVal);
    bool connected = false;
    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        connected = (s->client != nullptr);
    }
    napi_get_boolean(env, connected, &cVal);
    napi_set_named_property(env, obj, "connected", cVal);
#else
    (void)id;
#endif
    return obj;
}

static napi_value VncSendPointer(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out; napi_get_boolean(env, false, &out);
    if (argc < 4) return out;
    int32_t id = 0; napi_get_value_int32(env, argv[0], &id);
    int32_t x = 0; napi_get_value_int32(env, argv[1], &x);
    int32_t y = 0; napi_get_value_int32(env, argv[2], &y);
    int32_t mask = 0; napi_get_value_int32(env, argv[3], &mask);

#ifdef LIBVNC_HAVE_CLIENT
    std::lock_guard<std::mutex> lock(g_vnc_mutex);
    auto it = g_vnc_sessions.find(id);
    if (it == g_vnc_sessions.end()) return out;
    auto& s = it->second;
    rfbClient* cl = nullptr;
    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        cl = s->client;
    }
    if (!cl) return out;
    const rfbBool ok = SendPointerEvent(cl, x, y, mask);
    napi_get_boolean(env, ok ? true : false, &out);
#else
    (void)x; (void)y; (void)mask;
#endif
    return out;
}

static napi_value VncSendKey(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value out; napi_get_boolean(env, false, &out);
    if (argc < 3) return out;
    int32_t id = 0; napi_get_value_int32(env, argv[0], &id);
    int32_t keysym = 0; napi_get_value_int32(env, argv[1], &keysym);
    bool down = false; napi_get_value_bool(env, argv[2], &down);

#ifdef LIBVNC_HAVE_CLIENT
    std::lock_guard<std::mutex> lock(g_vnc_mutex);
    auto it = g_vnc_sessions.find(id);
    if (it == g_vnc_sessions.end()) return out;
    auto& s = it->second;
    rfbClient* cl = nullptr;
    {
        std::lock_guard<std::mutex> lk(s->lifecycle_mtx);
        cl = s->client;
    }
    if (!cl) return out;
    SendKeyEvent(cl, (rfbKeySym)keysym, down ? TRUE : FALSE);
    napi_get_boolean(env, true, &out);
#else
    (void)keysym; (void)down;
#endif
    return out;
}

// ============================================================================
// Windows 11 配置相关 NAPI 函数
// ============================================================================

/**
 * 设置 TPM 2.0 虚拟设备
 * 参数: vmName (string)
 * 返回: { success: boolean, socketPath?: string, stateDir?: string, error?: string }
 */
static napi_value SetupTpm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    napi_value result;
    napi_create_object(env, &result);
    
    if (argc < 1) {
        napi_value errVal;
        napi_create_string_utf8(env, "需要虚拟机名称参数", NAPI_AUTO_LENGTH, &errVal);
        napi_set_named_property(env, result, "error", errVal);
        napi_value successVal;
        napi_get_boolean(env, false, &successVal);
        napi_set_named_property(env, result, "success", successVal);
        return result;
    }
    
    char vmName[256] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], vmName, sizeof(vmName), &len);
    
    tpm_setup_result_t tpmResult;
    int ret = qemu_setup_tpm(vmName, &tpmResult);
    
    napi_value successVal;
    napi_get_boolean(env, tpmResult.success != 0, &successVal);
    napi_set_named_property(env, result, "success", successVal);
    
    if (tpmResult.success) {
        if (tpmResult.socket_path) {
            napi_value pathVal;
            napi_create_string_utf8(env, tpmResult.socket_path, NAPI_AUTO_LENGTH, &pathVal);
            napi_set_named_property(env, result, "socketPath", pathVal);
        }
        if (tpmResult.state_dir) {
            napi_value dirVal;
            napi_create_string_utf8(env, tpmResult.state_dir, NAPI_AUTO_LENGTH, &dirVal);
            napi_set_named_property(env, result, "stateDir", dirVal);
        }
    } else if (tpmResult.error_message) {
        napi_value errVal;
        napi_create_string_utf8(env, tpmResult.error_message, NAPI_AUTO_LENGTH, &errVal);
        napi_set_named_property(env, result, "error", errVal);
    }
    
    return result;
}

/**
 * 设置 UEFI 固件
 * 参数: vmName (string)
 * 返回: { success: boolean, codePath?: string, varsPath?: string, error?: string }
 */
static napi_value SetupUefi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    napi_value result;
    napi_create_object(env, &result);
    
    if (argc < 1) {
        napi_value errVal;
        napi_create_string_utf8(env, "需要虚拟机名称参数", NAPI_AUTO_LENGTH, &errVal);
        napi_set_named_property(env, result, "error", errVal);
        napi_value successVal;
        napi_get_boolean(env, false, &successVal);
        napi_set_named_property(env, result, "success", successVal);
        return result;
    }
    
    char vmName[256] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], vmName, sizeof(vmName), &len);
    
    uefi_setup_result_t uefiResult;
    int ret = qemu_setup_uefi(vmName, &uefiResult);
    
    napi_value successVal;
    napi_get_boolean(env, uefiResult.success != 0, &successVal);
    napi_set_named_property(env, result, "success", successVal);
    
    if (uefiResult.success) {
        if (uefiResult.code_path) {
            napi_value pathVal;
            napi_create_string_utf8(env, uefiResult.code_path, NAPI_AUTO_LENGTH, &pathVal);
            napi_set_named_property(env, result, "codePath", pathVal);
        }
        if (uefiResult.vars_path) {
            napi_value varsVal;
            napi_create_string_utf8(env, uefiResult.vars_path, NAPI_AUTO_LENGTH, &varsVal);
            napi_set_named_property(env, result, "varsPath", varsVal);
        }
    } else if (uefiResult.error_message) {
        napi_value errVal;
        napi_create_string_utf8(env, uefiResult.error_message, NAPI_AUTO_LENGTH, &errVal);
        napi_set_named_property(env, result, "error", errVal);
    }
    
    return result;
}

/**
 * 检查 Windows 11 兼容性
 * 参数: vmName (string, 可选)
 * 返回: { tpmAvailable, uefiAvailable, secureBootAvailable, overallCompatible, ... }
 */
static napi_value CheckWin11Compatibility(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    const char* vmName = nullptr;
    char vmNameBuf[256] = {0};
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], vmNameBuf, sizeof(vmNameBuf), &len);
        if (len > 0) vmName = vmNameBuf;
    }
    
    win11_compatibility_result_t compat;
    qemu_check_win11_compatibility(vmName, &compat);
    
    napi_value result;
    napi_create_object(env, &result);
    
    napi_value tpmVal, uefiVal, sbVal, overallVal;
    napi_get_boolean(env, compat.tpm_available != 0, &tpmVal);
    napi_get_boolean(env, compat.uefi_available != 0, &uefiVal);
    napi_get_boolean(env, compat.secure_boot_available != 0, &sbVal);
    napi_get_boolean(env, compat.overall_compatible != 0, &overallVal);
    
    napi_set_named_property(env, result, "tpmAvailable", tpmVal);
    napi_set_named_property(env, result, "uefiAvailable", uefiVal);
    napi_set_named_property(env, result, "secureBootAvailable", sbVal);
    napi_set_named_property(env, result, "overallCompatible", overallVal);
    
    if (compat.tpm_status) {
        napi_value statusVal;
        napi_create_string_utf8(env, compat.tpm_status, NAPI_AUTO_LENGTH, &statusVal);
        napi_set_named_property(env, result, "tpmStatus", statusVal);
    }
    if (compat.uefi_status) {
        napi_value statusVal;
        napi_create_string_utf8(env, compat.uefi_status, NAPI_AUTO_LENGTH, &statusVal);
        napi_set_named_property(env, result, "uefiStatus", statusVal);
    }
    if (compat.secure_boot_status) {
        napi_value statusVal;
        napi_create_string_utf8(env, compat.secure_boot_status, NAPI_AUTO_LENGTH, &statusVal);
        napi_set_named_property(env, result, "secureBootStatus", statusVal);
    }
    
    return result;
}

/**
 * 启用/禁用 Secure Boot
 * 参数: vmName (string), enable (boolean)
 * 返回: boolean
 */
static napi_value EnableSecureBoot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 2) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    
    char vmName[256] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], vmName, sizeof(vmName), &len);
    
    bool enable = false;
    napi_get_value_bool(env, argv[1], &enable);
    
    int ret = qemu_enable_secure_boot(vmName, enable ? 1 : 0);
    
    napi_value result;
    napi_get_boolean(env, ret == 0, &result);
    return result;
}

// 写入 VM 控制台
static napi_value WriteToVmConsole(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        return nullptr;
    }

    char buffer[1024];
    size_t len;
    napi_get_value_string_utf8(env, args[0], buffer, sizeof(buffer), &len);

    if (g_logCapture) {
        // 添加换行符如果需要
        std::string data(buffer, len);
        // 优先写入 TCP 串口（-serial tcp:...），否则回退到 stdin pipe
        bool sent = false;
        {
            std::lock_guard<std::mutex> lk(g_serial_mtx);
            if (g_serial_fd != -1) {
                ssize_t n = send(g_serial_fd, data.c_str(), data.size(), 0);
                if (n > 0) sent = true;
                if (n <= 0) SerialCloseLocked();
            }
        }
        if (!sent) {
            g_logCapture->WriteToStdin(data);
        }
    }

    return nullptr;
}

// 设置控制台回调
static napi_value SetConsoleCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) return nullptr;
    
    napi_value resourceName;
    napi_create_string_utf8(env, "ConsoleCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    // 如果已有回调，先释放
    if (g_consoleCallback) {
        // 停掉串口桥接（避免旧回调继续收数据）
        SerialStop();
        napi_release_threadsafe_function(g_consoleCallback, napi_tsfn_abort);
    }
    
    napi_create_threadsafe_function(env, args[0], nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr, ConsoleJsCallback, &g_consoleCallback);
    // 启动串口桥接：自动连接 tcp:127.0.0.1:4321 并把数据推到 JS
    SerialStart();
    
    return nullptr;
}

/**
 * 生成 Windows 11 优化的 QEMU 命令参数
 * 参数: vmName (string), memoryMb (number), diskPath (string), isoPath (string)
 * 返回: string
 */
static napi_value BuildWin11Args(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 4) {
        napi_value result;
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &result);
        return result;
    }
    
    char vmName[256] = {0};
    char diskPath[512] = {0};
    char isoPath[512] = {0};
    size_t len = 0;
    
    napi_get_value_string_utf8(env, argv[0], vmName, sizeof(vmName), &len);
    
    int32_t memoryMb = 4096;
    napi_get_value_int32(env, argv[1], &memoryMb);
    
    napi_get_value_string_utf8(env, argv[2], diskPath, sizeof(diskPath), &len);
    napi_get_value_string_utf8(env, argv[3], isoPath, sizeof(isoPath), &len);
    
    const char* args = qemu_build_win11_args(vmName, memoryMb, diskPath, isoPath);
    
    napi_value result;
    napi_create_string_utf8(env, args ? args : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

/**
 * 检查 UEFI 是否可用
 * 返回: boolean
 */
static napi_value IsUefiAvailable(napi_env env, napi_callback_info info) {
    int available = qemu_is_uefi_available();
    napi_value result;
    napi_get_boolean(env, available != 0, &result);
    return result;
}

/**
 * 检查 TPM 是否可用
 * 参数: vmName (string, 可选)
 * 返回: boolean
 */
static napi_value IsTpmAvailable(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    const char* vmName = nullptr;
    char vmNameBuf[256] = {0};
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], vmNameBuf, sizeof(vmNameBuf), &len);
        if (len > 0) vmName = vmNameBuf;
    }
    
    int available = qemu_is_tpm_available(vmName);
    napi_value result;
    napi_get_boolean(env, available != 0, &result);
    return result;
}

// ============================================================================

static napi_value TestFunction(napi_env env, napi_callback_info info) {
    HilogPrint("QEMU: TestFunction called!");
    HilogPrint("QEMU: TestFunction - NAPI module is working correctly!");
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// 添加一个简单的模块信息函数
static napi_value GetModuleInfo(napi_env env, napi_callback_info info) {
    HilogPrint("QEMU: GetModuleInfo called!");
    napi_value result;
    napi_create_object(env, &result);
    
    napi_value name, version, status;
    napi_create_string_utf8(env, "qemu_hmos", NAPI_AUTO_LENGTH, &name);
    napi_create_string_utf8(env, "1.0.0", NAPI_AUTO_LENGTH, &version);
    napi_create_string_utf8(env, "loaded", NAPI_AUTO_LENGTH, &status);
    
    napi_set_named_property(env, result, "name", name);
    napi_set_named_property(env, result, "version", version);
    napi_set_named_property(env, result, "status", status);
    
    return result;
}

// 模块初始化
EXTERN_C_START
// Keep exports stable; ArkTS depends on these names.
static napi_value Init(napi_env env, napi_value exports) {
    HilogPrint("QEMU: ========================================");
    HilogPrint("QEMU: NAPI Init function called!");
    HilogPrint("QEMU: Environment pointer: " + std::to_string(reinterpret_cast<uintptr_t>(env)));
    HilogPrint("QEMU: Exports pointer: " + std::to_string(reinterpret_cast<uintptr_t>(exports)));
    HilogPrint("QEMU: Module name: qemu_hmos");
    HilogPrint("QEMU: ========================================");
#if defined(__OHOS__)
    napi_property_descriptor desc[] = {
        { "version", 0, GetVersion, 0, 0, 0, napi_default, 0 },
        { "enableJit", 0, EnableJit, 0, 0, 0, napi_default, 0 },
        { "kvmSupported", 0, KvmSupported, 0, 0, 0, napi_default, 0 },
        { "startVm", 0, StartVm, 0, 0, 0, napi_default, 0 },
        { "stopVm", 0, StopVm, 0, 0, 0, napi_default, 0 },
        { "getVmLogs", 0, GetVmLogs, 0, 0, 0, napi_default, 0 },
        { "getVmStatus", 0, GetVmStatus, 0, 0, 0, napi_default, 0 },
        { "checkCoreLib", 0, CheckCoreLib, 0, 0, 0, napi_default, 0 },
        { "getDeviceCapabilities", 0, GetDeviceCapabilities, 0, 0, 0, napi_default, 0 },
        { "getSupportedDevices", 0, GetSupportedDevices, 0, 0, 0, napi_default, 0 },
        { "scanQemuDevices", 0, ScanQemuDevices, 0, 0, 0, napi_default, 0 },
        { "scanQemuDevicesAsync", 0, ScanQemuDevicesAsync, 0, 0, 0, napi_default, 0 },
        { "clearDeviceCache", 0, ClearDeviceCache, 0, 0, 0, napi_default, 0 },
        { "probeQemuDevices", 0, ProbeQemuDevices, 0, 0, 0, napi_default, 0 },
        { "pauseVm", 0, PauseVm, 0, 0, 0, napi_default, 0 },
        { "resumeVm", 0, ResumeVm, 0, 0, 0, napi_default, 0 },
        { "createSnapshot", 0, CreateSnapshot, 0, 0, 0, napi_default, 0 },
        { "restoreSnapshot", 0, RestoreSnapshot, 0, 0, 0, napi_default, 0 },
        { "listSnapshots", 0, ListSnapshots, 0, 0, 0, napi_default, 0 },
        { "deleteSnapshot", 0, DeleteSnapshot, 0, 0, 0, napi_default, 0 },
        { "createRdpClient", 0, CreateRdpClient, 0, 0, 0, napi_default, 0 },
        { "connectRdp", 0, ConnectRdp, 0, 0, 0, napi_default, 0 },
        { "disconnectRdp", 0, DisconnectRdp, 0, 0, 0, napi_default, 0 },
        { "getRdpStatus", 0, GetRdpStatus, 0, 0, 0, napi_default, 0 },
        { "destroyRdpClient", 0, DestroyRdpClient, 0, 0, 0, napi_default, 0 },
        { "rdpSendKey", 0, RdpSendKey, 0, 0, 0, napi_default, 0 },
        // RDP 超时处理
        { "rdpCheckTimeout", 0, RdpCheckTimeout, 0, 0, 0, napi_default, 0 },
        { "rdpSetTimeout", 0, RdpSetTimeout, 0, 0, 0, napi_default, 0 },
        { "rdpRequestCancel", 0, RdpRequestCancel, 0, 0, 0, napi_default, 0 },
        { "rdpForceCleanup", 0, RdpForceCleanup, 0, 0, 0, napi_default, 0 },
        { "rdpGetStatusString", 0, RdpGetStatusString, 0, 0, 0, napi_default, 0 },
        // Native VNC (client)
        { "vncAvailable", 0, VncAvailable, 0, 0, 0, napi_default, 0 },
        { "vncCreate", 0, VncCreate, 0, 0, 0, napi_default, 0 },
        { "vncConnect", 0, VncConnect, 0, 0, 0, napi_default, 0 },
        { "vncDisconnect", 0, VncDisconnect, 0, 0, 0, napi_default, 0 },
        { "vncGetFrame", 0, VncGetFrame, 0, 0, 0, napi_default, 0 },
        { "vncGetInfo", 0, VncGetInfo, 0, 0, 0, napi_default, 0 },
        { "vncSendPointer", 0, VncSendPointer, 0, 0, 0, napi_default, 0 },
        { "vncSendKey", 0, VncSendKey, 0, 0, 0, napi_default, 0 },
        { "vncSetSurface", 0, VncSetSurface, 0, 0, 0, napi_default, 0 },
        { "vncClearSurface", 0, VncClearSurface, 0, 0, 0, napi_default, 0 },
        // Windows 11 配置相关
        { "setupTpm", 0, SetupTpm, 0, 0, 0, napi_default, 0 },
        { "setupUefi", 0, SetupUefi, 0, 0, 0, napi_default, 0 },
        { "checkWin11Compatibility", 0, CheckWin11Compatibility, 0, 0, 0, napi_default, 0 },
        { "enableSecureBoot", 0, EnableSecureBoot, 0, 0, 0, napi_default, 0 },
        { "buildWin11Args", 0, BuildWin11Args, 0, 0, 0, napi_default, 0 },
        { "isUefiAvailable", 0, IsUefiAvailable, 0, 0, 0, napi_default, 0 },
        { "isTpmAvailable", 0, IsTpmAvailable, 0, 0, 0, napi_default, 0 },
        { "testFunction", 0, TestFunction, 0, 0, 0, napi_default, 0 },
        { "getModuleInfo", 0, GetModuleInfo, 0, 0, 0, napi_default, 0 },
        { "writeToVmConsole", 0, WriteToVmConsole, 0, 0, 0, napi_default, 0 },
        { "setConsoleCallback", 0, SetConsoleCallback, 0, 0, 0, napi_default, 0 },
        // QMP screendump（VNC 替代方案）
        { "takeScreenshot", 0, TakeScreenshot, 0, 0, 0, napi_default, 0 },
        // Disk tools (qemu-img / built-in qcow2 create)
        { "qemuImgCreateDisk", 0, QemuImgCreateDisk, 0, 0, 0, napi_default, 0 },
        { "qemuImgResizeDisk", 0, QemuImgResizeDisk, 0, 0, 0, napi_default, 0 },
    };
#else
    napi_property_descriptor__ desc[] = {
        { "version", GetVersion, 0 },
        { "enableJit", EnableJit, 0 },
        { "kvmSupported", KvmSupported, 0 },
        { "startVm", StartVm, 0 },
        { "stopVm", StopVm, 0 },
        { "getVmLogs", GetVmLogs, 0 },
        { "getVmStatus", GetVmStatus, 0 },
        { "checkCoreLib", CheckCoreLib, 0 },
        { "createRdpClient", CreateRdpClient, 0 },
        { "connectRdp", ConnectRdp, 0 },
        { "disconnectRdp", DisconnectRdp, 0 },
        { "getRdpStatus", GetRdpStatus, 0 },
        { "destroyRdpClient", DestroyRdpClient, 0 },
        { "rdpSendKey", RdpSendKey, 0 },
        // RDP 超时处理
        { "rdpCheckTimeout", RdpCheckTimeout, 0 },
        { "rdpSetTimeout", RdpSetTimeout, 0 },
        { "rdpRequestCancel", RdpRequestCancel, 0 },
        { "rdpForceCleanup", RdpForceCleanup, 0 },
        { "rdpGetStatusString", RdpGetStatusString, 0 },
        // Native VNC (client)
        { "vncAvailable", VncAvailable, 0 },
        { "vncCreate", VncCreate, 0 },
        { "vncConnect", VncConnect, 0 },
        { "vncDisconnect", VncDisconnect, 0 },
        { "vncGetFrame", VncGetFrame, 0 },
        { "vncGetInfo", VncGetInfo, 0 },
        { "vncSendPointer", VncSendPointer, 0 },
        { "vncSendKey", VncSendKey, 0 },
        { "vncSetSurface", VncSetSurface, 0 },
        { "vncClearSurface", VncClearSurface, 0 },
        // Windows 11 配置相关
        { "setupTpm", SetupTpm, 0 },
        { "setupUefi", SetupUefi, 0 },
        { "checkWin11Compatibility", CheckWin11Compatibility, 0 },
        { "enableSecureBoot", EnableSecureBoot, 0 },
        { "buildWin11Args", BuildWin11Args, 0 },
        { "isUefiAvailable", IsUefiAvailable, 0 },
        { "isTpmAvailable", IsTpmAvailable, 0 },
        { "testFunction", TestFunction, 0 },
        { "getModuleInfo", GetModuleInfo, 0 },
        { "writeToVmConsole", WriteToVmConsole, 0 },
        { "setConsoleCallback", SetConsoleCallback, 0 },
        // QMP screendump（VNC 替代方案）
        { "takeScreenshot", TakeScreenshot, 0 },
        // Disk tools (qemu-img / built-in qcow2 create)
        { "qemuImgCreateDisk", QemuImgCreateDisk, 0 },
        { "qemuImgResizeDisk", QemuImgResizeDisk, 0 },
    };
#endif
    size_t count = sizeof(desc) / sizeof(desc[0]);
#if defined(__OHOS__)
    napi_define_properties(env, exports, count, desc);
#else
    napi_define_properties(env, exports, count, (const napi_property_descriptor*)desc);
#endif
    return exports;
}
EXTERN_C_END

#if defined(__OHOS__)
// HarmonyOS NAPI 模块注册
// 使用 "qemu_hmos" 作为模块名（不能用 "entry"，那是保留名称会被 hvigor 覆盖）
// 对应 libqemu_hmos.so
// 只使用 NAPI_MODULE 宏进行注册，不要使用 __attribute__((constructor))
// 否则会导致双重注册冲突
NAPI_MODULE(qemu_hmos, Init)
#else
static napi_module_simple qemuModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "qemu_hmos",  // 模块名称必须与 ArkTS 中的 requireNativeModule('qemu_hmos') 匹配
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};
extern "C" __attribute__((constructor)) void RegisterQemuModule(void) {
    napi_module_register(&qemuModule);
}
#endif
