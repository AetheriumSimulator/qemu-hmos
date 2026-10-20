/**
 * QEMU 虚拟机管理器
 * 使用 Worker 线程管理 QEMU 虚拟机，通过 NAPI 调用 Native 层
 */

import worker from '@ohos.worker'
import deviceInfo from '@ohos.deviceInfo'
import { MicrophoneManager } from './MicrophoneManager'
interface NativeVmConfig {
  name: string
  archType: 'aarch64' | 'x86_64' | 'i386'
  isoPath: string
  diskPath: string
  diskSizeGB: number
  memoryMB: number
  cpuCount: number
  accel: string
  display: string
  nographic: boolean
  efiFirmware: string
  sharedDir: string
  qemuDataDir?: string
  keymapsAvailable?: boolean
  // 高级硬件配置（可选）
  machine?: string
  displayDevice?: string
  networkDevice?: string
  audioDevice?: string
}

// 导入模块类型
interface QemuModuleImport {
  default: NativeQemuModule
}

interface NativeQemuModule {
  setDeviceInfo?: (deviceType: number, model: string) => void
  kvmSupported?: () => boolean
  startVm: (config: NativeVmConfig) => boolean
  stopVm?: (name: string) => boolean
  getVmStatus?: (name: string) => string
  getLastError?: () => QemuLastError
  writeToVmConsole?: (data: string) => void
  setConsoleCallback?: (callback: (data: string) => void) => void
  // 通过 QMP screendump 获取 VM 截图
  takeScreenshot?: (vmName: string, outputPath: string) => boolean
}

interface QemuLastError {
  code: number
  name: string
  stage: string
  message: string
  vmName: string
}

let nativeQemu: NativeQemuModule | null = null
let nativeInitPromise: Promise<NativeQemuModule> | null = null

interface QemuWorkerMessage {
  command: 'start_vm' | 'stop_vm' | 'pause_vm' | 'resume_vm' | 'get_status' |
           'create_snapshot' | 'restore_snapshot' | 'list_snapshots' | 'delete_snapshot' |
           'forward_port' | 'setup_network' | 'mount_shared_dir' |
           'get_kvm_info' | 'set_device_info'
  vmConfig?: VMConfig
  vmId?: string
  vmName?: string
  snapshotName?: string
  hostPort?: number
  guestPort?: number
  hostPath?: string
  guestPath?: string
  deviceType?: number
  deviceModel?: string
  isReleaseBuild?: boolean
}

interface WorkerResponseData {
  vncPort?: number
  rdpPort?: number
  sshPort?: number
  snapshots?: string[]
  mountCommand?: string
}

interface QemuWorkerResponse {
  success: boolean
  message: string
  vmId?: string
  status?: string
  data?: WorkerResponseData
}

export interface VMConfig {
  name: string
  os?: string
  arch?: 'aarch64' | 'x86_64' | 'i386'
  archType?: 'aarch64' | 'x86_64' | 'i386'
  isoPath?: string
  diskPath?: string
  diskSizeGB?: number
  memory?: number
  memoryMB?: number
  cpuCores?: number
  cpuCount?: number
  accelMode?: string
  displayMode?: string
  nographic?: boolean
  efiFirmware?: string
  sharedDir?: string
  qemuDataDir?: string  // QEMU数据目录（包含keymaps，由KeymapsManager提供）
  vncPort?: number
  rdpPort?: number
  networkMode?: string
  // 高级硬件配置（从创建向导传入）
  machine?: string
  displayDevice?: string
  networkDevice?: string
  audioDevice?: string
  keymapsAvailable?: boolean  // ArkTS 已确认 keymaps 存在
}

export interface KVMInfo {
  kvmSupported: boolean
  isPcDevice: boolean
  kvmUnavailableReason: string | null
  hasJitPermission: boolean
  jitPermissionInfo: string
  recommendedAccel: 'kvm' | 'tcg'
}

export interface VMStartResult {
  success: boolean
  vmId?: string
  message: string
  errorCode?: number
  errorName?: string
  errorStage?: string
  vncPort?: number
  rdpPort?: number
  sshPort?: number
}

interface PromiseResolver {
  resolve: (value: QemuWorkerResponse) => void
  reject: (reason: Error) => void
}

interface StopVMResult {
  success: boolean
  message: string
}

interface PauseVMResult {
  success: boolean
  message: string
}

interface ResumeVMResult {
  success: boolean
  message: string
}

interface VMStatusResult {
  success: boolean
  status?: string
  data?: WorkerResponseData
  message: string
}

interface SnapshotResult {
  success: boolean
  message: string
}

interface ListSnapshotsResult {
  success: boolean
  snapshots: string[]
  message: string
}

interface ForwardPortResult {
  success: boolean
  message: string
}

interface SetupNetworkResult {
  success: boolean
  message: string
}

interface MountSharedDirResult {
  success: boolean
  message: string
  mountCommand?: string
}

export class QemuVMManager {
  private static instance: QemuVMManager
  private worker: worker.ThreadWorker | null = null
  private workerAvailable: boolean = false  // Worker 是否可用
  private vmStatusCallbacks: Map<string, (status: string) => void> = new Map()
  private pendingPromises: Map<string, PromiseResolver> = new Map()
  private messageId: number = 0
  private isReleaseBuild: boolean = false
  
  static getInstance(): QemuVMManager {
    if (!QemuVMManager.instance) {
      QemuVMManager.instance = new QemuVMManager()
    }
    return QemuVMManager.instance
  }
  
  private constructor() {
    this.initWorker()
    this.initDeviceInfo()
  }
  
  /**
   * 设置是否是正式版本（影响 KVM 提示信息）
   */
  setReleaseBuild(isRelease: boolean) {
    this.isReleaseBuild = isRelease
  }
  
  private initWorker() {
    // 暂时禁用 Worker，直接使用 NAPI 调用
    // Worker 需要正确配置后才能启用
    console.info('[QemuVMManager] Worker 暂时禁用，使用直接 NAPI 调用')
    this.workerAvailable = false
    this.worker = null
    
    // TODO: 未来启用 Worker 时取消注释以下代码
    /*
    try {
      // 创建 Worker 线程
      this.worker = new worker.ThreadWorker('entry/ets/workers/qemu_worker.ets')
      
      // 监听 Worker 消息
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        this.handleWorkerResponse(response)
      }
      
      // Worker 错误处理
      this.worker.onerror = (error) => {
        console.error('[QemuVMManager] Worker 错误:', error)
        this.workerAvailable = false
      }
      
      this.workerAvailable = true
      console.info('[QemuVMManager] Worker 初始化成功')
    } catch (error) {
      console.error('[QemuVMManager] Worker 初始化失败，回退到直接 NAPI 调用:', error)
      this.workerAvailable = false
      this.worker = null
    }
    */
  }

  /**
   * 初始化设备信息并传递给 Native 层
   */
  private async initDeviceInfo() {
    try {
      // 获取设备类型
      const deviceType = this.getDeviceTypeCode(deviceInfo.deviceType)
      const model = deviceInfo.productModel || ''
      
      console.info(`[QemuVMManager] 设备信息: type=${deviceInfo.deviceType}, model=${model}`)
      
      // Worker 不可用时直接走 NAPI
      if (!this.workerAvailable) {
        const native = await this.ensureNative()
        try {
          native.setDeviceInfo?.(deviceType, model)
        } catch (err) {
          console.error('[QemuVMManager] 直接设置设备信息失败:', err)
        }
        return
      }

      // 发送到 Worker
      await this.sendCommand({
        command: 'set_device_info',
        deviceType: deviceType,
        deviceModel: model
      })
    } catch (error) {
      console.error('[QemuVMManager] 初始化设备信息失败:', error)
    }
  }

  /**
   * 确保加载 native 模块（Worker 不可用时的兜底）
   */
  private async ensureNative(): Promise<NativeQemuModule> {
    if (nativeQemu) {
      return nativeQemu
    }
    if (!nativeInitPromise) {
      nativeInitPromise = import('qemu_hmos').then((mod: QemuModuleImport): NativeQemuModule => {
        const resolved: NativeQemuModule = mod.default
        nativeQemu = resolved
        return resolved
      }).catch((err: Error): NativeQemuModule => {
        nativeInitPromise = null
        throw err
      })
    }
    return nativeInitPromise
  }
  
  /**
   * 转换设备类型为数字码
   */
  private getDeviceTypeCode(deviceType: string): number {
    const typeMap: Map<string, number> = new Map([
      ['phone', 1],
      ['tablet', 2],
      ['2in1', 3],
      ['pc', 4],
      ['tv', 5],
      ['wearable', 6]
    ])
    const code = typeMap.get(deviceType.toLowerCase())
    return code !== undefined ? code : 0
  }
  
  private handleWorkerResponse(response: QemuWorkerResponse) {
    console.info('[QemuVMManager] 收到 Worker 响应:', JSON.stringify(response))
    
    // 如果是状态更新，调用相应的回调
    if (response.vmId && response.status) {
      const callback = this.vmStatusCallbacks.get(response.vmId)
      if (callback) {
        callback(response.status)
      }
    }
  }
  
  /**
   * 发送命令到 Worker 或直接调用 NAPI
   */
  private sendCommand(message: QemuWorkerMessage): Promise<QemuWorkerResponse> {
    return new Promise((resolve, reject) => {
      // Worker 不可用时，返回失败响应（不崩溃）
      if (!this.workerAvailable || !this.worker) {
        console.warn('[QemuVMManager] Worker 不可用，命令被忽略:', message.command)
        // 返回失败响应而不是 reject，避免崩溃
        const response: QemuWorkerResponse = {
          success: false,
          message: 'Worker 不可用，请直接使用 NAPI 调用'
        }
        resolve(response)
        return
      }
      
      this.worker.postMessage(message)
      
      const originalHandler = this.worker.onmessage
      this.worker.onmessage = (event) => {
        const response = event.data as QemuWorkerResponse
        resolve(response)
        this.worker!.onmessage = originalHandler
      }
      
      // 超时处理
      setTimeout(() => {
        reject(new Error('命令超时'))
      }, 30000)
    })
  }
  
  // ============================================================
  // 虚拟机生命周期管理
  // ============================================================
  
  /**
   * 启动虚拟机
   */
  async startVM(vmConfig: VMConfig): Promise<VMStartResult> {
    try {
      // Worker 不可用时直接调用 NAPI
      if (!this.workerAvailable) {
        const native = await this.ensureNative()
        // 安全填充参数，避免传 0/空导致 native 崩溃
        const cpu = vmConfig.cpuCount ?? vmConfig.cpuCores ?? 2
        const mem = vmConfig.memoryMB ?? vmConfig.memory ?? 2048
        const disk = vmConfig.diskSizeGB ?? 32
        const accel = native.kvmSupported?.() ? 'kvm' : 'tcg'
        const display = vmConfig.displayMode ?? 'vnc=0.0.0.0:1,websocket=5701'

        try {
          const nativeConfig: NativeVmConfig = {
            name: vmConfig.name,
            archType: vmConfig.archType ?? vmConfig.arch ?? 'aarch64',
            isoPath: vmConfig.isoPath ?? '',
            diskPath: vmConfig.diskPath ?? '',
            diskSizeGB: disk > 0 ? disk : 32,
            memoryMB: mem > 0 ? mem : 2048,
            cpuCount: cpu > 0 ? cpu : 2,
            accel: vmConfig.accelMode ?? accel,
            display: display,
            nographic: vmConfig.nographic ?? false,
            efiFirmware: vmConfig.efiFirmware ?? '',
            sharedDir: vmConfig.sharedDir ?? '',
            qemuDataDir: vmConfig.qemuDataDir ?? '',  // 传递keymaps目录路径
            keymapsAvailable: vmConfig.keymapsAvailable ?? false,
            machine: vmConfig.machine,
            displayDevice: vmConfig.displayDevice,
            networkDevice: vmConfig.networkDevice,
            audioDevice: vmConfig.audioDevice
          }
          const success: boolean = native.startVm(nativeConfig)

          if (!success) {
            const diagnostic = native.getLastError?.()
            return {
              success: false,
              message: diagnostic
                ? `${diagnostic.name}(${diagnostic.code}) [${diagnostic.stage}]: ${diagnostic.message}`
                : 'NAPI startVm 返回 false',
              errorCode: diagnostic?.code,
              errorName: diagnostic?.name,
              errorStage: diagnostic?.stage
            }
          }

          return {
            success: true,
            vmId: vmConfig.name,
            message: '已通过 NAPI 直接启动',
            vncPort: 5901,
            rdpPort: 3390,
            sshPort: 2222
          }
        } catch (err) {
          const diagnostic = native.getLastError?.()
          return {
            success: false,
            message: diagnostic
              ? `${diagnostic.name}(${diagnostic.code}) [${diagnostic.stage}]: ${diagnostic.message}`
              : `直接 NAPI 启动失败: ${err}`,
            errorCode: diagnostic?.code,
            errorName: diagnostic?.name,
            errorStage: diagnostic?.stage
          }
        }
      }

      const response = await this.sendCommand({
        command: 'start_vm',
        vmConfig: vmConfig
      })
      
      if (response.success && response.vmId) {
        const result: VMStartResult = {
          success: true,
          vmId: response.vmId,
          message: response.message,
          vncPort: response.data?.vncPort,
          rdpPort: response.data?.rdpPort,
          sshPort: response.data?.sshPort
        }
        return result
      } else {
        const result: VMStartResult = {
          success: false,
          message: response.message
        }
        return result
      }
    } catch (error) {
      const result: VMStartResult = {
        success: false,
        message: `NATIVE_MODULE_MISSING(7) [module_load]: 启动失败: ${error}`,
        errorCode: 7,
        errorName: 'NATIVE_MODULE_MISSING',
        errorStage: 'module_load'
      }
      return result
    }
  }
  
  /**
   * 停止虚拟机
   */
  async stopVM(vmId: string): Promise<StopVMResult> {
    MicrophoneManager.getInstance().vmStopped(vmId)
    try {
      // Worker 不可用时直接调用 NAPI（否则 sendCommand 会把 stop_vm 忽略掉，表现为“点停止关不了机”）
      if (!this.workerAvailable) {
        const native = await this.ensureNative()
        try {
          const ok = native.stopVm ? Boolean(native.stopVm(vmId)) : false
          return { success: ok, message: ok ? '已通过 NAPI 关闭虚拟机' : 'NAPI stopVm 不可用或返回 false' }
        } catch (err) {
          return { success: false, message: `直接 NAPI 关闭失败: ${err}` }
        }
      }

      const response = await this.sendCommand({
        command: 'stop_vm',
        vmId: vmId
      })
      const result: StopVMResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: StopVMResult = { success: false, message: `停止失败: ${error}` }
      return result
    }
  }
  
  /**
   * 暂停虚拟机
   */
  async pauseVM(vmId: string): Promise<PauseVMResult> {
    try {
      const response = await this.sendCommand({
        command: 'pause_vm',
        vmId: vmId
      })
      const result: PauseVMResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: PauseVMResult = { success: false, message: `暂停失败: ${error}` }
      return result
    }
  }

  /**
   * 恢复虚拟机
   */
  async resumeVM(vmId: string): Promise<ResumeVMResult> {
    try {
      const response = await this.sendCommand({
        command: 'resume_vm',
        vmId: vmId
      })
      const result: ResumeVMResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: ResumeVMResult = { success: false, message: `恢复失败: ${error}` }
      return result
    }
  }

  /**
   * 获取虚拟机状态
   */
  async getVMStatus(vmId: string): Promise<VMStatusResult> {
    try {
      const response = await this.sendCommand({
        command: 'get_status',
        vmId: vmId
      })
      const result: VMStatusResult = {
        success: response.success,
        status: response.status,
        data: response.data,
        message: response.message
      }
      return result
    } catch (error) {
      const result: VMStatusResult = { success: false, message: `获取状态失败: ${error}` }
      return result
    }
  }
  
  // ============================================================
  // 快照管理
  // ============================================================
  
  /**
   * 创建快照
   */
  async createSnapshot(vmName: string, snapshotName: string): Promise<SnapshotResult> {
    try {
      const response = await this.sendCommand({
        command: 'create_snapshot',
        vmName: vmName,
        snapshotName: snapshotName
      })
      const result: SnapshotResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: SnapshotResult = { success: false, message: `创建快照失败: ${error}` }
      return result
    }
  }

  /**
   * 恢复快照
   */
  async restoreSnapshot(vmName: string, snapshotName: string): Promise<SnapshotResult> {
    try {
      const response = await this.sendCommand({
        command: 'restore_snapshot',
        vmName: vmName,
        snapshotName: snapshotName
      })
      const result: SnapshotResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: SnapshotResult = { success: false, message: `恢复快照失败: ${error}` }
      return result
    }
  }

  /**
   * 列出快照
   */
  async listSnapshots(vmName: string): Promise<ListSnapshotsResult> {
    try {
      const response = await this.sendCommand({
        command: 'list_snapshots',
        vmName: vmName
      })
      const snapshots = response.data?.snapshots || []
      const result: ListSnapshotsResult = {
        success: response.success,
        snapshots: snapshots,
        message: response.message
      }
      return result
    } catch (error) {
      const result: ListSnapshotsResult = { success: false, snapshots: [], message: `获取快照列表失败: ${error}` }
      return result
    }
  }

  /**
   * 删除快照
   */
  async deleteSnapshot(vmName: string, snapshotName: string): Promise<SnapshotResult> {
    try {
      const response = await this.sendCommand({
        command: 'delete_snapshot',
        vmName: vmName,
        snapshotName: snapshotName
      })
      const result: SnapshotResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: SnapshotResult = { success: false, message: `删除快照失败: ${error}` }
      return result
    }
  }
  
  // ============================================================
  // 网络管理
  // ============================================================
  
  /**
   * 端口转发
   */
  async forwardPort(vmName: string, hostPort: number, guestPort: number): Promise<ForwardPortResult> {
    try {
      const response = await this.sendCommand({
        command: 'forward_port',
        vmName: vmName,
        hostPort: hostPort,
        guestPort: guestPort
      })
      const result: ForwardPortResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: ForwardPortResult = { success: false, message: `端口转发失败: ${error}` }
      return result
    }
  }

  /**
   * 设置网络
   */
  async setupNetwork(vmName: string, mode: string = 'user'): Promise<SetupNetworkResult> {
    try {
      const partialConfig: Partial<VMConfig> = { networkMode: mode }
      const response = await this.sendCommand({
        command: 'setup_network',
        vmName: vmName,
        vmConfig: partialConfig as VMConfig
      })
      const result: SetupNetworkResult = { success: response.success, message: response.message }
      return result
    } catch (error) {
      const result: SetupNetworkResult = { success: false, message: `网络配置失败: ${error}` }
      return result
    }
  }

  // ============================================================
  // 文件共享
  // ============================================================

  /**
   * 挂载共享目录
   */
  async mountSharedDir(vmName: string, hostPath: string, guestPath?: string): Promise<MountSharedDirResult> {
    try {
      const response = await this.sendCommand({
        command: 'mount_shared_dir',
        vmName: vmName,
        hostPath: hostPath,
        guestPath: guestPath
      })
      const result: MountSharedDirResult = {
        success: response.success,
        message: response.message,
        mountCommand: response.data?.mountCommand
      }
      return result
    } catch (error) {
      const result: MountSharedDirResult = { success: false, message: `共享目录配置失败: ${error}` }
      return result
    }
  }
  
  // ============================================================
  // KVM / 加速模式信息
  // ============================================================
  
  /**
   * 获取 KVM 信息
   */
  async getKVMInfo(): Promise<KVMInfo> {
    try {
      const response = await this.sendCommand({
        command: 'get_kvm_info',
        isReleaseBuild: this.isReleaseBuild
      })
      
      if (response.success && response.data) {
        return response.data as KVMInfo
      }
      
      // 默认返回
      return {
        kvmSupported: false,
        isPcDevice: false,
        kvmUnavailableReason: '无法获取 KVM 信息',
        hasJitPermission: false,
        jitPermissionInfo: '',
        recommendedAccel: 'tcg'
      }
    } catch (error) {
      return {
        kvmSupported: false,
        isPcDevice: false,
        kvmUnavailableReason: `获取 KVM 信息失败: ${error}`,
        hasJitPermission: false,
        jitPermissionInfo: '',
        recommendedAccel: 'tcg'
      }
    }
  }
  
  // ============================================================
  // 状态回调管理
  // ============================================================
  
  /**
   * 注册虚拟机状态变化回调
   */
  onVMStatusChange(vmId: string, callback: (status: string) => void) {
    this.vmStatusCallbacks.set(vmId, callback)
  }
  
  /**
   * 移除虚拟机状态回调
   */
  removeVMStatusCallback(vmId: string) {
    this.vmStatusCallbacks.delete(vmId)
  }
  
  /**
   * 写入 VM 控制台
   */
  async writeToVmConsole(data: string): Promise<void> {
    try {
      // Worker 不可用时直接调用 NAPI
      if (!this.workerAvailable) {
        const native = await this.ensureNative()
        if (native.writeToVmConsole) {
          native.writeToVmConsole(data)
        }
        return
      }
      // TODO: Worker 模式支持
    } catch (error) {
      console.error('[QemuVMManager] 写入控制台失败:', error)
    }
  }
  
  /**
   * 设置控制台回调
   */
  async setConsoleCallback(callback: (data: string) => void): Promise<void> {
    try {
      if (!this.workerAvailable) {
        const native = await this.ensureNative()
        if (native.setConsoleCallback) {
          native.setConsoleCallback(callback)
        }
        return
      }
      // TODO: Worker 模式
    } catch (error) {
      console.error('[QemuVMManager] 设置控制台回调失败:', error)
    }
  }

  /**
   * 销毁 Worker
   */
  destroy() {
    if (this.worker) {
      this.worker.terminate()
      this.worker = null
    }
    this.vmStatusCallbacks.clear()
    this.pendingPromises.clear()
  }

  /**
   * 通过 QMP screendump 获取虚拟机屏幕截图
   * 由于 VNC 后端崩溃，使用这个作为替代方案显示 VM 预览
   * @param vmName 虚拟机名称
   * @param outputPath 输出文件路径（PPM 格式）
   * @returns 是否成功
   */
  async takeScreenshot(vmName: string, outputPath: string): Promise<boolean> {
    try {
      const native = await this.ensureNative()
      if (native.takeScreenshot) {
        return native.takeScreenshot(vmName, outputPath)
      }
      console.error('[QemuVMManager] takeScreenshot 不可用')
      return false
    } catch (error) {
      console.error('[QemuVMManager] takeScreenshot 失败:', error)
      return false
    }
  }
}
