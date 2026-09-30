/**
 * AppSettings
 * 主窗口（Index）使用的全局设置持久化：默认 CPU/内存/磁盘 等。
 *
 * 注意：
 * - 仅负责存取；UI 由 pages/Index.ets 的 SettingsContent 渲染。
 * - 不要在这里做复杂业务逻辑，避免引入循环依赖。
 */
import data_preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'
import hilog from '@ohos.hilog'

export type DefaultDisplayMode = 'vnc'

export interface AppSettingsData {
  defaultMemoryMB: number
  defaultDiskGB: number
  defaultCpuCount: number
  defaultMachine: string
  autoStartVnc: boolean
  defaultDisplay: DefaultDisplayMode
}

const PREF_NAME = 'app_settings'
const KEY_DEFAULT_MEMORY_MB = 'default_memory_mb'
const KEY_DEFAULT_DISK_GB = 'default_disk_gb'
const KEY_DEFAULT_CPU_COUNT = 'default_cpu_count'
const KEY_DEFAULT_MACHINE = 'default_machine'
const KEY_AUTO_START_VNC = 'auto_start_vnc'
const KEY_DEFAULT_DISPLAY = 'default_display'

const DEFAULT_SETTINGS: AppSettingsData = {
  defaultMemoryMB: 6144,
  defaultDiskGB: 64,
  defaultCpuCount: 4,
  defaultMachine: 'virt',
  autoStartVnc: true,
  defaultDisplay: 'vnc'
}
// Defaults aim for a smooth first boot; power users can override.

class AppSettings {
  private pref: data_preferences.Preferences | null = null
  private initialized: boolean = false
  private settings: AppSettingsData = {
    defaultMemoryMB: DEFAULT_SETTINGS.defaultMemoryMB,
    defaultDiskGB: DEFAULT_SETTINGS.defaultDiskGB,
    defaultCpuCount: DEFAULT_SETTINGS.defaultCpuCount,
    defaultMachine: DEFAULT_SETTINGS.defaultMachine,
    autoStartVnc: DEFAULT_SETTINGS.autoStartVnc,
    defaultDisplay: DEFAULT_SETTINGS.defaultDisplay
  }

  private cloneSettings(s: AppSettingsData): AppSettingsData {
    return {
      defaultMemoryMB: s.defaultMemoryMB,
      defaultDiskGB: s.defaultDiskGB,
      defaultCpuCount: s.defaultCpuCount,
      defaultMachine: s.defaultMachine,
      autoStartVnc: s.autoStartVnc,
      defaultDisplay: s.defaultDisplay
    }
  }

  private mergeSettings(base: AppSettingsData, patch: Partial<AppSettingsData>): AppSettingsData {
    const next: AppSettingsData = this.cloneSettings(base)
    if (typeof patch.defaultMemoryMB === 'number') next.defaultMemoryMB = patch.defaultMemoryMB
    if (typeof patch.defaultDiskGB === 'number') next.defaultDiskGB = patch.defaultDiskGB
    if (typeof patch.defaultCpuCount === 'number') next.defaultCpuCount = patch.defaultCpuCount
    if (typeof patch.defaultMachine === 'string') next.defaultMachine = patch.defaultMachine
    if (typeof patch.autoStartVnc === 'boolean') next.autoStartVnc = patch.autoStartVnc
    if (patch.defaultDisplay === 'vnc') next.defaultDisplay = 'vnc'
    return next
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return
    try {
      this.pref = await data_preferences.getPreferences(context, PREF_NAME)
      await this.load()
      this.initialized = true
      hilog.info(0x0000, 'AppSettings', '设置初始化完成')
    } catch (e) {
      hilog.error(0x0000, 'AppSettings', '设置初始化失败: %{public}s', (e as Error).message)
    }
  }

  getSettings(): AppSettingsData {
    return this.cloneSettings(this.settings)
  }

  async update(next: Partial<AppSettingsData>): Promise<void> {
    this.settings = this.mergeSettings(this.settings, next)
    await this.save()
  }

  private async load(): Promise<void> {
    if (!this.pref) return
    try {
      this.settings.defaultMemoryMB = await this.pref.get(KEY_DEFAULT_MEMORY_MB, DEFAULT_SETTINGS.defaultMemoryMB) as number
      this.settings.defaultDiskGB = await this.pref.get(KEY_DEFAULT_DISK_GB, DEFAULT_SETTINGS.defaultDiskGB) as number
      this.settings.defaultCpuCount = await this.pref.get(KEY_DEFAULT_CPU_COUNT, DEFAULT_SETTINGS.defaultCpuCount) as number
      this.settings.defaultMachine = await this.pref.get(KEY_DEFAULT_MACHINE, DEFAULT_SETTINGS.defaultMachine) as string
      this.settings.autoStartVnc = await this.pref.get(KEY_AUTO_START_VNC, DEFAULT_SETTINGS.autoStartVnc) as boolean
      // Migrate legacy RDP preference to the only supported VNC display mode.
      this.settings.defaultDisplay = 'vnc'
    } catch (e) {
      hilog.error(0x0000, 'AppSettings', '加载设置失败: %{public}s', (e as Error).message)
      this.settings = this.cloneSettings(DEFAULT_SETTINGS)
    }
  }

  private async save(): Promise<void> {
    if (!this.pref) return
    try {
      // 保护性 clamp，避免异常值污染持久化
      const mem = Math.max(512, Math.min(16384, Math.floor(this.settings.defaultMemoryMB)))
      const disk = Math.max(0, Math.min(2048, Math.floor(this.settings.defaultDiskGB)))
      const cpu = Math.max(1, Math.min(16, Math.floor(this.settings.defaultCpuCount)))
      const machine = (this.settings.defaultMachine || DEFAULT_SETTINGS.defaultMachine).trim() || DEFAULT_SETTINGS.defaultMachine
      const display: DefaultDisplayMode = 'vnc'

      await this.pref.put(KEY_DEFAULT_MEMORY_MB, mem)
      await this.pref.put(KEY_DEFAULT_DISK_GB, disk)
      await this.pref.put(KEY_DEFAULT_CPU_COUNT, cpu)
      await this.pref.put(KEY_DEFAULT_MACHINE, machine)
      await this.pref.put(KEY_AUTO_START_VNC, !!this.settings.autoStartVnc)
      await this.pref.put(KEY_DEFAULT_DISPLAY, display)
      await this.pref.flush()

      // 写回内存中的规范化结果
      this.settings.defaultMemoryMB = mem
      this.settings.defaultDiskGB = disk
      this.settings.defaultCpuCount = cpu
      this.settings.defaultMachine = machine
      this.settings.defaultDisplay = display
    } catch (e) {
      hilog.error(0x0000, 'AppSettings', '保存设置失败: %{public}s', (e as Error).message)
    }
  }
}

export const appSettings = new AppSettings()
