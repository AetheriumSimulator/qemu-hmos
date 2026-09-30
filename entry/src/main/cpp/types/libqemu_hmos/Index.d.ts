export interface VMConfig {
  name: string;
  archType?: 'aarch64' | 'x86_64' | 'i386';
  isoPath?: string;
  diskSizeGB?: number;
  memoryMB?: number;
  cpuCount?: number;
  accel?: string;
  display?: string;
  nographic?: boolean;
  efiFirmware?: string;  // UEFI 固件路径
}

export interface VMStatus {
  name: string;
  status: 'creating' | 'preparing' | 'running' | 'stopping' | 'stopped' | 'failed';
  createdAt: string;
  diskPath: string;
  logPath: string;
}

export interface DeviceCapabilities {
  kvmSupported: boolean;
  jitSupported: boolean;
  totalMemory: number;
  cpuCores: number;
  machines?: {
    id: string;
    name: string;
    desc: string;
  }[];
}

export interface DeviceOption {
  id: string;
  name: string;
  desc: string;
}

export interface SupportedDevices {
  machines: DeviceOption[];
  displays: DeviceOption[];
  networks: DeviceOption[];
  audios: DeviceOption[];
  note?: string;           // 说明信息
}

export interface ProbeResult {
  success: boolean;
  error?: string;
  qmpResponse?: string;    // QMP 原始响应（JSON 格式）
  qmpSocket?: string;      // QMP socket 路径
}

// 设备扫描结果
export interface ScanResult {
  success: boolean;
  cached?: boolean;        // 是否来自缓存
  rawJson?: string;        // QMP 返回的原始 JSON（包含所有设备类型）
  error?: string;
}

export interface QemuModule {
  version(): string;
  enableJit(): boolean;
  kvmSupported(): boolean;
  startVm(config: VMConfig): boolean;
  stopVm(name: string): boolean;
  getVmLogs(name: string, startLine?: number): string[];
  getVmStatus(name: string): string;
  getDeviceCapabilities?(): DeviceCapabilities;
  getSupportedDevices?(): SupportedDevices;
  scanQemuDevices?(): ScanResult;           // 同步版本（返回缓存或提示）
  scanQemuDevicesAsync?(): Promise<ScanResult>;  // 异步扫描（返回 Promise，不阻塞主线程）
  clearDeviceCache?(): boolean;              // 清除设备缓存，强制重新扫描
  probeQemuDevices?(vmName: string): ProbeResult;  // 从运行中的 VM 探测设备
  pauseVm?(name: string): boolean;
  resumeVm?(name: string): boolean;
  createSnapshot?(name: string, snapshotName: string): boolean;
  restoreSnapshot?(name: string, snapshotName: string): boolean;
  listSnapshots?(name: string): string[];
  deleteSnapshot?(name: string, snapshotName: string): boolean;
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
  vncAvailable?(): boolean;
  vncCreate?(): number;
  vncConnect?(id: number, host: string, port: number): boolean;
  vncDisconnect?(id: number): void;
  vncGetFrame?(id: number): {
    width: number;
    height: number;
    pixels: ArrayBuffer;
  } | null;
}

// 声明 native 模块
declare module 'libentry.so' {
  const qemuModule: QemuModule;
  export default qemuModule;
}

declare module 'libqemu_hmos.so' {
  const qemuModule: QemuModule;
  export default qemuModule;
}

declare const qemuModule: QemuModule;
export default qemuModule;
