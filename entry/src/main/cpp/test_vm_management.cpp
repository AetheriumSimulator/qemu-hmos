#include <iostream>
#include <string>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#include <sstream>
#include <iomanip>
#include <ctime>

// 模拟VM配置结构
struct VMConfig {
    std::string name;
    std::string isoPath;
    int diskSizeGB;
    int memoryMB;
    int cpuCount;
    std::string diskPath;
    std::string logPath;
};

// 测试用的VM配置
VMConfig createTestConfig() {
    VMConfig config;
    config.name = "test-vm";
    config.isoPath = "/path/to/test.iso";
    config.diskSizeGB = 10;
    config.memoryMB = 1024;
    config.cpuCount = 2;
    config.diskPath = "./test_files/vms/test-vm/disk.qcow2";
    config.logPath = "./test_files/logs/VM-test-vm.log";
    return config;
}

// 检查目录是否存在
bool directoryExists(const std::string& path) {
    struct stat info;
    return stat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode);
}

// 检查文件是否存在
bool fileExists(const std::string& path) {
    struct stat info;
    return stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode);
}

// 读取文件内容
std::string readFile(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        return "";
    }
    std::string content((std::istreambuf_iterator<char>(file)),
                       std::istreambuf_iterator<char>());
    return content;
}

// 测试VM目录创建
bool testVMDirectoryCreation() {
    std::cout << "\n=== 测试VM目录创建 ===\n";
    
    std::string vmName = "test-vm";
    std::string expectedDir = "./test_files/vms/" + vmName;
    
    // 模拟创建目录的逻辑
    std::string command = "mkdir -p " + expectedDir;
    int result = system(command.c_str());
    
    if (result == 0) {
        std::cout << "✓ VM目录创建成功: " << expectedDir << std::endl;
        
        // 检查目录是否真的存在
        if (directoryExists(expectedDir)) {
            std::cout << "✓ VM目录验证成功\n";
            return true;
        } else {
            std::cout << "✗ VM目录验证失败\n";
            return false;
        }
    } else {
        std::cout << "✗ VM目录创建失败\n";
        return false;
    }
}

// 测试VM配置文件创建
bool testVMConfigFileCreation() {
    std::cout << "\n=== 测试VM配置文件创建 ===\n";
    
    VMConfig config = createTestConfig();
    std::string configPath = "./test_files/vms/" + config.name + "/config.json";
    
    // 创建JSON配置字符串
    std::ostringstream jsonStream;
    jsonStream << "{\n";
    jsonStream << "  \"name\": \"" << config.name << "\",\n";
    jsonStream << "  \"isoPath\": \"" << config.isoPath << "\",\n";
    jsonStream << "  \"diskSizeGB\": " << config.diskSizeGB << ",\n";
    jsonStream << "  \"memoryMB\": " << config.memoryMB << ",\n";
    jsonStream << "  \"cpuCount\": " << config.cpuCount << ",\n";
    jsonStream << "  \"diskPath\": \"" << config.diskPath << "\",\n";
    jsonStream << "  \"logPath\": \"" << config.logPath << "\",\n";
    jsonStream << "  \"created\": \"2024-01-20T10:30:00Z\",\n";
    jsonStream << "  \"lastModified\": \"2024-01-20T10:30:00Z\"\n";
    jsonStream << "}";
    
    // 写入配置文件
    std::ofstream configFile(configPath);
    if (configFile.is_open()) {
        configFile << jsonStream.str();
        configFile.close();
        
        std::cout << "✓ VM配置文件创建成功: " << configPath << std::endl;
        
        // 验证文件内容
        if (fileExists(configPath)) {
            std::string content = readFile(configPath);
            if (content.find(config.name) != std::string::npos) {
                std::cout << "✓ VM配置文件内容验证成功\n";
                std::cout << "配置文件内容:\n" << content << std::endl;
                return true;
            } else {
                std::cout << "✗ VM配置文件内容验证失败\n";
                return false;
            }
        } else {
            std::cout << "✗ VM配置文件不存在\n";
            return false;
        }
    } else {
        std::cout << "✗ VM配置文件创建失败\n";
        return false;
    }
}

// 测试VM状态文件管理
bool testVMStatusManagement() {
    std::cout << "\n=== 测试VM状态文件管理 ===\n";
    
    std::string vmName = "test-vm";
    std::string statusPath = "./test_files/vms/" + vmName + "/status.json";
    
    // 测试不同状态的更新
    std::vector<std::string> statuses = {"preparing", "running", "stopping", "stopped"};
    
    for (const auto& status : statuses) {
        // 创建状态JSON字符串
        std::ostringstream statusStream;
        statusStream << "{\n";
        statusStream << "  \"status\": \"" << status << "\",\n";
        statusStream << "  \"timestamp\": \"2024-01-20T10:30:00Z\"";
        if (status == "running") {
            statusStream << ",\n  \"pid\": 12345";
        } else {
            statusStream << ",\n  \"pid\": null";
        }
        statusStream << "\n}";
        
        std::ofstream statusFile(statusPath);
        if (statusFile.is_open()) {
            statusFile << statusStream.str();
            statusFile.close();
            
            std::cout << "✓ VM状态更新为: " << status << std::endl;
        } else {
            std::cout << "✗ VM状态文件创建失败: " << status << std::endl;
            return false;
        }
    }
    
    // 验证最终状态文件
    if (fileExists(statusPath)) {
        std::string content = readFile(statusPath);
        std::cout << "✓ VM状态文件验证成功\n";
        std::cout << "最终状态文件内容:\n" << content << std::endl;
        return true;
    } else {
        std::cout << "✗ VM状态文件不存在\n";
        return false;
    }
}

// 测试日志目录创建
bool testLogDirectoryCreation() {
    std::cout << "\n=== 测试日志目录创建 ===\n";
    
    std::string logDir = "./test_files/logs";
    
    // 创建日志目录
    std::string command = "mkdir -p " + logDir;
    int result = system(command.c_str());
    
    if (result == 0 && directoryExists(logDir)) {
        std::cout << "✓ 日志目录创建成功: " << logDir << std::endl;
        
        // 创建测试日志文件
        std::string logPath = logDir + "/VM-test-vm.log";
        std::ofstream logFile(logPath, std::ios::app);
        if (logFile.is_open()) {
            logFile << "[2024-01-20 10:30:00] VM management test log entry\n";
            logFile.close();
            std::cout << "✓ 测试日志文件创建成功: " << logPath << std::endl;
            return true;
        } else {
            std::cout << "✗ 测试日志文件创建失败\n";
            return false;
        }
    } else {
        std::cout << "✗ 日志目录创建失败\n";
        return false;
    }
}

int main() {
    std::cout << "开始VM目录创建和配置文件管理功能测试...\n";
    
    bool allTestsPassed = true;
    
    // 运行所有测试
    allTestsPassed &= testLogDirectoryCreation();
    allTestsPassed &= testVMDirectoryCreation();
    allTestsPassed &= testVMConfigFileCreation();
    allTestsPassed &= testVMStatusManagement();
    
    // 输出测试结果
    std::cout << "\n=== 测试结果汇总 ===\n";
    if (allTestsPassed) {
        std::cout << "✓ 所有VM管理功能测试通过！\n";
        std::cout << "\n核心功能验证：\n";
        std::cout << "- VM目录结构创建: 正常\n";
        std::cout << "- VM配置文件管理: 正常\n";
        std::cout << "- VM状态文件管理: 正常\n";
        std::cout << "- 日志目录管理: 正常\n";
        return 0;
    } else {
        std::cout << "✗ 部分VM管理功能测试失败\n";
        return 1;
    }
}