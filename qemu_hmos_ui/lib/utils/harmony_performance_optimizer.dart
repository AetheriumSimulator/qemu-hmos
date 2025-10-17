import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:math' as math;

/// 华为设备性能优化工具
/// 专门针对华为设备的性能问题进行优化
class HarmonyPerformanceOptimizer {
  static bool? _isHarmonyDevice;
  static bool? _isLowEndDevice;
  
  /// 检测是否为华为设备
  static bool get isHarmonyDevice {
    _isHarmonyDevice ??= _detectHarmonyDevice();
    return _isHarmonyDevice!;
  }
  
  /// 检测是否为低端设备
  static bool get isLowEndDevice {
    _isLowEndDevice ??= _detectLowEndDevice();
    return _isLowEndDevice!;
  }
  
  /// 检测华为设备
  static bool _detectHarmonyDevice() {
    try {
      // 检测华为设备特征
      if (Platform.isAndroid) {
        final String brand = Platform.environment['BRAND'] ?? '';
        final String manufacturer = Platform.environment['MANUFACTURER'] ?? '';
        final String model = Platform.environment['MODEL'] ?? '';
        
        // 华为设备品牌标识
        final bool isHuawei = brand.toLowerCase().contains('huawei') ||
                              manufacturer.toLowerCase().contains('huawei') ||
                              model.toLowerCase().contains('huawei') ||
                              model.toLowerCase().contains('honor');
        
        if (kDebugMode && isHuawei) {
          print('🔍 检测到华为设备: $brand $manufacturer $model');
        }
        
        return isHuawei;
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ 设备检测失败: $e');
      }
    }
    return false;
  }
  
  /// 检测低端设备
  static bool _detectLowEndDevice() {
    try {
      if (Platform.isAndroid) {
        // 简单的低端设备检测逻辑
        // 可以根据实际需求调整
        return false; // 暂时返回false，后续可以添加更复杂的检测
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ 低端设备检测失败: $e');
      }
    }
    return false;
  }
  
  /// 获取华为设备优化建议
  static Map<String, dynamic> getOptimizationSuggestions() {
    if (!isHarmonyDevice) {
      return {'enabled': false, 'reason': '非华为设备'};
    }
    
    return {
      'enabled': true,
      'device': '华为设备',
      'suggestions': [
        '减少阴影模糊半径（blurRadius < 16）',
        '简化动画效果（duration < 200ms）',
        '使用 RepaintBoundary 减少重绘',
        '避免频繁的 setState 调用',
        '使用 const 构造函数',
        '减少复杂的布局计算',
      ],
      'performance_level': isLowEndDevice ? '低端设备' : '中高端设备',
    };
  }
  
  /// 获取优化的阴影配置
  static List<BoxShadow> getOptimizedShadows({
    Color? color,
    double? blurRadius,
    Offset? offset,
    double? spreadRadius,
  }) {
    if (!isHarmonyDevice) {
      // 非华为设备使用原始配置
      return [
        BoxShadow(
          color: color ?? Colors.black.withOpacity(0.08),
          blurRadius: blurRadius ?? 24,
          offset: offset ?? const Offset(0, 8),
          spreadRadius: spreadRadius ?? 0,
        ),
        BoxShadow(
          color: color ?? Colors.black.withOpacity(0.04),
          blurRadius: blurRadius ?? 48,
          offset: offset ?? const Offset(0, 16),
          spreadRadius: spreadRadius ?? 0,
        ),
      ];
    }
    
    // 华为设备使用优化配置
    return [
      BoxShadow(
        color: color ?? Colors.black.withOpacity(0.06),
        blurRadius: (blurRadius ?? 24) * 0.5, // 减少模糊半径
        offset: offset ?? const Offset(0, 4),  // 减少偏移
        spreadRadius: spreadRadius ?? 0,
      ),
      if (!isLowEndDevice) // 低端设备只使用一个阴影
        BoxShadow(
          color: color ?? Colors.black.withOpacity(0.03),
          blurRadius: (blurRadius ?? 48) * 0.3, // 大幅减少模糊半径
          offset: offset ?? const Offset(0, 8),  // 减少偏移
          spreadRadius: spreadRadius ?? 0,
        ),
    ];
  }
  
  /// 获取优化的动画时长
  static Duration getOptimizedDuration(Duration originalDuration) {
    if (!isHarmonyDevice) {
      return originalDuration;
    }
    
    // 华为设备使用更短的动画时长
    final int milliseconds = (originalDuration.inMilliseconds * 0.7).round();
    return Duration(milliseconds: math.max(milliseconds, 150)); // 最少150ms
  }
  
  /// 获取优化的动画曲线
  static Curve getOptimizedCurve(Curve originalCurve) {
    if (!isHarmonyDevice) {
      return originalCurve;
    }
    
    // 华为设备使用更简单的动画曲线
    if (originalCurve == Curves.easeInOut) {
      return Curves.easeInOut;
    } else if (originalCurve == Curves.easeIn) {
      return Curves.easeIn;
    } else if (originalCurve == Curves.easeOut) {
      return Curves.easeOut;
    } else {
      return Curves.easeInOut; // 默认使用简单曲线
    }
  }
  
  /// 打印性能优化建议
  static void printOptimizationInfo() {
    if (!kDebugMode) return;
    
    final suggestions = getOptimizationSuggestions();
    if (suggestions['enabled'] == true) {
      print('🚀 华为设备性能优化已启用');
      print('📱 设备类型: ${suggestions['device']}');
      print('⚡ 性能等级: ${suggestions['performance_level']}');
      print('💡 优化建议:');
      for (String suggestion in suggestions['suggestions']) {
        print('   • $suggestion');
      }
    } else {
      print('ℹ️ 华为设备性能优化未启用: ${suggestions['reason']}');
    }
  }
}
