import 'package:flutter/services.dart';
import 'dart:async';

/// QEMU虚拟机桥接服务
/// 通过MethodChannel与HarmonyOS Native层通信
class QemuBridgeService {
  static const MethodChannel _channel = MethodChannel('qemu.bridge');

  /// 获取QEMU版本号
  /// 
  /// 返回: QEMU版本字符串，例如 "8.2.0"
  /// 异常: PlatformException 当QEMU未正确集成时
  Future<String> getVersion() async {
    try {
      final String version = await _channel.invokeMethod('version');
      return version;
    } on PlatformException catch (e) {
      throw QemuException('获取版本失败: ${e.message}', e.code);
    }
  }

  /// 获取设备能力信息
  /// 
  /// 返回: DeviceCapabilities 包含KVM/JIT支持状态
  Future<DeviceCapabilities> getDeviceCapabilities() async {
    try {
      final Map<dynamic, dynamic> result = 
          await _channel.invokeMethod('getDeviceCapabilities');
      return DeviceCapabilities.fromMap(result);
    } on PlatformException catch (e) {
      throw QemuException('获取设备能力失败: ${e.message}', e.code);
    }
  }

  /// 启动虚拟机
  /// 
  /// [config] 虚拟机配置参数
  /// 返回: 虚拟机启动结果消息
  /// 异常: QemuException 当启动失败时
  Future<String> startVm(VmConfig config) async {
    try {
      final String result = await _channel.invokeMethod('startVm', config.toMap());
      return result;
    } on PlatformException catch (e) {
      throw QemuException('启动虚拟机失败: ${e.message}', e.code);
    }
  }

  /// 停止虚拟机
  /// 
  /// [vmName] 虚拟机名称
  /// 返回: true表示成功停止
  Future<bool> stopVm(String vmName) async {
    try {
      final bool result = await _channel.invokeMethod('stopVm', {
        'name': vmName,
      });
      return result;
    } on PlatformException catch (e) {
      throw QemuException('停止虚拟机失败: ${e.message}', e.code);
    }
  }

  /// 获取虚拟机日志
  /// 
  /// [vmName] 虚拟机名称
  /// [startLine] 起始行号（可选，默认0）
  /// 返回: 日志行数组
  Future<List<String>> getVmLogs(String vmName, {int startLine = 0}) async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('getVmLogs', {
        'name': vmName,
        'startLine': startLine,
      });
      return result.cast<String>();
    } on PlatformException catch (e) {
      throw QemuException('获取日志失败: ${e.message}', e.code);
    }
  }
}

/// 虚拟机配置
class VmConfig {
  /// 虚拟机名称（必填）
  final String name;
  
  /// ISO镜像路径（可选）
  final String? isoPath;
  
  /// 磁盘大小（GB，1-256）
  final int? diskSizeGB;
  
  /// 内存大小（MB，512-8192）
  final int? memoryMB;
  
  /// CPU核心数（1-8）
  final int? cpuCount;
  
  /// 加速器类型（kvm/tcg）
  final String? accel;
  
  /// 显示类型（vnc/none）
  final String? display;
  
  /// 是否无图形模式
  final bool? nographic;

  VmConfig({
    required this.name,
    this.isoPath,
    this.diskSizeGB,
    this.memoryMB = 2048,
    this.cpuCount = 2,
    this.accel = 'tcg',
    this.display = 'vnc',
    this.nographic = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      if (isoPath != null) 'isoPath': isoPath,
      if (diskSizeGB != null) 'diskSizeGB': diskSizeGB,
      if (memoryMB != null) 'memoryMB': memoryMB,
      if (cpuCount != null) 'cpuCount': cpuCount,
      if (accel != null) 'accel': accel,
      if (display != null) 'display': display,
      if (nographic != null) 'nographic': nographic,
    };
  }
}

/// 设备能力信息
class DeviceCapabilities {
  /// 是否支持KVM硬件加速
  final bool kvmSupported;
  
  /// 是否支持JIT即时编译
  final bool jitSupported;
  
  /// 总内存大小（MB）
  final int totalMemory;
  
  /// CPU核心数
  final int cpuCores;

  DeviceCapabilities({
    required this.kvmSupported,
    required this.jitSupported,
    required this.totalMemory,
    required this.cpuCores,
  });

  factory DeviceCapabilities.fromMap(Map<dynamic, dynamic> map) {
    return DeviceCapabilities(
      kvmSupported: map['kvmSupported'] ?? false,
      jitSupported: map['jitSupported'] ?? false,
      totalMemory: map['totalMemory'] ?? 0,
      cpuCores: map['cpuCores'] ?? 0,
    );
  }

  @override
  String toString() {
    return 'DeviceCapabilities(kvm: $kvmSupported, jit: $jitSupported, '
        'memory: ${totalMemory}MB, cores: $cpuCores)';
  }
}

/// QEMU异常类
class QemuException implements Exception {
  final String message;
  final String? code;

  QemuException(this.message, [this.code]);

  @override
  String toString() {
    if (code != null) {
      return 'QemuException[$code]: $message';
    }
    return 'QemuException: $message';
  }
}

