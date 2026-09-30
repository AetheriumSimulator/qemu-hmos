import data_preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'

// paused = QEMU suspend（用户看到的"暂停"）
// stopped = 已关机
export type VMStatus = 'creating' | 'preparing' | 'starting' | 'running' | 'stopping' | 'stopped' | 'failed' | 'paused' | 'backup'

// 来宾系统类型
export type SystemCamp = 'windows' | 'linux' | 'bsd' | 'harmonyos' | 'macos' | 'other'

// 虚拟 CPU 架构
export type CpuCamp = 'aarch64' | 'x86_64' | 'i386' | 'riscv64' | 'other'

/**
 * 虚拟机启动模式
 * - standard: 普通启动 - 使用VNC，适用于macOS/不支持RDP的系统
 * - debug: 调试模式 - 仅串口TTL，无图形界面
 */
export type VMBootMode = 'standard' | 'debug'

/** 获取系统推荐的默认启动模式 */
export function getDefaultBootMode(systemCamp: SystemCamp): VMBootMode {
  return 'standard'
}

export interface VMConfigPersist {
  name: string
  osType: string
  diskSizeGB: number
  memoryMB: number
  cpuCount: number
  isoPath?: string
  archType?: 'aarch64' | 'x86_64' | 'i386'  // 架构类型
  // 高级硬件配置（可选）
  machine?: string
  displayDevice?: string
  networkDevice?: string
  audioDevice?: string
}

export interface VMMetaPersist {
  id: string
  name: string
  osType: string
  status: VMStatus
  createdAt: number
  config: VMConfigPersist
  // 新增字段：来宾系统类型和 CPU 架构
  systemCamp?: SystemCamp   // Windows / Linux / BSD / HarmonyOS / macOS
  cpuCamp?: CpuCamp         // aarch64 / x86_64 / i386 / riscv64
}

const PREFS_NAME = 'vms'
const KEY_VMS = 'list'

export class VmStore {
  private pref?: data_preferences.Preferences
  private inited = false
  private ctx: common.Context

  constructor(ctx: common.Context) {
    this.ctx = ctx
  }

  async init() {
    if (this.inited) return
    this.pref = await data_preferences.getPreferences(this.ctx, PREFS_NAME)
    this.inited = true
  }

  private ensure() {
    if (!this.inited || !this.pref) throw new Error('VmStore not initialized')
  }

  async loadAll(): Promise<VMMetaPersist[]> {
    await this.init()
    this.ensure()
    const raw = (await this.pref!.get(KEY_VMS, '[]')) as string
    try {
      const list = JSON.parse(raw) as VMMetaPersist[]
      return Array.isArray(list) ? list : []
    } catch {
      return []
    }
  }

  async saveAll(list: VMMetaPersist[]): Promise<void> {
    await this.init()
    this.ensure()
    await this.pref!.put(KEY_VMS, JSON.stringify(list))
    await this.pref!.flush()
  }

  async upsert(vm: VMMetaPersist): Promise<VMMetaPersist[]> {
    const all = await this.loadAll()
    const idx = all.findIndex(v => v.id === vm.id)
    if (idx >= 0) all[idx] = vm
    else all.push(vm)
    await this.saveAll(all)
    return all
  }

  async remove(id: string): Promise<VMMetaPersist[]> {
    const all = await this.loadAll()
    const next = all.filter(v => v.id !== id)
    await this.saveAll(next)
    return next
  }
}
