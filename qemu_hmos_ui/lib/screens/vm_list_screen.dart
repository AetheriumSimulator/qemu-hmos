import 'package:flutter/material.dart';
import '../services/qemu_bridge_service.dart';

/// 虚拟机列表页面
class VmListScreen extends StatefulWidget {
  const VmListScreen({Key? key}) : super(key: key);

  @override
  State<VmListScreen> createState() => _VmListScreenState();
}

class _VmListScreenState extends State<VmListScreen> {
  final QemuBridgeService _qemuService = QemuBridgeService();
  
  String _qemuVersion = '加载中...';
  DeviceCapabilities? _capabilities;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  /// 加载设备信息
  Future<void> _loadDeviceInfo() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 并行获取版本和设备能力
      final results = await Future.wait([
        _qemuService.getVersion(),
        _qemuService.getDeviceCapabilities(),
      ]);

      setState(() {
        _qemuVersion = results[0] as String;
        _capabilities = results[1] as DeviceCapabilities;
        _isLoading = false;
      });
    } on QemuException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    }
  }

  /// 启动测试虚拟机
  Future<void> _startTestVm() async {
    final config = VmConfig(
      name: 'test-vm',
      memoryMB: 1024,
      cpuCount: 2,
      accel: _capabilities?.kvmSupported == true ? 'kvm' : 'tcg',
      display: 'vnc',
    );

    try {
      final result = await _qemuService.startVm(config);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('虚拟机启动成功: $result')),
        );
      }
    } on QemuException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('启动失败: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: SafeArea(
        child: Stack(
          children: [
            // 主内容
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? _buildErrorView()
                    : _buildContentView(),
            
            // 右下角悬浮按钮
            Positioned(
              right: 20,
              bottom: 120, // 避让胶囊导航栏
              child: FloatingActionButton.extended(
                onPressed: _startTestVm,
                icon: const Icon(Icons.play_arrow),
                label: const Text('启动虚拟机'),
                tooltip: '启动测试虚拟机',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建错误视图
  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            '加载失败',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _loadDeviceInfo,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// 构建内容视图
  Widget _buildContentView() {
    return CustomScrollView(
      slivers: [
        // 标题栏
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '虚拟机',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'QEMU $_qemuVersion',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                ),
              ],
            ),
          ),
        ),
        
        // 内容卡片
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _buildCapabilitiesCard(),
              const SizedBox(height: 16),
              _buildQuickActionsCard(),
              const SizedBox(height: 100), // 底部留白避让胶囊导航栏
            ]),
          ),
        ),
      ],
    );
  }

  /// 构建信息卡片
  Widget _buildInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'QEMU信息',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('版本'),
              subtitle: Text(_qemuVersion),
            ),
            ListTile(
              leading: const Icon(Icons.devices),
              title: const Text('平台'),
              subtitle: const Text('HarmonyOS NEXT'),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建设备能力卡片
  Widget _buildCapabilitiesCard() {
    if (_capabilities == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '设备能力',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            _buildCapabilityRow(
              '硬件加速(KVM)',
              _capabilities!.kvmSupported,
            ),
            _buildCapabilityRow(
              'JIT即时编译',
              _capabilities!.jitSupported,
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('系统内存'),
              subtitle: Text('${_capabilities!.totalMemory} MB'),
            ),
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('CPU核心'),
              subtitle: Text('${_capabilities!.cpuCores} 核'),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建能力行
  Widget _buildCapabilityRow(String label, bool supported) {
    return ListTile(
      leading: Icon(
        supported ? Icons.check_circle : Icons.cancel,
        color: supported ? Colors.green : Colors.grey,
      ),
      title: Text(label),
      subtitle: Text(supported ? '支持' : '不支持'),
    );
  }

  /// 构建快速操作卡片
  Widget _buildQuickActionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '快速操作',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('创建虚拟机'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                // TODO: 导航到创建虚拟机页面
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('功能开发中...')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('查看虚拟机列表'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                // TODO: 导航到虚拟机列表
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('功能开发中...')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('设置'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                // TODO: 导航到设置页面
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('功能开发中...')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

