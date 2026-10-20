// QEMU NAPI模块类型声明
declare module 'qemu_hmos' {
  interface QemuLastError {
    code: number;
    name: string;
    stage: string;
    message: string;
    vmName: string;
  }

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
    // Consent is bound to a running Native session; stale grants are rejected.
    getMicrophoneSession(vmName: string): number;
    setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean;
    getMicrophoneStatus(vmName: string): string;
    getVmStatus(vmName: string): string;
    getVmLogs(vmName: string, startLine?: number): string[];
    getLastError(): QemuLastError;
    
    // 核心库诊断
    checkCoreLib(): {
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

