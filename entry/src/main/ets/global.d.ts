// 全局类型声明文件
declare module 'qemu_hmos' {
  interface QemuModule {
    // 基础功能
    version(): string;
    enableJit(): boolean;
    kvmSupported(): boolean;
    
    // VM管理
    startVm(config: {
      name: string;
      isoPath?: string;
      diskSizeGB?: number;
      memoryMB?: number;
      cpuCount?: number;
      accel?: string;
      display?: string;
      nographic?: boolean;
    }): boolean;
    
    stopVm(vmName: string): boolean;
    getVmStatus(vmName: string): string;
    getVmLogs(vmName: string, startLine?: number): string[];
    getDeviceCapabilities?(): {
      kvmSupported: boolean;
      jitSupported: boolean;
      totalMemory: number;
      cpuCores: number;
    };
    pauseVm?(vmName: string): boolean;
    resumeVm?(vmName: string): boolean;
    createSnapshot?(vmName: string, snapshotName: string): boolean;
    restoreSnapshot?(vmName: string, snapshotName: string): boolean;
    listSnapshots?(vmName: string): string[];
    deleteSnapshot?(vmName: string, snapshotName: string): boolean;
    
    // 核心库诊断
    checkCoreLib?(): {
      loaded: boolean;
      foundLd: boolean;
      foundSelfDir: boolean;
      selfDir: string;
      existsFilesPath: boolean;
      filesPath: string;
      foundFiles: boolean;
      errLd?: string;
      errSelfDir?: string;
      errFiles?: string;
      symFound?: boolean;
      symErr?: string;
    };
  }
  
  const qemu: QemuModule;
  export default qemu;
}

declare module '@ohos.arkui.advanced' {
  export class CustomDialogController {
    constructor();
    open(): void;
    close(): void;
  }
}

