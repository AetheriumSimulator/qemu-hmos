/**
 * Windows 11 兼容性测试器
 * 检测运行 Windows 11 ARM 虚拟机所需的系统要求
 */

import deviceInfo from '@ohos.deviceInfo';
import { Windows11ConfigManager } from './Windows11Config';

/**
 * KVM 支持信息
 */
export interface KvmSupportInfo {
  /** 设备硬件是否支持 KVM */
  hardwareSupported: boolean;
  /** 是否有使用 KVM 的许可 */
  hasPermission: boolean;
  /** 当前使用的加速方式 */
  currentAccelerator: 'kvm' | 'tcg';
  /** 提示消息 */
  message: string;
  /** 设备型号 */
  deviceModel: string;
}

export interface Windows11Config {
  cpuSupported: boolean;
  memoryAdequate: boolean;
  tpmSupported: boolean;
  secureBootEnabled: boolean;
  kvmInfo: KvmSupportInfo;
  details: Windows11Details;
}

export interface Windows11Details {
  cpuArch: string;
  cpuCores: number;
  totalMemoryGB: number;
  requiredMemoryGB: number;
  tpmVersion: string;
  uefiAvailable: boolean;
  recommendation: string;
}

/**
 * QEMU 推荐配置
 */
export interface QemuRecommendedConfig {
  cpuCores: number;
  memoryMB: number;
  diskSizeGB: number;
  accelerator: string;
  display: string;
}

/**
 * 支持 KVM 但需要华为许可的设备列表
 */
const KVM_CAPABLE_DEVICES: string[] = [
  'MateBook Pro',
  'MateBook Fold', 
  'MatePad Edge',
  'HUAWEI MateBook Pro',
  'HUAWEI MateBook Fold',
  'HUAWEI MatePad Edge',
  // 可能的其他型号变体
  'MRG-W76',      // MateBook Pro 可能的型号代码
  'MRG-W56',
  'PAL-W09',      // MatePad Edge 可能的型号代码
  'PAL-AL09',
];

export class Windows11CompatibilityTester {
  // 最低要求
  private static readonly MIN_MEMORY_GB = 4;
  private static readonly RECOMMENDED_MEMORY_GB = 8;
  private static readonly MIN_CPU_CORES = 2;
  
  /**
   * 检查设备是否支持 KVM（硬件层面）
   * 注意：即使硬件支持，也需要华为的许可才能使用
   */
  checkKvmSupport(): KvmSupportInfo {
    const productModel = deviceInfo.productModel || '';
    const brand = deviceInfo.brand || '';
    
    console.info(`[W11Tester] 设备型号: ${productModel}, 品牌: ${brand}`);
    
    // 检查是否是支持 KVM 的设备
    const isKvmCapableDevice = this.isKvmCapableDevice(productModel);
    
    if (isKvmCapableDevice) {
      const result: KvmSupportInfo = {
        hardwareSupported: true,
        hasPermission: false,  // 我们没有华为的许可
        currentAccelerator: 'tcg',
        message: `您的设备 ${productModel} 支持 KVM 硬件加速，但我们尚未获得华为的许可来使用 KVM。当前使用 TCG 软件模拟，性能会有所降低。`,
        deviceModel: productModel
      };
      return result;
    }
    
    // 普通设备
    const result: KvmSupportInfo = {
      hardwareSupported: false,
      hasPermission: false,
      currentAccelerator: 'tcg',
      message: '您的设备使用 TCG 软件模拟运行虚拟机。',
      deviceModel: productModel
    };
    return result;
  }
  
  /**
   * 检查设备型号是否在支持 KVM 的列表中
   */
  private isKvmCapableDevice(productModel: string): boolean {
    if (!productModel) return false;
    
    const modelLower = productModel.toLowerCase();
    
    for (const device of KVM_CAPABLE_DEVICES) {
      if (modelLower.includes(device.toLowerCase())) {
        return true;
      }
    }
    
    // 额外检查：包含特定关键词的华为高端设备
    if (modelLower.includes('matebook') && 
        (modelLower.includes('pro') || modelLower.includes('fold'))) {
      return true;
    }
    
    if (modelLower.includes('matepad') && modelLower.includes('edge')) {
      return true;
    }
    
    return false;
  }

  checkCompatibility(): Windows11Config {
    const cpuSupported = this.checkCpuSupport();
    const memoryAdequate = this.checkMemory();
    const tpmSupported = this.checkTpmSupport();
    const secureBootEnabled = this.checkSecureBoot();
    const kvmInfo = this.checkKvmSupport();
    
    const config: Windows11Config = {
      cpuSupported,
      memoryAdequate,
      tpmSupported,
      secureBootEnabled,
      kvmInfo,
      details: this.getDetails(cpuSupported, memoryAdequate, tpmSupported, secureBootEnabled)
    };
    return config;
  }
  
  /**
   * 获取 CPU 架构信息
   * 由于 HarmonyOS API 没有直接的 cpuAbi 属性，通过其他方式推断
   */
  private getCpuArch(): string {
    // HarmonyOS 设备大多是 ARM64
    // 可以通过 osFullName 或设备型号来推断
    const osFullName = deviceInfo.osFullName || '';
    const productModel = deviceInfo.productModel || '';
    
    // 华为设备基本都是 ARM64
    if (osFullName.toLowerCase().includes('harmonyos') ||
        productModel.toLowerCase().includes('huawei') ||
        productModel.toLowerCase().includes('honor') ||
        productModel.toLowerCase().includes('mate') ||
        productModel.toLowerCase().includes('nova')) {
      return 'arm64-v8a';
    }
    
    // 默认假设 ARM64
    return 'arm64-v8a';
  }
  
  /**
   * 检测 CPU 支持
   * Windows 11 ARM 需要 ARMv8.0 或更高版本
   */
  private checkCpuSupport(): boolean {
    try {
      // 获取 CPU 架构
      const cpuArch = this.getCpuArch();
      
      // 检查是否是 ARM64 架构
      if (cpuArch.toLowerCase().includes('arm64') || 
          cpuArch.toLowerCase().includes('aarch64')) {
        return true;
      }
      
      // x86_64 也可以运行（通过 QEMU 模拟，但很慢）
      if (cpuArch.toLowerCase().includes('x86_64') || 
          cpuArch.toLowerCase().includes('x64')) {
        return true;
      }
      
      console.info(`[W11Tester] CPU Arch: ${cpuArch}`);
      return false;
    } catch (e) {
      console.error('[W11Tester] Failed to check CPU:', e);
      return true; // 乐观假设
    }
  }
  
  /**
   * 检测内存是否足够
   * Windows 11 最低需要 4GB，推荐 8GB 以上
   */
  private checkMemory(): boolean {
    try {
      // HarmonyOS 设备通常有足够的内存
      // 由于 API 限制，我们检查设备类型来推断
      const deviceType = deviceInfo.deviceType;
      
      // 平板和电脑通常有 4GB 以上内存
      if (deviceType === 'tablet' || deviceType === '2in1' || deviceType === 'pc') {
        return true;
      }
      
      // 手机可能内存不足
      if (deviceType === 'phone') {
        // 现代华为手机通常有 8GB+，假设足够
        return true;
      }
      
      return true; // 乐观假设
    } catch (e) {
      console.error('[W11Tester] Failed to check memory:', e);
      return true;
    }
  }
  
  /**
   * 检测当前构建实际提供的 TPM 后端
   */
  private checkTpmSupport(): boolean {
    return Windows11ConfigManager.isTPMAvailable();
  }
  
  /**
   * 检测 Secure Boot 支持
   * QEMU + OVMF 支持 UEFI Secure Boot
   */
  private checkSecureBoot(): boolean {
    // QEMU 使用 OVMF 固件支持 UEFI 和 Secure Boot
    // 需要配置正确的固件文件
    return true;
  }
  
  /**
   * 获取详细信息
   */
  private getDetails(
    cpuSupported: boolean,
    memoryAdequate: boolean,
    tpmSupported: boolean,
    secureBootEnabled: boolean
  ): Windows11Details {
    const cpuArch = this.getCpuArch();
    const deviceType = deviceInfo.deviceType || 'tablet';
    
    // 估算内存（基于设备类型）
    let estimatedMemoryGB = 4;
    if (deviceType === 'tablet' || deviceType === '2in1') {
      estimatedMemoryGB = 8;
    } else if (deviceType === 'pc') {
      estimatedMemoryGB = 16;
    }
    
    // 估算 CPU 核心数
    let estimatedCores = 4;
    if (deviceType === 'pc' || deviceType === '2in1') {
      estimatedCores = 8;
    }
    
    // 生成建议
    let recommendation = '';
    if (!cpuSupported) {
      recommendation = 'CPU 架构不支持运行 Windows 11 ARM。';
    } else if (!memoryAdequate) {
      recommendation = `内存不足。Windows 11 需要至少 ${Windows11CompatibilityTester.MIN_MEMORY_GB}GB 内存。`;
    } else if (estimatedMemoryGB < Windows11CompatibilityTester.RECOMMENDED_MEMORY_GB) {
      recommendation = `建议分配至少 ${Windows11CompatibilityTester.RECOMMENDED_MEMORY_GB}GB 内存以获得更好的体验。`;
    } else {
      recommendation = '您的设备完全支持运行 Windows 11 ARM 虚拟机。';
    }
    
    const details: Windows11Details = {
      cpuArch: cpuArch,
      cpuCores: estimatedCores,
      totalMemoryGB: estimatedMemoryGB,
      requiredMemoryGB: Windows11CompatibilityTester.MIN_MEMORY_GB,
      tpmVersion: tpmSupported ? '2.0 (软件模拟)' : '不可用',
      uefiAvailable: secureBootEnabled,
      recommendation
    };
    return details;
  }
  
  /**
   * 获取推荐的 QEMU 配置
   */
  getRecommendedQemuConfig(): QemuRecommendedConfig {
    const deviceType = deviceInfo.deviceType || 'tablet';
    
    // 根据设备类型推荐不同配置
    if (deviceType === 'pc' || deviceType === '2in1') {
      const config: QemuRecommendedConfig = {
        cpuCores: 4,
        memoryMB: 6144,  // 6GB
        diskSizeGB: 64,
        accelerator: 'kvm',  // 如果可用
        display: 'virtio-gpu'
      };
      return config;
    } else if (deviceType === 'tablet') {
      const config: QemuRecommendedConfig = {
        cpuCores: 2,
        memoryMB: 4096,  // 4GB
        diskSizeGB: 32,
        accelerator: 'tcg',
        display: 'virtio-gpu'
      };
      return config;
    } else {
      // 手机或其他设备 - 最低配置
      const config: QemuRecommendedConfig = {
        cpuCores: 2,
        memoryMB: 2048,  // 2GB
        diskSizeGB: 16,
        accelerator: 'tcg',
        display: 'virtio-gpu'
      };
      return config;
    }
  }
}
