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
  // Consent is bound to a running Native session; stale grants are rejected.
  getMicrophoneSession(vmName: string): number;
  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean;
  getMicrophoneStatus(vmName: string): string;
  getVmLogs(name: string, startLine?: number): string[];
  getVmStatus(name: string): string;
  getLastError?: () => QemuLastError;
  // Diagnostics and testing (optional)
  testFunction?: () => boolean;
  checkCoreLib?: () => CoreDiag;
  // Native VNC (LibVNCClient) - optional methods
  vncAvailable?: () => boolean;
  vncCreate?: () => number;
  vncConnect?: (id: number, host: string, port: number) => boolean;
  vncDisconnect?: (id: number) => void;
  vncGetFrame?: (id: number) => VncFrame | null;
  vncSendPointer?: (id: number, x: number, y: number, buttonMask: number) => boolean;
  vncSendKey?: (id: number, keysym: number, down: boolean) => boolean;
}

export interface QemuLastError {
  code: number;
  name: string;
  stage: string;
  message: string;
  vmName: string;
}

// VNC frame shape for native client
export interface VncFrame {
  width: number;
  height: number;
  pixels: ArrayBuffer;
  // optional: frame sequence id (incremented when there is a new frame)
  seq?: number;
}

// Module declaration for N-API native addon
declare module 'qemu_hmos' {
  const qemu: QemuAPI;
  export default qemu;
}

// Diagnostics result for core library probing
export interface CoreDiag {
  loaded: boolean;
  foundLd: boolean;
  symFound?: boolean;
  selfDir: string;
  foundSelfDir: boolean;
  existsFilesPath: boolean;
  filesPath: string;
  foundFiles: boolean;
  errLd?: string;
  symErr?: string;
  errSelfDir?: string;
  errFiles?: string;
}
