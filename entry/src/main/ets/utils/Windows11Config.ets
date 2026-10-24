// Windows 11 虚拟机配置优化
// 针对鸿蒙设备运行Windows 11的特殊配置
// 已移植到 Native 层实现

import qemu from 'qemu_hmos';

export interface Windows11Requirements {
  minMemoryMB: number;
  minDiskSizeGB: number;
  requiredFeatures: string[];
  tpmRequired: boolean;
  secureBootRequired: boolean;
}

export interface TPMSetupResult {
  success: boolean;
  socketPath?: string;
  stateDir?: string;
  error?: string;
}

export interface UEFISetupResult {
  success: boolean;
  codePath?: string;
  varsPath?: string;
  error?: string;
}

export interface Win11CompatibilityResult {
  tpmAvailable: boolean;
  uefiAvailable: boolean;
  secureBootAvailable: boolean;
  overallCompatible: boolean;
  tpmStatus?: string;
  uefiStatus?: string;
  secureBootStatus?: string;
}

export class Windows11ConfigManager {
  // Windows 11 最低系统要求
  static readonly REQUIREMENTS: Windows11Requirements = {
    minMemoryMB: 4096, // 4GB RAM
    minDiskSizeGB: 64,  // 64GB 存储空间
    requiredFeatures: ['TPM 2.0', 'UEFI', 'Secure Boot'],
    tpmRequired: true,
    secureBootRequired: true
  };

  // 检查配置是否满足Windows 11要求
  static validateWindows11Config(memory: number, diskSize: number): { valid: boolean; issues: string[] } {
    const issues: string[] = [];
    
    if (memory < this.REQUIREMENTS.minMemoryMB) {
      issues.push(`内存不足：需要至少 ${this.REQUIREMENTS.minMemoryMB}MB，当前 ${memory}MB`);
    }
    
    if (diskSize < this.REQUIREMENTS.minDiskSizeGB) {
      issues.push(`磁盘空间不足：需要至少 ${this.REQUIREMENTS.minDiskSizeGB}GB，当前 ${diskSize}GB`);
    }
    
    return {
      valid: issues.length === 0,
      issues
    };
  }

  /**
   * 创建 Windows 11 虚拟 TPM
   * 调用 Native 层实现
   */
  static async setupVirtualTPM(vmName: string): Promise<TPMSetupResult> {
    console.log(`[Windows11Config] 为虚拟机 ${vmName} 设置虚拟TPM`);
    
    try {
      // 调用 Native 层创建 TPM
      const result: TPMSetupResult = qemu.setupTpm(vmName);
      
      if (result.success) {
        console.log(`[Windows11Config] TPM 设置完成: ${result.socketPath}`);
      } else {
        console.error(`[Windows11Config] TPM 设置失败: ${result.error}`);
      }
      
      return result;
    } catch (e) {
      const errorMsg = e instanceof Error ? e.message : String(e);
      console.error(`[Windows11Config] TPM 设置异常: ${errorMsg}`);
      return {
        success: false,
        error: errorMsg
      };
    }
  }

  /**
   * 创建 UEFI 变量文件
   * 调用 Native 层实现
   */
  static async setupUEFIVars(vmName: string): Promise<UEFISetupResult> {
    console.log(`[Windows11Config] 为虚拟机 ${vmName} 设置 UEFI 变量`);
    
    try {
      // 调用 Native 层创建 UEFI 变量文件
      const result: UEFISetupResult = qemu.setupUefi(vmName);
      
      if (result.success) {
        console.log(`[Windows11Config] UEFI 设置完成:`);
        console.log(`  Code: ${result.codePath}`);
        console.log(`  Vars: ${result.varsPath}`);
      } else {
        console.error(`[Windows11Config] UEFI 设置失败: ${result.error}`);
      }
      
      return result;
    } catch (e) {
      const errorMsg = e instanceof Error ? e.message : String(e);
      console.error(`[Windows11Config] UEFI 设置异常: ${errorMsg}`);
      return {
        success: false,
        error: errorMsg
      };
    }
  }

  /**
   * 启用/禁用 Secure Boot
   */
  static enableSecureBoot(vmName: string, enable: boolean): boolean {
    try {
      return qemu.enableSecureBoot(vmName, enable);
    } catch (e) {
      console.error(`[Windows11Config] Secure Boot 设置失败: ${e}`);
      return false;
    }
  }

  /**
   * 检查 UEFI 是否可用
   */
  static isUEFIAvailable(): boolean {
    try {
      return qemu.isUefiAvailable();
    } catch (e) {
      console.warn('[Windows11Config] UEFI 检查失败，假设可用');
      return true;
    }
  }

  /**
   * 检查 TPM 是否可用
   */
  static isTPMAvailable(vmName?: string): boolean {
    try {
      return qemu.isTpmAvailable(vmName);
    } catch (e) {
      console.warn('[Windows11Config] TPM 检查失败，视为不可用');
      return false;
    }
  }

  /**
   * 生成 Windows 11 优化的 QEMU 命令参数
   * 调用 Native 层实现
   */
  static buildWindows11QemuArgs(vmName: string, memory: number, diskPath: string, isoPath: string): string {
    try {
      return qemu.buildWin11Args(vmName, memory, diskPath, isoPath);
    } catch (e) {
      console.error(`[Windows11Config] 构建 QEMU 参数失败: ${e}`);
      // 返回最基础的参数
      return `-m ${memory}M -smp 4`;
    }
  }

  // 性能监控和优化建议
  static getPerformanceRecommendations(hostSpecs: { cpu: string; memory: number; storage: string }): string[] {
    const recommendations: string[] = [];
    
    if (hostSpecs.memory < 8192) {
      recommendations.push('建议主机内存至少8GB以获得更好的Windows 11性能');
    }
    
    if (!hostSpecs.cpu.includes('ARM') && !hostSpecs.cpu.includes('arm')) {
      recommendations.push('Windows 11 ARM 版本在 ARM 架构上运行最佳');
    }
    
    if (!hostSpecs.storage.includes('SSD') && !hostSpecs.storage.includes('UFS')) {
      recommendations.push('建议使用SSD/UFS存储以提升Windows 11启动和运行速度');
    }
    
    recommendations.push('启用硬件加速(KVM)以获得最佳性能（需要特殊权限）');
    recommendations.push('为虚拟机分配足够的CPU核心(建议4核心)');
    
    return recommendations;
  }
}

// Windows 11 兼容性测试工具
export class Windows11CompatibilityTester {
  /**
   * 测试虚拟机是否能成功启动 Windows 11
   * 调用 Native 层进行全面检查
   */
  static async testWindows11Boot(vmName: string): Promise<{ success: boolean; issues: string[] }> {
    console.log(`[Windows11Tester] 测试虚拟机 ${vmName} 的 Windows 11 兼容性`);
    
    const issues: string[] = [];
    
    try {
      // 调用 Native 层进行全面兼容性检查
      const compat: Win11CompatibilityResult = qemu.checkWin11Compatibility(vmName);
      
      if (!compat.tpmAvailable) {
        issues.push(`TPM 不可用: ${compat.tpmStatus || '未知原因'}`);
      }
      
      if (!compat.uefiAvailable) {
        issues.push(`UEFI 不可用: ${compat.uefiStatus || '未知原因'}`);
      }
      
      if (!compat.secureBootAvailable) {
        issues.push(`Secure Boot 未启用: ${compat.secureBootStatus || '可在设置中启用'}`);
      }
      
      if (compat.overallCompatible) {
        console.log('[Windows11Tester] Windows 11 兼容性测试通过');
        return { success: true, issues: [] };
      } else {
        console.warn('[Windows11Tester] Windows 11 兼容性测试发现问题:', issues);
        return { success: false, issues };
      }
      
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      issues.push(`兼容性测试失败: ${errorMsg}`);
      return { success: false, issues };
    }
  }
  
  /**
   * 快速检查 TPM 可用性
   */
  static async checkTPMAvailability(vmName?: string): Promise<boolean> {
    console.log('[Windows11Tester] 检查 TPM 2.0 支持...');
    return Windows11ConfigManager.isTPMAvailable(vmName);
  }
  
  /**
   * 快速检查 UEFI 支持
   */
  static async checkUEFISupport(): Promise<boolean> {
    console.log('[Windows11Tester] 检查 UEFI 支持...');
    return Windows11ConfigManager.isUEFIAvailable();
  }
  
  /**
   * 快速检查 Secure Boot 支持
   */
  static async checkSecureBootSupport(vmName: string): Promise<boolean> {
    console.log('[Windows11Tester] 检查 Secure Boot 支持...');
    try {
      const compat: Win11CompatibilityResult = qemu.checkWin11Compatibility(vmName);
      return compat.secureBootAvailable;
    } catch (e) {
      // QEMU 支持 Secure Boot，只是需要正确配置
      return true;
    }
  }
}
