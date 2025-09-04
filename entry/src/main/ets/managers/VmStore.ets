import data_preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'

export type VMStatus = 'creating' | 'preparing' | 'running' | 'stopping' | 'stopped' | 'failed'

export interface VMConfigPersist {
  name: string
  osType: string
  diskSizeGB: number
  memoryMB: number
  cpuCount: number
  isoPath?: string
}

export interface VMMetaPersist {
  id: string
  name: string
  osType: string
  status: VMStatus
  createdAt: number
  config: VMConfigPersist
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
