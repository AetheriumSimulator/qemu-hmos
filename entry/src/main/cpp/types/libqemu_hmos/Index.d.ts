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

export const version: () => string;
export const enableJit: () => boolean;
export const kvmSupported: () => boolean;
export const startVm: (config: VMConfig) => boolean;
export const stopVm: (name: string) => boolean;
export const getVmLogs: (name: string, startLine?: number) => string[];
export const getVmStatus: (name: string) => string;

declare const _default: {
  version: typeof version;
  enableJit: typeof enableJit;
  kvmSupported: typeof kvmSupported;
  startVm: typeof startVm;
  stopVm: typeof stopVm;
  getVmLogs: typeof getVmLogs;
  getVmStatus: typeof getVmStatus;
};
export default _default;
