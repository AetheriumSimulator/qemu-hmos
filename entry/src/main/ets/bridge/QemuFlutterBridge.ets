import { logI, logE } from '../utils/Hilog'
import qemu from 'libqemu_hmos.so'

export interface BridgeErrorResult {
  error: string
}

export interface DeviceCapabilities {
  kvmSupported: boolean
  jitSupported: boolean
  totalMemory: number
  cpuCores: number
}

export type BridgeResult =
  | string
  | boolean
  | string[]
  | DeviceCapabilities
  | BridgeErrorResult

interface StartVmParams {
  name: string
  isoPath?: string
  diskSizeGB?: number
  memoryMB?: number
  cpuCount?: number
  accel?: string
  display?: string
  nographic?: boolean
}

interface RawBridgePayload {
  name?: string
  isoPath?: string
  diskSizeGB?: number
  memoryMB?: number
  cpuCount?: number
  accel?: string
  display?: string
  nographic?: boolean
  startLine?: number
}

export class BridgePayload {
  name?: string
  isoPath?: string
  diskSizeGB?: number
  memoryMB?: number
  cpuCount?: number
  accel?: string
  display?: string
  nographic?: boolean
  startLine?: number

  static from(source: unknown): BridgePayload {
    const payload = new BridgePayload()
    if (source && typeof source === 'object') {
      const raw = source as RawBridgePayload

      if (typeof raw.name === 'string' && raw.name.length > 0) payload.name = raw.name
      if (typeof raw.isoPath === 'string' && raw.isoPath.length > 0) payload.isoPath = raw.isoPath
      if (typeof raw.diskSizeGB === 'number') payload.diskSizeGB = Math.floor(raw.diskSizeGB)
      if (typeof raw.memoryMB === 'number') payload.memoryMB = Math.floor(raw.memoryMB)
      if (typeof raw.cpuCount === 'number') payload.cpuCount = Math.floor(raw.cpuCount)
      if (typeof raw.accel === 'string' && raw.accel.length > 0) payload.accel = raw.accel
      if (typeof raw.display === 'string' && raw.display.length > 0) payload.display = raw.display
      if (typeof raw.nographic === 'boolean') payload.nographic = raw.nographic
      if (typeof raw.startLine === 'number') payload.startLine = Math.floor(raw.startLine)
    }
    return payload
  }

  hasData(): boolean {
    return this.name !== undefined ||
      this.isoPath !== undefined ||
      this.diskSizeGB !== undefined ||
      this.memoryMB !== undefined ||
      this.cpuCount !== undefined ||
      this.accel !== undefined ||
      this.display !== undefined ||
      this.nographic !== undefined ||
      this.startLine !== undefined
  }
}

export class QemuFlutterBridge {
  static async handle(method: string, args: BridgePayload): Promise<BridgeResult> {
    const startTime = Date.now()
    try {
      logI(`[Bridge] call: ${method}, args: ${JSON.stringify(args)}`)
      
      let result: BridgeResult
      
      switch (method) {
        case 'version':
          result = qemu.version()
          break

        case 'startVm': {
          const vmConfig = QemuFlutterBridge.parseStartVmArgs(args)
          logI(`[Bridge] startVm config: ${JSON.stringify(vmConfig)}`)
          result = qemu.startVm(vmConfig)
          break
        }

        case 'stopVm': {
          const vmName = QemuFlutterBridge.readVmName(args)
          logI(`[Bridge] stopVm: ${vmName}`)
          result = qemu.stopVm(vmName)
          break
        }

        case 'getVmLogs':
          result = qemu.getVmLogs(
            QemuFlutterBridge.readVmName(args),
            QemuFlutterBridge.readStartLine(args)
          )
          break

        case 'getDeviceCapabilities':
          result = qemu.getDeviceCapabilities() as DeviceCapabilities
          break

        default:
          logE(`[Bridge] unknown method: ${method}`)
          return QemuFlutterBridge.errorResult(`unknown method: ${method}`)
      }
      
      const elapsed = Date.now() - startTime
      logI(`[Bridge] ${method} completed in ${elapsed}ms`)
      return result
      
    } catch (err) {
      const elapsed = Date.now() - startTime
      const message = err instanceof Error ? err.message : `${err}`
      logE(`[Bridge] error in ${method} after ${elapsed}ms: ${message}`)
      return QemuFlutterBridge.errorResult(message)
    }
  }

  private static parseStartVmArgs(args: BridgePayload): StartVmParams {
    const config: StartVmParams = {
      name: QemuFlutterBridge.readVmName(args)
    }

    if (args.isoPath) config.isoPath = args.isoPath
    
    // 校验并设置内存大小（最小256MB，最大8192MB）
    if (args.diskSizeGB !== undefined) {
      config.diskSizeGB = Math.max(1, Math.min(256, args.diskSizeGB))
    }
    
    // 校验并设置内存大小（最小512MB，最大8192MB）
    if (args.memoryMB !== undefined) {
      config.memoryMB = Math.max(512, Math.min(8192, args.memoryMB))
    }
    
    // 校验并设置CPU核心数（最小1核，最大8核）
    if (args.cpuCount !== undefined) {
      config.cpuCount = Math.max(1, Math.min(8, args.cpuCount))
    }
    
    if (args.accel) config.accel = args.accel
    if (args.display) config.display = args.display
    if (typeof args.nographic === 'boolean') config.nographic = args.nographic

    return config
  }

  private static readVmName(args: BridgePayload): string {
    if (args.name && args.name.length > 0) {
      return args.name
    }
    return 'vm'
  }

  private static readStartLine(args: BridgePayload): number {
    if (typeof args.startLine === 'number') {
      return args.startLine
    }
    return 0
  }

  private static errorResult(message: string): BridgeErrorResult {
    return { error: message }
  }
}

export default QemuFlutterBridge
