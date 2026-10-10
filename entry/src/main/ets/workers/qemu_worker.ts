/**
 * QEMU Worker 线程（重写版）
 *  - 只调用 NAPI 中现有的高层 API
 *  - 管理状态轮询，并将结果通过 workerPort 推送回主线程
 */

import worker from '@ohos.worker'
import qemu from 'qemu_hmos'

type VmStatus = 'running' | 'stopped' | 'paused' | 'starting' | 'failed' | 'error'

interface WorkerVMConfig {
    name: string
  arch?: string
  archType?: 'aarch64' | 'x86_64' | 'i386'
  os?: string
    isoPath?: string
  diskSizeGB?: number
  diskSize?: number
  memory?: number
  memoryMB?: number
  cpuCores?: number
  cpuCount?: number
  accel?: string
  accelMode?: string
  display?: string
  displayMode?: string
  nographic?: boolean
  efiFirmware?: string  // UEFI 固件路径
}

interface QemuWorkerMessage {
  command: 'start_vm' | 'stop_vm' | 'pause_vm' | 'resume_vm' | 'get_status' |
           'create_snapshot' | 'restore_snapshot' | 'list_snapshots' | 'delete_snapshot' |
           'forward_port' | 'setup_network' | 'mount_shared_dir' |
           'get_kvm_info' | 'set_device_info'
  vmConfig?: WorkerVMConfig
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

interface QemuWorkerResponse {
  success: boolean
  message: string
  vmId?: string
  status?: VmStatus
  data?: Record<string, unknown>
}

interface QemuLastError {
  code: number
  name: string
  stage: string
  message: string
  vmName: string
}

const workerPort = worker.workerPort
const qemuNative = qemu

const vmIdToName = new Map<string, string>()
const statusMonitors = new Map<string, number>()

const STATUS_INTERVAL_MS = 5000

function fail(message: string): QemuWorkerResponse {
  return { success: false, message }
}

function resolveVmName(vmId?: string, explicitName?: string): string | undefined {
  if (explicitName) {
    return explicitName
  }
  if (!vmId) {
    return undefined
  }
  return vmIdToName.get(vmId) ?? vmId
}

function normalizeVmConfig(config?: WorkerVMConfig): { ok: true; value: WorkerVMConfig } | { ok: false; error: string } {
  if (!config) {
    return { ok: false, error: '缺少虚拟机配置' }
  }
  if (!config.name) {
    return { ok: false, error: '虚拟机名称不能为空' }
  }

  const arch = (config.archType ?? config.arch ?? 'aarch64') as WorkerVMConfig['archType']
  const memoryMB = config.memoryMB ?? config.memory
  const cpuCount = config.cpuCount ?? config.cpuCores
  const diskSizeGB = config.diskSizeGB ?? config.diskSize

  if (!memoryMB) {
    return { ok: false, error: '缺少内存配置' }
  }
  if (!cpuCount) {
    return { ok: false, error: '缺少 CPU 配置' }
  }
  if (!diskSizeGB) {
    return { ok: false, error: '缺少磁盘大小配置' }
  }

      return {
    ok: true,
    value: {
      ...config,
      archType: arch,
      memoryMB,
      cpuCount,
      diskSizeGB
      }
    }
}

function startVmStatusMonitor(vmId: string, vmName: string) {
  if (statusMonitors.has(vmId) || typeof qemuNative.getVmStatus !== 'function') {
    return
  }
  const timer = setInterval(() => {
    const status = readVmStatus(vmName)
    workerPort.postMessage({
      success: true,
      message: 'status_update',
      vmId,
      status,
      data: { timestamp: Date.now(), vmName }
    })
    if (status === 'stopped' || status === 'failed' || status === 'error') {
      stopVmStatusMonitor(vmId)
    }
  }, STATUS_INTERVAL_MS)
  statusMonitors.set(vmId, timer as unknown as number)
}

function stopVmStatusMonitor(vmId: string) {
  const timer = statusMonitors.get(vmId)
  if (timer !== undefined) {
    clearInterval(timer)
    statusMonitors.delete(vmId)
  }
}

function readVmStatus(vmName: string): VmStatus {
  try {
    if (typeof qemuNative.getVmStatus === 'function') {
      const state = qemuNative.getVmStatus(vmName)
      if (state === 'running' || state === 'stopped' || state === 'paused' ||
          state === 'preparing' || state === 'starting') {
        return state as VmStatus
      }
    }
    return 'stopped'
  } catch (error) {
    console.error('[QEMU Worker] 获取状态失败:', error)
    return 'error'
    }
  }
function startVM(config?: WorkerVMConfig): QemuWorkerResponse {
  if (!qemuNative) {
    return fail('Native 模块未加载')
  }
  const normalized = normalizeVmConfig(config)
  if (normalized.ok === false) {
    return fail(normalized.error)
  }

  // 类型守卫确保 normalized 是成功类型
  if (normalized.ok !== true) {
    return fail('配置验证失败')
  }

  const params = normalized.value
  const success = qemuNative.startVm({
    name: params.name,
    archType: params.archType,
    isoPath: params.isoPath,
    diskSizeGB: params.diskSizeGB,
    memoryMB: params.memoryMB,
    cpuCount: params.cpuCount,
    accel: params.accelMode ?? params.accel,
    display: params.displayMode ?? params.display,
    nographic: params.nographic ?? false,
    efiFirmware: params.efiFirmware  // 传递 UEFI 固件路径
  })

  if (!success) {
    const diagnostic = qemuNative.getLastError?.() as QemuLastError | undefined
    return fail(diagnostic
      ? `${diagnostic.name}(${diagnostic.code}) [${diagnostic.stage}]: ${diagnostic.message}`
      : '启动虚拟机失败，请检查 native 日志')
  }

  const vmId = params.name
  vmIdToName.set(vmId, params.name)
  startVmStatusMonitor(vmId, params.name)
  
  return {
    success: true,
    message: '虚拟机启动命令已下发',
    vmId,
    status: 'running',
    data: { archType: params.archType }
  }
}

function stopVM(message: QemuWorkerMessage): QemuWorkerResponse {
  const vmName = resolveVmName(message.vmId, message.vmName)
  if (!vmName) {
    return fail('缺少虚拟机标识')
  }
  if (!qemuNative) {
    return fail('Native 模块未加载')
  }
  const ok = qemuNative.stopVm(vmName)
  if (ok) {
    vmIdToName.delete(vmName)
    stopVmStatusMonitor(vmName)
  }
    return {
    success: ok,
    vmId: vmName,
    message: ok ? `虚拟机 ${vmName} 停止中` : `停止虚拟机 ${vmName} 失败`
    }
  }
  
function pauseVM(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.pauseVm !== 'function') {
    return fail('native 未实现 pauseVm')
  }
  const vmName = resolveVmName(message.vmId, message.vmName)
  if (!vmName) {
    return fail('缺少虚拟机标识')
  }
  const ok = qemuNative.pauseVm(vmName)
    return {
    success: ok,
    vmId: vmName,
    message: ok ? '虚拟机已暂停' : '暂停虚拟机失败',
    status: ok ? 'paused' : undefined
    }
  }
  
function resumeVM(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.resumeVm !== 'function') {
    return fail('native 未实现 resumeVm')
  }
  const vmName = resolveVmName(message.vmId, message.vmName)
  if (!vmName) {
    return fail('缺少虚拟机标识')
  }
  const ok = qemuNative.resumeVm(vmName)
  return {
    success: ok,
    vmId: vmName,
    message: ok ? '虚拟机已恢复' : '恢复虚拟机失败',
    status: ok ? 'running' : undefined
  }
}

function getVMStatus(message: QemuWorkerMessage): QemuWorkerResponse {
  const vmName = resolveVmName(message.vmId, message.vmName)
  if (!vmName) {
    return fail('缺少虚拟机标识')
  }
  const status = readVmStatus(vmName)
  return {
    success: true,
    vmId: vmName,
    status,
    message: '状态获取成功'
  }
}

function createSnapshot(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.createSnapshot !== 'function') {
    return fail('native 未实现快照功能')
  }
  if (!message.vmName || !message.snapshotName) {
    return fail('缺少快照参数')
  }
  const ok = qemuNative.createSnapshot(message.vmName, message.snapshotName)
    return {
    success: ok,
    vmId: message.vmName,
    message: ok ? '快照创建成功' : '快照创建失败'
    }
  }
  
function restoreSnapshot(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.restoreSnapshot !== 'function') {
    return fail('native 未实现快照功能')
  }
  if (!message.vmName || !message.snapshotName) {
    return fail('缺少快照参数')
  }
  const ok = qemuNative.restoreSnapshot(message.vmName, message.snapshotName)
    return {
    success: ok,
    vmId: message.vmName,
    message: ok ? '快照恢复成功' : '快照恢复失败'
    }
  }
  
function listSnapshots(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.listSnapshots !== 'function') {
    return fail('native 未实现快照功能')
  }
  if (!message.vmName) {
    return fail('缺少虚拟机名称')
  }
  const list = qemuNative.listSnapshots(message.vmName) || []
  return {
    success: true,
    vmId: message.vmName,
    message: '获取快照列表成功',
    data: { snapshots: list }
  }
}

function deleteSnapshot(message: QemuWorkerMessage): QemuWorkerResponse {
  if (typeof qemuNative.deleteSnapshot !== 'function') {
    return fail('native 未实现快照功能')
  }
  if (!message.vmName || !message.snapshotName) {
    return fail('缺少快照参数')
  }
  const ok = qemuNative.deleteSnapshot(message.vmName, message.snapshotName)
    return {
    success: ok,
    vmId: message.vmName,
    message: ok ? '快照删除成功' : '快照删除失败'
    }
  }
  
function getKvmInfo(): QemuWorkerResponse {
  const capabilities = typeof qemuNative.getDeviceCapabilities === 'function'
    ? qemuNative.getDeviceCapabilities()
    : undefined
  const kvmSupported = capabilities?.kvmSupported ?? qemuNative.kvmSupported()
  const jitSupported = capabilities?.jitSupported ?? qemuNative.enableJit()
  return {
    success: true,
    message: 'KVM 能力查询成功',
    data: {
      kvmSupported,
      jitSupported,
      totalMemory: capabilities?.totalMemory ?? 0,
      cpuCores: capabilities?.cpuCores ?? 0
    }
  }
}

function unsupported(message: string): QemuWorkerResponse {
  return fail(`${message}：native 模块未实现`)
}

workerPort.onmessage = (event: any) => {
  const message = event.data as QemuWorkerMessage
  let response: QemuWorkerResponse
  try {
    switch (message.command) {
      case 'start_vm':
        response = startVM(message.vmConfig)
        break
      case 'stop_vm':
        response = stopVM(message)
        break
      case 'pause_vm':
        response = pauseVM(message)
        break
      case 'resume_vm':
        response = resumeVM(message)
        break
      case 'get_status':
        response = getVMStatus(message)
        break
      case 'create_snapshot':
        response = createSnapshot(message)
        break
      case 'restore_snapshot':
        response = restoreSnapshot(message)
        break
      case 'list_snapshots':
        response = listSnapshots(message)
        break
      case 'delete_snapshot':
        response = deleteSnapshot(message)
        break
      case 'get_kvm_info':
        response = getKvmInfo()
        break
      case 'forward_port':
      case 'setup_network':
      case 'mount_shared_dir':
      case 'set_device_info':
        response = unsupported(message.command)
        break
      default:
        response = fail(`未知命令: ${message.command}`)
        break
    }
  } catch (error) {
    const errMsg = error instanceof Error ? error.message : `${error}`
    console.error('[QEMU Worker] 命令执行失败:', errMsg)
    response = fail(`执行失败: ${errMsg}`)
  }
  workerPort.postMessage(response)
}

workerPort.onerror = (error: any) => {
  console.error('[QEMU Worker] Worker 错误:', error)
}

console.info('[QEMU Worker] Worker 线程已初始化')
