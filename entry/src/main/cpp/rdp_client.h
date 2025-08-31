#ifndef RDP_CLIENT_H
#define RDP_CLIENT_H

#include <string>
#include <functional>
#include <memory>

// RDP连接状态
enum class RdpConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    ERROR
};

// RDP连接配置
struct RdpConnectionConfig {
    std::string host;
    int port;
    std::string username;
    std::string password;
    std::string domain;
    int width;
    int height;
    int color_depth;
    bool enable_audio;
    bool enable_clipboard;
    bool enable_file_sharing;
    std::string shared_folder;
};

// RDP事件回调
struct RdpCallbacks {
    std::function<void(RdpConnectionState state)> on_state_changed;
    std::function<void(const std::string& message)> on_log_message;
    std::function<void(int x, int y, int button, bool pressed)> on_mouse_event;
    std::function<void(int key, bool pressed)> on_keyboard_event;
    std::function<void(const std::string& text)> on_clipboard_data;
};

// RDP客户端类
class RdpClient {
public:
    RdpClient();
    ~RdpClient();

    // 连接管理
    bool connect(const RdpConnectionConfig& config);
    void disconnect();
    bool is_connected() const;
    RdpConnectionState get_connection_state() const;

    // 显示控制
    bool set_resolution(int width, int height);
    bool set_color_depth(int depth);
    bool enable_fullscreen(bool enable);

    // 输入控制
    bool send_mouse_event(int x, int y, int button, bool pressed);
    bool send_keyboard_event(int key, bool pressed);
    bool send_text_input(const std::string& text);

    // 剪贴板
    bool enable_clipboard_sharing(bool enable);
    std::string get_clipboard_text() const;
    bool set_clipboard_text(const std::string& text);

    // 文件共享
    bool enable_file_sharing(bool enable);
    bool set_shared_folder(const std::string& path);
    std::string get_shared_folder() const;

    // 音频控制
    bool enable_audio(bool enable);
    bool set_audio_volume(int volume);
    int get_audio_volume() const;

    // 设置回调
    void set_callbacks(const RdpCallbacks& callbacks);

    // 获取错误信息
    std::string get_last_error() const;

private:
    class Impl;
    std::unique_ptr<Impl> pImpl;
};

// RDP管理器类
class RdpManager {
public:
    static RdpManager& getInstance();
    
    // 创建RDP客户端
    std::shared_ptr<RdpClient> createClient();
    
    // 获取可用的RDP客户端列表
    std::vector<std::shared_ptr<RdpClient>> getClients() const;
    
    // 关闭所有RDP连接
    void closeAllConnections();
    
    // 设置全局配置
    void setGlobalConfig(const RdpConnectionConfig& config);
    RdpConnectionConfig getGlobalConfig() const;

private:
    RdpManager() = default;
    ~RdpManager() = default;
    RdpManager(const RdpManager&) = delete;
    RdpManager& operator=(const RdpManager&) = delete;
    
    std::vector<std::shared_ptr<RdpClient>> clients;
    RdpConnectionConfig globalConfig;
};

#endif // RDP_CLIENT_H
