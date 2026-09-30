#include "rdp_client.h"
#include <iostream>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <atomic>
#include <chrono>
#include <thread>

// RDP 协议常量
#define RDP_DEFAULT_PORT 3389
#define RDP_CONNECT_TIMEOUT_MS 5000
#define RDP_PROTOCOL_TPKT_VERSION 3

// 连接状态追踪（内部使用，与 RdpConnectionState 枚举不同）
// 使用最简单的 volatile 变量，完全避免 C++ 原子操作可能的兼容性问题
static volatile bool g_rdp_connected = false;
static volatile bool g_rdp_connecting = false;
static volatile bool g_rdp_cancel_requested = false;
static volatile int64_t g_rdp_last_activity_ms = 0;
static volatile int g_rdp_timeout_seconds = 30;
static pthread_t g_rdp_worker_thread = 0;

// 注意：上面使用简单的 volatile 全局变量替代了 std::atomic
// 这样可以完全避免 C++ 原子操作可能导致的 SIGILL 问题

// 更新活动时间戳
static void rdp_update_activity() {
    auto now = std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    g_rdp_last_activity_ms = ms;
}

// 检查是否超时（返回超时秒数，0表示未超时）
extern "C" int rdp_check_timeout() {
    if (!g_rdp_connecting && !g_rdp_connected) {
        return 0;  // 未在连接中
    }
    
    auto now = std::chrono::steady_clock::now();
    auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    
    int64_t last = g_rdp_last_activity_ms;
    if (last == 0) return 0;
    
    int64_t elapsed_sec = (now_ms - last) / 1000;
    int timeout = g_rdp_timeout_seconds;
    
    if (elapsed_sec > timeout) {
        return static_cast<int>(elapsed_sec);
    }
    return 0;
}

// 设置超时时间
extern "C" void rdp_set_timeout(int seconds) {
    if (seconds > 0 && seconds < 3600) {
        g_rdp_timeout_seconds = seconds;
    }
}

// 请求取消连接
extern "C" void rdp_request_cancel() {
    g_rdp_cancel_requested = true;
    
    // 发送信号中断阻塞的线程
    if (g_rdp_worker_thread != 0) {
        pthread_kill(g_rdp_worker_thread, SIGUSR1);
    }
}

// 检查是否已请求取消
extern "C" int rdp_is_cancel_requested() {
    return g_rdp_cancel_requested ? 1 : 0;
}

// 强制清理（即使线程没退出也清理资源）
extern "C" void rdp_force_cleanup() {
    // 标记取消
    g_rdp_cancel_requested = true;
    
    // 发送信号
    if (g_rdp_worker_thread != 0) {
        pthread_kill(g_rdp_worker_thread, SIGUSR1);
        
        // 等待最多2秒
        for (int i = 0; i < 20; i++) {
            if (!g_rdp_connecting && !g_rdp_connected) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    
    // 强制重置状态（即使线程还在运行）
    g_rdp_connected = false;
    g_rdp_connecting = false;
    g_rdp_worker_thread = 0;
    g_rdp_cancel_requested = false;
    g_rdp_last_activity_ms = 0;
    
    // 注意：这里可能会有线程泄漏，但比卡死整个应用好
    // 泄漏的线程在收到信号后最终会自己退出
}

// 获取连接状态字符串
extern "C" const char* rdp_get_status_string() {
    if (g_rdp_cancel_requested) {
        return "cancelling";  // 正在取消
    }
    if (g_rdp_connecting) {
        int timeout_sec = rdp_check_timeout();
        if (timeout_sec > 0) {
            return "timeout";  // 超时
        }
        return "connecting";  // 连接中
    }
    if (g_rdp_connected) {
        return "connected";  // 已连接
    }
    return "disconnected";  // 未连接
}

// RDP 客户端实现 - 带有真正的网络连接
class RdpClient::Impl {
public:
    Impl() : socket_fd(-1), state(RdpConnectionState::DISCONNECTED), connected(false) {}
    
    ~Impl() {
        disconnect();
    }
    
    // 尝试建立 TCP 连接
    bool establish_tcp_connection(const std::string& host, int port) {
        struct addrinfo hints, *result, *rp;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;     // IPv4 或 IPv6
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_NUMERICSERV;
        
        std::string port_str = std::to_string(port);
        int ret = getaddrinfo(host.c_str(), port_str.c_str(), &hints, &result);
        if (ret != 0) {
            last_error = "DNS resolution failed: " + std::string(gai_strerror(ret));
            return false;
        }
        
        // 尝试连接每个解析出的地址
        for (rp = result; rp != nullptr; rp = rp->ai_next) {
            socket_fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (socket_fd == -1) {
                continue;
            }
            
            // 设置非阻塞模式
            int flags = fcntl(socket_fd, F_GETFL, 0);
            fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK);
            
            // 尝试连接
            ret = ::connect(socket_fd, rp->ai_addr, rp->ai_addrlen);
            if (ret == -1 && errno != EINPROGRESS) {
                close(socket_fd);
                socket_fd = -1;
                continue;
            }
            
            // 等待连接完成
            struct pollfd pfd;
            pfd.fd = socket_fd;
            pfd.events = POLLOUT;
            
            ret = poll(&pfd, 1, RDP_CONNECT_TIMEOUT_MS);
            if (ret <= 0) {
                close(socket_fd);
                socket_fd = -1;
                continue;
            }
            
            // 检查连接是否成功
            int error = 0;
            socklen_t len = sizeof(error);
            if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &error, &len) < 0 || error != 0) {
                close(socket_fd);
                socket_fd = -1;
                continue;
            }
            
            // 恢复阻塞模式
            fcntl(socket_fd, F_SETFL, flags);
            
            // 连接成功
            freeaddrinfo(result);
            return true;
        }
        
        freeaddrinfo(result);
        last_error = "Failed to connect to " + host + ":" + port_str;
        return false;
    }
    
    // 发送 RDP 初始协商请求（X.224 Connection Request）
    bool send_rdp_negotiation() {
        if (socket_fd < 0) {
            return false;
        }
        
        // RDP 协商请求数据包
        // TPKT Header (4 bytes) + X.224 CR (7 bytes) + RDP NEG REQ (8 bytes)
        unsigned char rdp_neg_req[] = {
            // TPKT Header
            0x03, 0x00, 0x00, 0x13,  // Version 3, Reserved, Length 19
            // X.224 Connection Request
            0x0e,                     // Length indicator (14)
            0xe0,                     // CR | CDT
            0x00, 0x00,               // DST-REF
            0x00, 0x00,               // SRC-REF
            0x00,                     // Class 0
            // RDP Negotiation Request
            0x01,                     // TYPE_RDP_NEG_REQ
            0x00,                     // flags
            0x08, 0x00,               // length (8)
            0x03, 0x00, 0x00, 0x00    // PROTOCOL_SSL | PROTOCOL_HYBRID
        };
        
        ssize_t sent = send(socket_fd, rdp_neg_req, sizeof(rdp_neg_req), 0);
        if (sent != sizeof(rdp_neg_req)) {
            last_error = "Failed to send RDP negotiation request";
            return false;
        }
        
        // 等待响应
        unsigned char response[256];
        struct pollfd pfd;
        pfd.fd = socket_fd;
        pfd.events = POLLIN;
        
        if (poll(&pfd, 1, 3000) <= 0) {
            last_error = "RDP server did not respond";
            return false;
        }
        
        ssize_t received = recv(socket_fd, response, sizeof(response), 0);
        if (received < 11) {
            last_error = "Invalid RDP response";
            return false;
        }
        
        // 检查 TPKT 版本
        if (response[0] != RDP_PROTOCOL_TPKT_VERSION) {
            last_error = "Invalid TPKT version";
            return false;
        }
        
        // 检查 X.224 响应类型
        if ((response[5] & 0xf0) != 0xd0) {  // CC (Connection Confirm)
            last_error = "RDP connection refused";
            return false;
        }
        
        return true;
    }
    
    bool connect(const RdpConnectionConfig& config) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (connected) {
            last_error = "Already connected";
            return false;
        }
        
        // 更新状态
        state = RdpConnectionState::CONNECTING;
        if (callbacks.on_state_changed) {
            callbacks.on_state_changed(state);
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Connecting to " + config.host + ":" + std::to_string(config.port));
        }
        
        // 验证连接参数
        if (config.host.empty() || config.port <= 0) {
            state = RdpConnectionState::ERROR;
            last_error = "Invalid host or port";
            if (callbacks.on_state_changed) {
                callbacks.on_state_changed(state);
            }
            return false;
        }
        
        // 步骤1: 建立 TCP 连接
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Establishing TCP connection...");
        }
        
        if (!establish_tcp_connection(config.host, config.port)) {
            state = RdpConnectionState::ERROR;
            if (callbacks.on_state_changed) {
                callbacks.on_state_changed(state);
            }
            if (callbacks.on_log_message) {
                callbacks.on_log_message("[RDP] TCP connection failed: " + last_error);
            }
            return false;
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] TCP connection established");
        }
        
        // 步骤2: RDP 协议协商
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Sending RDP negotiation request...");
        }
        
        if (!send_rdp_negotiation()) {
            close(socket_fd);
            socket_fd = -1;
            state = RdpConnectionState::ERROR;
            if (callbacks.on_state_changed) {
                callbacks.on_state_changed(state);
            }
        if (callbacks.on_log_message) {
                callbacks.on_log_message("[RDP] Negotiation failed: " + last_error);
            }
            return false;
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] RDP negotiation successful");
        }
        
        // 保存配置
            connection_config = config;
            connected = true;
            state = RdpConnectionState::CONNECTED;
            
            if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Connection established to " + config.host + ":" + std::to_string(config.port));
            }
            
            if (callbacks.on_state_changed) {
                callbacks.on_state_changed(state);
            }
        
        // NOTE: 完整的 RDP 会话需要实现:
        // - TLS/SSL 握手
        // - NTLM/CredSSP 认证  
        // - MCS 通道建立
        // - 许可证协商
        // - 图形通道初始化
        // 这些需要完整的 FreeRDP 库支持
            
            return true;
    }
    
    int socket_fd;
    
    void disconnect() {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            return;
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Disconnecting...");
        }
        
        // 关闭 socket
        if (socket_fd >= 0) {
            close(socket_fd);
            socket_fd = -1;
        }
        
        connected = false;
        state = RdpConnectionState::DISCONNECTED;
        
        if (callbacks.on_state_changed) {
            callbacks.on_state_changed(state);
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("[RDP] Disconnected");
        }
    }
    
    bool is_connected() const {
        std::lock_guard<std::mutex> lock(mutex);
        return connected;
    }
    
    RdpConnectionState get_connection_state() const {
        std::lock_guard<std::mutex> lock(mutex);
        return state;
    }
    
    bool set_resolution(int width, int height) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.width = width;
        connection_config.height = height;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Resolution set to " + std::to_string(width) + "x" + std::to_string(height));
        }
        
        return true;
    }
    
    bool set_color_depth(int depth) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.color_depth = depth;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Color depth set to " + std::to_string(depth));
        }
        
        return true;
    }
    
    bool send_mouse_event(int x, int y, int button, bool pressed) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        if (callbacks.on_mouse_event) {
            callbacks.on_mouse_event(x, y, button, pressed);
        }
        
        return true;
    }
    
    bool send_keyboard_event(int key, bool pressed) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        if (callbacks.on_keyboard_event) {
            callbacks.on_keyboard_event(key, pressed);
        }
        
        return true;
    }
    
    bool send_text_input(const std::string& text) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Text input: " + text);
        }
        
        return true;
    }
    
    bool enable_clipboard_sharing(bool enable) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.enable_clipboard = enable;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Clipboard sharing " + std::string(enable ? "enabled" : "disabled"));
        }
        
        return true;
    }
    
    std::string get_clipboard_text() const {
        std::lock_guard<std::mutex> lock(mutex);
        return clipboard_text;
    }
    
    bool set_clipboard_text(const std::string& text) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        clipboard_text = text;
        
        if (callbacks.on_clipboard_data) {
            callbacks.on_clipboard_data(text);
        }
        
        return true;
    }
    
    bool enable_file_sharing(bool enable) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.enable_file_sharing = enable;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("File sharing " + std::string(enable ? "enabled" : "disabled"));
        }
        
        return true;
    }
    
    bool set_shared_folder(const std::string& path) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.shared_folder = path;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Shared folder set to: " + path);
        }
        
        return true;
    }
    
    std::string get_shared_folder() const {
        std::lock_guard<std::mutex> lock(mutex);
        return connection_config.shared_folder;
    }
    
    bool enable_audio(bool enable) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        connection_config.enable_audio = enable;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Audio " + std::string(enable ? "enabled" : "disabled"));
        }
        
        return true;
    }
    
    bool set_audio_volume(int volume) {
        std::lock_guard<std::mutex> lock(mutex);
        
        if (!connected) {
            last_error = "Not connected";
            return false;
        }
        
        if (volume < 0 || volume > 100) {
            last_error = "Volume must be between 0 and 100";
            return false;
        }
        
        audio_volume = volume;
        
        if (callbacks.on_log_message) {
            callbacks.on_log_message("Audio volume set to " + std::to_string(volume));
        }
        
        return true;
    }
    
    int get_audio_volume() const {
        std::lock_guard<std::mutex> lock(mutex);
        return audio_volume;
    }
    
    void set_callbacks(const RdpCallbacks& cb) {
        std::lock_guard<std::mutex> lock(mutex);
        callbacks = cb;
    }
    
    std::string get_last_error() const {
        std::lock_guard<std::mutex> lock(mutex);
        return last_error;
    }
    
private:
    mutable std::mutex mutex;
    RdpConnectionState state;
    bool connected;
    RdpConnectionConfig connection_config;
    RdpCallbacks callbacks;
    std::string last_error;
    std::string clipboard_text;
    int audio_volume = 50;
};

// RdpClient实现
RdpClient::RdpClient() {
    pImpl = std::make_unique<Impl>();
}

RdpClient::~RdpClient() = default;

bool RdpClient::connect(const RdpConnectionConfig& config) {
    return pImpl->connect(config);
}

void RdpClient::disconnect() {
    pImpl->disconnect();
}

bool RdpClient::is_connected() const {
    return pImpl->is_connected();
}

RdpConnectionState RdpClient::get_connection_state() const {
    return pImpl->get_connection_state();
}

bool RdpClient::set_resolution(int width, int height) {
    return pImpl->set_resolution(width, height);
}

bool RdpClient::set_color_depth(int depth) {
    return pImpl->set_color_depth(depth);
}

bool RdpClient::enable_fullscreen(bool enable) {
    // 实现全屏功能
    (void)enable;  // 暂未实现，避免未使用参数警告
    return true;
}

bool RdpClient::send_mouse_event(int x, int y, int button, bool pressed) {
    return pImpl->send_mouse_event(x, y, button, pressed);
}

bool RdpClient::send_keyboard_event(int key, bool pressed) {
    return pImpl->send_keyboard_event(key, pressed);
}

bool RdpClient::send_text_input(const std::string& text) {
    return pImpl->send_text_input(text);
}

bool RdpClient::enable_clipboard_sharing(bool enable) {
    return pImpl->enable_clipboard_sharing(enable);
}

std::string RdpClient::get_clipboard_text() const {
    return pImpl->get_clipboard_text();
}

bool RdpClient::set_clipboard_text(const std::string& text) {
    return pImpl->set_clipboard_text(text);
}

bool RdpClient::enable_file_sharing(bool enable) {
    return pImpl->enable_file_sharing(enable);
}

bool RdpClient::set_shared_folder(const std::string& path) {
    return pImpl->set_shared_folder(path);
}

std::string RdpClient::get_shared_folder() const {
    return pImpl->get_shared_folder();
}

bool RdpClient::enable_audio(bool enable) {
    return pImpl->enable_audio(enable);
}

bool RdpClient::set_audio_volume(int volume) {
    return pImpl->set_audio_volume(volume);
}

int RdpClient::get_audio_volume() const {
    return pImpl->get_audio_volume();
}

void RdpClient::set_callbacks(const RdpCallbacks& callbacks) {
    pImpl->set_callbacks(callbacks);
}

std::string RdpClient::get_last_error() const {
    return pImpl->get_last_error();
}

// RdpManager实现
RdpManager& RdpManager::getInstance() {
    static RdpManager instance;
    return instance;
}

std::shared_ptr<RdpClient> RdpManager::createClient() {
    auto client = std::make_shared<RdpClient>();
    clients.push_back(client);
    return client;
}

std::vector<std::shared_ptr<RdpClient>> RdpManager::getClients() const {
    return clients;
}

void RdpManager::closeAllConnections() {
    for (auto& client : clients) {
        if (client) {
            client->disconnect();
        }
    }
}

void RdpManager::setGlobalConfig(const RdpConnectionConfig& config) {
    globalConfig = config;
}

RdpConnectionConfig RdpManager::getGlobalConfig() const {
    return globalConfig;
}
