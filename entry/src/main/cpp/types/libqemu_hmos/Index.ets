/**
 * QEMU HarmonyOS NAPI module loader.
 * Uses static import for native module loading.
 */

// 使用静态导入加载 native 模块 - HarmonyOS 推荐方式
// 注意：不能用 libentry.so，那是保留名称会被 hvigor 覆盖
// @ts-ignore - libqemu_hmos.so is a native module
import nativeQemu from 'libqemu_hmos.so';

let staticModule: object | undefined = nativeQemu;

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
  efiFirmware?: string;
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

export interface SupportedDevices {
  machines: { id: string; name: string; desc: string }[];
  displays: { id: string; name: string; desc: string }[];
  networks: { id: string; name: string; desc: string }[];
  audios: { id: string; name: string; desc: string }[];
}

export interface NativeVMConfig {
  name: string;
  arch_type: string;
  machine_type: string;
  cpu_type: string;
  memory_mb: number;
  cpu_count: number;
  disk_path: string;
  iso_path: string;
  efi_firmware: string;
  shared_dir: string;
  vnc_port: number;
  network_mode: string;
  accel_mode: string;
  display_mode: string;
}

export interface QemuModule {
  version(): string;
  enableJit(): boolean;
  kvmSupported(): boolean;
  startVm(config: VMConfig): boolean;
  stopVm(name: string): boolean;
  getVmLogs(name: string, startLine?: number): string[];
  getVmStatus?(name: string): string;
  getDeviceCapabilities?(): DeviceCapabilities;
  getSupportedDevices?(): SupportedDevices;
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
  vncAvailable?: () => boolean;
  vncCreate?: () => number;
  vncConnect?: (id: number, host: string, port: number) => boolean;
  vncDisconnect?: (id: number) => void;
  vncGetFrame?: (id: number) => {
    width: number;
    height: number;
    pixels: ArrayBuffer;
  } | null;
  getSupportedDevices?: () => SupportedDevices;
}

function createStub(): QemuModule {
  const warn = (method: string) => console.warn(`[qemu_hmos] ${method} ignored: native module missing`);
  return {
    version: () => '0.0.0-stub',
    enableJit: () => { warn('enableJit'); return false; },
    kvmSupported: () => false,
    startVm: () => { warn('startVm'); return false; },
    stopVm: () => { warn('stopVm'); return false; },
    getVmLogs: () => [],
    getVmStatus: () => 'stopped',
    getDeviceCapabilities: () => ({
      kvmSupported: false,
      jitSupported: false,
      totalMemory: 0,
      cpuCores: 0,
      machines: []
    }),
    getSupportedDevices: () => ({
      machines: [],
      displays: [],
      networks: [],
      audios: []
    }),
    pauseVm: () => { warn('pauseVm'); return false; },
    resumeVm: () => { warn('resumeVm'); return false; },
    createSnapshot: () => { warn('createSnapshot'); return false; },
    restoreSnapshot: () => { warn('restoreSnapshot'); return false; },
    listSnapshots: () => [],
    deleteSnapshot: () => { warn('deleteSnapshot'); return false; }
  };
}

function isValidModule(obj: unknown): obj is QemuModule {
  if (!obj || typeof obj !== 'object') return false;
  const m = obj as Record<string, unknown>;
  return typeof m.version === 'function' && typeof m.startVm === 'function';
}

function loadNativeModule(): QemuModule | null {
  if (staticModule && isValidModule(staticModule)) {
    console.info('[qemu_hmos] using statically loaded native module');
    return staticModule as QemuModule;
  }

  const globalAny = globalThis as Record<string, unknown>;
  const requireNapi = globalAny.requireNapi as ((name: string) => unknown) | undefined;

  if (typeof requireNapi === 'function') {
    // 尝试不同的模块名（不能用 entry，那是保留名称）
    const names = ['qemu_hmos', 'libqemu_hmos', 'libqemu_hmos.so'];
    const errors: string[] = [];
    for (const name of names) {
      try {
        console.info(`[qemu_hmos] trying requireNapi('${name}')...`);
        const mod = requireNapi(name);
        console.info(`[qemu_hmos] requireNapi('${name}') -> ${typeof mod}`);
        if (mod && typeof mod === 'object') {
          const keys = Object.keys(mod as object);
          if (keys.length > 0) {
            console.info(`[qemu_hmos] exports: ${keys.slice(0, 5).join(', ')}${keys.length > 5 ? '...' : ''}`);
          }
        }
        if (isValidModule(mod)) {
          console.info(`[qemu_hmos] requireNapi('${name}') succeeded`);
          return mod as QemuModule;
        }
        // If requireNapi returned falsy/undefined, record a hint to see whether it was a silent failure
        errors.push(`${name}: returned ${typeof mod}`);
      } catch (err) {
        const msg = err instanceof Error ? err.message : `${err}`;
        errors.push(`${name}: ${msg}`);
        console.warn(`[qemu_hmos] requireNapi('${name}') failed: ${msg}`);
      }
    }
    if (errors.length > 0) {
      console.error(`[qemu_hmos] requireNapi attempts failed: ${errors.join('; ')}`);
    }
  } else {
    console.error('[qemu_hmos] requireNapi unavailable');
  }

  for (const key of ['qemu_hmos', 'libqemu_hmos', 'nativeQemu']) {
    const candidate = globalAny[key];
    if (isValidModule(candidate)) {
      console.info(`[qemu_hmos] using globalThis.${key}`);
      return candidate as QemuModule;
    }
  }

  console.error('[qemu_hmos] all native load strategies failed');
  return null;
}

console.info('[qemu_hmos] starting native module load...');
const nativeModule = loadNativeModule();
const qemuModule: QemuModule = nativeModule ?? createStub();

if (nativeModule) {
  try {
    console.info(`[qemu_hmos] native module loaded, version: ${nativeModule.version()}`);
  } catch (e) {
    console.warn(`[qemu_hmos] version query failed: ${e}`);
  }
} else {
  console.warn('[qemu_hmos] using stub module');
}

export default qemuModule;
