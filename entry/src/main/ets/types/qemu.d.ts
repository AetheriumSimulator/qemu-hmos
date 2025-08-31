export interface VMConfig {
  name: string;
  isoPath?: string;
  diskSizeGB?: number;
  memoryMB?: number;
  cpuCount?: number;
  accel?: string;
  display?: string;
  nographic?: boolean;
}

export interface VMStatus {
  name: string;
  status: 'creating' | 'preparing' | 'running' | 'stopping' | 'stopped' | 'failed';
  createdAt: string;
  diskPath: string;
  logPath: string;
}

export interface QemuAPI {
  version(): string;
  enableJit(): boolean;
  kvmSupported(): boolean;
  startVm(config: VMConfig): boolean;
  stopVm(name: string): boolean;
  getVmLogs(name: string, startLine?: number): string[];
  getVmStatus(name: string): string;
}

// 模拟QEMU API实现，用于开发阶段
export const qemu: QemuAPI = {
  version(): string {
    return 'QEMU 8.0.0 (模拟版本)';
  },
  
  enableJit(): boolean {
    return true;
  },
  
  kvmSupported(): boolean {
    return false;
  },
  
  startVm(config: VMConfig): boolean {
    console.log('启动VM:', config);
    return true;
  },
  
  stopVm(name: string): boolean {
    console.log('停止VM:', name);
    return true;
  },
  
  getVmLogs(name: string, startLine: number = 0): string[] {
    return [`VM ${name} 的日志记录`];
  },
  
  getVmStatus(name: string): string {
    return 'stopped';
  }
};
