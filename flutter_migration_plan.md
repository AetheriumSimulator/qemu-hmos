# Flutter迁移实施计划

## 1. 创建Flutter项目

```bash
# 创建Flutter项目
flutter create qemu_hmos_flutter --platforms=android,ios

# 进入项目目录
cd qemu_hmos_flutter

# 添加鸿蒙平台支持（需要自定义）
# 这里需要手动配置鸿蒙平台支持
```

## 2. 项目结构

```
qemu_hmos_flutter/
├── lib/
│   ├── main.dart
│   ├── pages/
│   │   ├── home_page.dart
│   │   ├── vnc_viewer_page.dart
│   │   └── rdp_viewer_page.dart
│   ├── widgets/
│   │   ├── vm_card.dart
│   │   ├── system_capability_card.dart
│   │   └── create_vm_dialog.dart
│   ├── services/
│   │   ├── qemu_service.dart
│   │   ├── vm_manager.dart
│   │   └── file_manager.dart
│   └── models/
│       ├── vm_config.dart
│       └── vm_status.dart
├── harmonyos/
│   ├── cpp/
│   │   ├── method_channel_handler.cpp
│   │   ├── qemu_wrapper.cpp
│   │   └── napi_bridge.cpp
│   └── libs/
│       └── arm64-v8a/
│           └── libqemu_full.so
└── pubspec.yaml
```

## 3. 核心服务层实现

### QemuService (lib/services/qemu_service.dart)
```dart
import 'package:flutter/services.dart';

class QemuService {
  static const MethodChannel _channel = MethodChannel('qemu_hmos');
  
  // 系统能力检测
  static Future<Map<String, dynamic>> getSystemCapabilities() async {
    try {
      final result = await _channel.invokeMethod('getSystemCapabilities');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      throw Exception('获取系统能力失败: ${e.message}');
    }
  }
  
  // 启动虚拟机
  static Future<bool> startVM(Map<String, dynamic> config) async {
    try {
      final result = await _channel.invokeMethod('startVM', config);
      return result as bool;
    } on PlatformException catch (e) {
      throw Exception('启动虚拟机失败: ${e.message}');
    }
  }
  
  // 停止虚拟机
  static Future<bool> stopVM(String vmName) async {
    try {
      final result = await _channel.invokeMethod('stopVM', {'name': vmName});
      return result as bool;
    } on PlatformException catch (e) {
      throw Exception('停止虚拟机失败: ${e.message}');
    }
  }
  
  // 获取虚拟机状态
  static Future<String> getVMStatus(String vmName) async {
    try {
      final result = await _channel.invokeMethod('getVMStatus', {'name': vmName});
      return result as String;
    } on PlatformException catch (e) {
      throw Exception('获取虚拟机状态失败: ${e.message}');
    }
  }
  
  // 获取虚拟机列表
  static Future<List<Map<String, dynamic>>> getVMList() async {
    try {
      final result = await _channel.invokeMethod('getVMList');
      return List<Map<String, dynamic>>.from(result);
    } on PlatformException catch (e) {
      throw Exception('获取虚拟机列表失败: ${e.message}');
    }
  }
  
  // 创建虚拟机
  static Future<bool> createVM(Map<String, dynamic> config) async {
    try {
      final result = await _channel.invokeMethod('createVM', config);
      return result as bool;
    } on PlatformException catch (e) {
      throw Exception('创建虚拟机失败: ${e.message}');
    }
  }
  
  // 删除虚拟机
  static Future<bool> deleteVM(String vmName) async {
    try {
      final result = await _channel.invokeMethod('deleteVM', {'name': vmName});
      return result as bool;
    } on PlatformException catch (e) {
      throw Exception('删除虚拟机失败: ${e.message}');
    }
  }
  
  // 获取虚拟机日志
  static Future<List<String>> getVMLogs(String vmName) async {
    try {
      final result = await _channel.invokeMethod('getVMLogs', {'name': vmName});
      return List<String>.from(result);
    } on PlatformException catch (e) {
      throw Exception('获取虚拟机日志失败: ${e.message}');
    }
  }
}
```

### VMManager (lib/services/vm_manager.dart)
```dart
import 'qemu_service.dart';
import '../models/vm_config.dart';
import '../models/vm_status.dart';

class VMManager {
  static final VMManager _instance = VMManager._internal();
  factory VMManager() => _instance;
  VMManager._internal();
  
  List<VMStatus> _vms = [];
  Map<String, dynamic> _systemCapabilities = {};
  
  // 获取系统能力
  Future<Map<String, dynamic>> getSystemCapabilities() async {
    _systemCapabilities = await QemuService.getSystemCapabilities();
    return _systemCapabilities;
  }
  
  // 获取虚拟机列表
  Future<List<VMStatus>> getVMList() async {
    try {
      final vmData = await QemuService.getVMList();
      _vms = vmData.map((data) => VMStatus.fromMap(data)).toList();
      return _vms;
    } catch (e) {
      print('获取虚拟机列表失败: $e');
      return [];
    }
  }
  
  // 创建虚拟机
  Future<bool> createVM(VMConfig config) async {
    try {
      final success = await QemuService.createVM(config.toMap());
      if (success) {
        await getVMList(); // 刷新列表
      }
      return success;
    } catch (e) {
      print('创建虚拟机失败: $e');
      return false;
    }
  }
  
  // 启动虚拟机
  Future<bool> startVM(String vmName) async {
    try {
      final success = await QemuService.startVM({'name': vmName});
      if (success) {
        await getVMList(); // 刷新列表
      }
      return success;
    } catch (e) {
      print('启动虚拟机失败: $e');
      return false;
    }
  }
  
  // 停止虚拟机
  Future<bool> stopVM(String vmName) async {
    try {
      final success = await QemuService.stopVM(vmName);
      if (success) {
        await getVMList(); // 刷新列表
      }
      return success;
    } catch (e) {
      print('停止虚拟机失败: $e');
      return false;
    }
  }
  
  // 删除虚拟机
  Future<bool> deleteVM(String vmName) async {
    try {
      final success = await QemuService.deleteVM(vmName);
      if (success) {
        await getVMList(); // 刷新列表
      }
      return success;
    } catch (e) {
      print('删除虚拟机失败: $e');
      return false;
    }
  }
}
```

## 4. 数据模型

### VMConfig (lib/models/vm_config.dart)
```dart
class VMConfig {
  final String name;
  final String archType;
  final String osType;
  final int diskSizeGB;
  final int memoryMB;
  final int cpuCount;
  final String? isoPath;
  
  VMConfig({
    required this.name,
    this.archType = 'aarch64',
    this.osType = 'Windows',
    this.diskSizeGB = 64,
    this.memoryMB = 6144,
    this.cpuCount = 4,
    this.isoPath,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'archType': archType,
      'osType': osType,
      'diskSizeGB': diskSizeGB,
      'memoryMB': memoryMB,
      'cpuCount': cpuCount,
      'isoPath': isoPath,
    };
  }
  
  factory VMConfig.fromMap(Map<String, dynamic> map) {
    return VMConfig(
      name: map['name'] ?? '',
      archType: map['archType'] ?? 'aarch64',
      osType: map['osType'] ?? 'Windows',
      diskSizeGB: map['diskSizeGB'] ?? 64,
      memoryMB: map['memoryMB'] ?? 6144,
      cpuCount: map['cpuCount'] ?? 4,
      isoPath: map['isoPath'],
    );
  }
}
```

### VMStatus (lib/models/vm_status.dart)
```dart
enum VMState {
  creating,
  preparing,
  running,
  stopping,
  stopped,
  failed,
  starting,
}

class VMStatus {
  final String id;
  final String name;
  final String osType;
  final VMState status;
  final DateTime createdAt;
  final VMConfig config;
  
  VMStatus({
    required this.id,
    required this.name,
    required this.osType,
    required this.status,
    required this.createdAt,
    required this.config,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'osType': osType,
      'status': status.name,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'config': config.toMap(),
    };
  }
  
  factory VMStatus.fromMap(Map<String, dynamic> map) {
    return VMStatus(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      osType: map['osType'] ?? 'Windows',
      status: VMState.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => VMState.stopped,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] ?? 0),
      config: VMConfig.fromMap(Map<String, dynamic>.from(map['config'] ?? {})),
    );
  }
}
```

## 5. C++ Method Channel Handler

### method_channel_handler.cpp
```cpp
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar.h>
#include <memory>
#include "qemu_wrapper.h"

class QemuMethodChannelHandler {
public:
    QemuMethodChannelHandler() {
        // 初始化QEMU
        qemu_init();
    }
    
    ~QemuMethodChannelHandler() {
        // 清理QEMU
        qemu_cleanup();
    }
    
    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        if (call.method_name() == "getSystemCapabilities") {
            HandleGetSystemCapabilities(std::move(result));
        } else if (call.method_name() == "startVM") {
            HandleStartVM(call, std::move(result));
        } else if (call.method_name() == "stopVM") {
            HandleStopVM(call, std::move(result));
        } else if (call.method_name() == "getVMStatus") {
            HandleGetVMStatus(call, std::move(result));
        } else if (call.method_name() == "getVMList") {
            HandleGetVMList(std::move(result));
        } else if (call.method_name() == "createVM") {
            HandleCreateVM(call, std::move(result));
        } else if (call.method_name() == "deleteVM") {
            HandleDeleteVM(call, std::move(result));
        } else if (call.method_name() == "getVMLogs") {
            HandleGetVMLogs(call, std::move(result));
        } else {
            result->NotImplemented();
        }
    }
    
private:
    void HandleGetSystemCapabilities(
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        flutter::EncodableMap capabilities;
        
        // 检测KVM支持
        capabilities[flutter::EncodableValue("kvmSupported")] = 
            flutter::EncodableValue(qemu_detect_kvm_support() == 1);
        
        // 检测JIT支持
        capabilities[flutter::EncodableValue("jitSupported")] = 
            flutter::EncodableValue(true); // 假设支持
        
        // 获取QEMU版本
        capabilities[flutter::EncodableValue("version")] = 
            flutter::EncodableValue(std::string(qemu_get_version()));
        
        // 获取系统信息
        capabilities[flutter::EncodableValue("totalMemory")] = 
            flutter::EncodableValue(GetTotalMemory());
        
        capabilities[flutter::EncodableValue("cpuCores")] = 
            flutter::EncodableValue(GetCPUCores());
        
        result->Success(flutter::EncodableValue(capabilities));
    }
    
    void HandleStartVM(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            
            // 构建QEMU配置
            qemu_vm_config_t config = {};
            
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            config.name = name.c_str();
            
            auto archType = std::get<std::string>(args.at(flutter::EncodableValue("archType")));
            config.arch_type = archType.c_str();
            
            config.memory_mb = std::get<int32_t>(args.at(flutter::EncodableValue("memoryMB")));
            config.cpu_count = std::get<int32_t>(args.at(flutter::EncodableValue("cpuCount")));
            config.disk_size_gb = std::get<int32_t>(args.at(flutter::EncodableValue("diskSizeGB")));
            
            // 设置其他配置...
            config.network_mode = "user";
            config.display_mode = "vnc";
            config.accel_mode = qemu_detect_kvm_support() ? "kvm" : "tcg";
            
            // 创建并启动虚拟机
            auto handle = qemu_vm_create(&config);
            if (handle) {
                int start_result = qemu_vm_start(handle);
                result->Success(flutter::EncodableValue(start_result == 0));
            } else {
                result->Success(flutter::EncodableValue(false));
            }
            
        } catch (const std::exception& e) {
            result->Error("START_VM_ERROR", e.what());
        }
    }
    
    void HandleStopVM(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            
            // 查找虚拟机句柄并停止
            // 这里需要实现虚拟机查找逻辑
            result->Success(flutter::EncodableValue(true));
            
        } catch (const std::exception& e) {
            result->Error("STOP_VM_ERROR", e.what());
        }
    }
    
    void HandleGetVMStatus(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            
            // 查找虚拟机并获取状态
            // 这里需要实现状态查询逻辑
            result->Success(flutter::EncodableValue("stopped"));
            
        } catch (const std::exception& e) {
            result->Error("GET_VM_STATUS_ERROR", e.what());
        }
    }
    
    void HandleGetVMList(
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            // 返回虚拟机列表
            flutter::EncodableList vmList;
            // 这里需要实现虚拟机列表获取逻辑
            result->Success(flutter::EncodableValue(vmList));
            
        } catch (const std::exception& e) {
            result->Error("GET_VM_LIST_ERROR", e.what());
        }
    }
    
    void HandleCreateVM(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            
            // 创建虚拟机配置
            qemu_vm_config_t config = {};
            
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            config.name = name.c_str();
            
            auto archType = std::get<std::string>(args.at(flutter::EncodableValue("archType")));
            config.arch_type = archType.c_str();
            
            config.memory_mb = std::get<int32_t>(args.at(flutter::EncodableValue("memoryMB")));
            config.cpu_count = std::get<int32_t>(args.at(flutter::EncodableValue("cpuCount")));
            config.disk_size_gb = std::get<int32_t>(args.at(flutter::EncodableValue("diskSizeGB")));
            
            // 设置其他配置...
            config.network_mode = "user";
            config.display_mode = "vnc";
            config.accel_mode = qemu_detect_kvm_support() ? "kvm" : "tcg";
            
            // 创建虚拟机
            auto handle = qemu_vm_create(&config);
            result->Success(flutter::EncodableValue(handle != nullptr));
            
        } catch (const std::exception& e) {
            result->Error("CREATE_VM_ERROR", e.what());
        }
    }
    
    void HandleDeleteVM(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            
            // 查找并删除虚拟机
            // 这里需要实现虚拟机删除逻辑
            result->Success(flutter::EncodableValue(true));
            
        } catch (const std::exception& e) {
            result->Error("DELETE_VM_ERROR", e.what());
        }
    }
    
    void HandleGetVMLogs(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        
        try {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto name = std::get<std::string>(args.at(flutter::EncodableValue("name")));
            
            // 获取虚拟机日志
            flutter::EncodableList logs;
            // 这里需要实现日志获取逻辑
            result->Success(flutter::EncodableValue(logs));
            
        } catch (const std::exception& e) {
            result->Error("GET_VM_LOGS_ERROR", e.what());
        }
    }
    
    // 辅助函数
    int64_t GetTotalMemory() {
        // 获取系统总内存
        return 8 * 1024 * 1024 * 1024; // 8GB
    }
    
    int32_t GetCPUCores() {
        // 获取CPU核心数
        return 8;
    }
};

// 全局处理器实例
static std::unique_ptr<QemuMethodChannelHandler> g_handler;

// 插件注册函数
void RegisterQemuPlugin(flutter::PluginRegistrar* registrar) {
    auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "qemu_hmos",
        &flutter::StandardMethodCodec::GetInstance());
    
    g_handler = std::make_unique<QemuMethodChannelHandler>();
    
    channel->SetMethodCallHandler([&](const auto& call, auto result) {
        g_handler->HandleMethodCall(call, std::move(result));
    });
}
```

## 6. 主页面实现

### home_page.dart
```dart
import 'package:flutter/material.dart';
import '../services/vm_manager.dart';
import '../models/vm_status.dart';
import '../widgets/system_capability_card.dart';
import '../widgets/vm_card.dart';
import '../widgets/create_vm_dialog.dart';
import 'vnc_viewer_page.dart';
import 'rdp_viewer_page.dart';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final VMManager _vmManager = VMManager();
  List<VMStatus> _vms = [];
  Map<String, dynamic> _systemCapabilities = {};
  bool _isLoading = false;
  String _errorMessage = '';
  
  late TabController _tabController;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
  
  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    
    try {
      // 并行加载系统能力和虚拟机列表
      final futures = await Future.wait([
        _vmManager.getSystemCapabilities(),
        _vmManager.getVMList(),
      ]);
      
      setState(() {
        _systemCapabilities = futures[0] as Map<String, dynamic>;
        _vms = futures[1] as List<VMStatus>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }
  
  Future<void> _createVM(VMConfig config) async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final success = await _vmManager.createVM(config);
      if (success) {
        await _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机创建成功')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机创建失败')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _startVM(VMStatus vm) async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final success = await _vmManager.startVM(vm.name);
      if (success) {
        await _loadData();
        // 跳转到VNC查看器
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VNCViewerPage(vmName: vm.name),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机启动失败')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启动失败: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _stopVM(VMStatus vm) async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final success = await _vmManager.stopVM(vm.name);
      if (success) {
        await _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机已停止')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机停止失败')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('停止失败: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _deleteVM(VMStatus vm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除'),
        content: Text('确定要删除虚拟机 "${vm.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('删除'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      setState(() {
        _isLoading = true;
      });
      
      try {
        final success = await _vmManager.deleteVM(vm.name);
        if (success) {
          await _loadData();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('虚拟机已删除')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('虚拟机删除失败')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('QEMU虚拟机管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '虚拟机', icon: Icon(Icons.computer)),
            Tab(text: '应用', icon: Icon(Icons.apps)),
            Tab(text: '我的', icon: Icon(Icons.person)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildVMTab(),
          _buildAppsTab(),
          _buildMineTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateVMDialog(),
        child: Icon(Icons.add),
        tooltip: '创建虚拟机',
      ),
    );
  }
  
  Widget _buildVMTab() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }
    
    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text('加载失败: $_errorMessage'),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadData,
              child: Text('重试'),
            ),
          ],
        ),
      );
    }
    
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: EdgeInsets.all(16),
        children: [
          // 系统能力检测卡片
          SystemCapabilityCard(capabilities: _systemCapabilities),
          SizedBox(height: 16),
          
          // 虚拟机列表
          if (_vms.isEmpty)
            _buildEmptyState()
          else
            ..._vms.map((vm) => Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: VMCard(
                vm: vm,
                onStart: () => _startVM(vm),
                onStop: () => _stopVM(vm),
                onDelete: () => _deleteVM(vm),
              ),
            )),
        ],
      ),
    );
  }
  
  Widget _buildAppsTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.apps, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('应用管理功能开发中...'),
        ],
      ),
    );
  }
  
  Widget _buildMineTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('个人中心功能开发中...'),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(Icons.computer_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              '暂无虚拟机',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(height: 8),
            Text(
              '点击右下角按钮创建第一个虚拟机',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showCreateVMDialog() {
    showDialog(
      context: context,
      builder: (context) => CreateVMDialog(
        onCreate: _createVM,
      ),
    );
  }
}
```

这个方案的核心优势：

1. **完全分离**：Flutter负责UI，C++负责QEMU集成
2. **Method Channel**：标准化的跨平台通信
3. **保持现有C++代码**：最小化改动
4. **Flutter优势**：开发效率高，UI丰富
5. **可扩展性**：未来可以轻松支持其他平台

您觉得这个架构设计如何？需要我详细实现某个部分吗？