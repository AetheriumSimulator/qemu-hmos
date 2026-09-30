// Aether Engine 主页面 - 左侧导航栏 + 创建向导 + 动画 + 沉浸式 + 深色模式
// 目标平台：平板/电脑
import hilog from '@ohos.hilog'
import common from '@ohos.app.ability.common'
import Want from '@ohos.app.ability.Want'
import window from '@ohos.window'
import router from '@ohos.router'
import filePicker from '@ohos.file.picker'
import fs from '@ohos.file.fs'
import qemu from 'qemu_hmos'
import { VmStore, type VMMetaPersist, type VMStatus, type VMConfigPersist } from '../managers/VmStore'
import { FirmwareManager } from '../utils/FirmwareManager'
import { KeymapsManager } from '../utils/KeymapsManager'
import { QemuVMManager, type VMConfig as ManagerVMConfig } from '../managers/QemuVMManager'
import { StoragePaths } from '../utils/StoragePaths'
import promptAction from '@ohos.promptAction'
import type { CoreDiag } from '../types/qemu'
import { curves } from '@kit.ArkUI'
import { CustomTitleBar } from '../components/CustomTitleBar'
import { CommandPalette, VMInfo } from '../components/CommandPalette'
import { VMCreateWizard, WizardResult } from '../components/VMCreateWizard'
import deviceInfo from '@ohos.deviceInfo'
import { vncSettings } from '../managers/VNCSettings'

// ========== 类型定义 ==========
interface DeviceOptionBase {
  id: string
  name: string
  desc: string
}

interface DeviceCapabilities {
  kvmSupported: boolean
  jitSupported: boolean
  totalMemory: number
  cpuCores: number
  machines?: DeviceOptionBase[]
}

interface SupportedDevices {
  machines: DeviceOptionBase[]
  displays: DeviceOptionBase[]
  networks: DeviceOptionBase[]
  audios: DeviceOptionBase[]
}

// 设备扫描结果
interface ScanResult {
  success: boolean
  cached?: boolean
  rawJson?: string
  error?: string
}

interface QemuModule {
  version: () => string
  enableJit: () => boolean
  kvmSupported: () => boolean
  startVm: (config: object) => boolean
  stopVm: (name: string) => boolean
  getVmStatus?: (name: string) => string
  getVmLogs: (name: string, startLine?: number) => string[]
  checkCoreLib?: () => CoreDiag
  getDeviceCapabilities?: () => DeviceCapabilities
  getSupportedDevices?: () => SupportedDevices
  scanQemuDevices?: () => ScanResult  // 同步版本（返回缓存或提示）
  scanQemuDevicesAsync?: () => Promise<ScanResult>  // 异步扫描（返回 Promise）
  clearDeviceCache?: () => boolean     // 清除设备缓存
}

// (noVNC 已移除)

// 支持的架构
interface ArchOption { id: string; name: string; desc: string; supported: boolean }
// 支持的系统
interface OSOption { id: string; name: string; arch: string }
// 支持的机器类型
interface MachineOption { id: string; name: string; desc: string; icon: string }
// 设备分类结果
interface CategorizedDevices { displays: string[]; networks: string[]; audios: string[] }

const qemuModule: QemuModule | null = qemu ? (qemu as QemuModule) : null

// 向导步骤
type WizardStep = 'mode' | 'kvm_unavailable' | 'machine' | 'arch' | 'os' | 'config' | 'done'
// Sheet 类型
type SheetType = 'none' | 'wizard' | 'status' | 'startMode' | 'kvmDetail' | 'settings' | 'console' | 'shortcut' | 'vmSettings'

// ========== 数据类 ==========
class QemuConfig {
  name: string = ''
  osType: string = 'Windows'
  archType: string = 'aarch64'
  diskSizeGB: number = 64
  memoryMB: number = 6144
  cpuCount: number = 4
  isoPath: string = ''
  // 高级硬件配置（可选）
  machine?: string
  displayDevice?: string
  networkDevice?: string
  audioDevice?: string
}

// 扩展的持久化配置类型（用于兼容旧数据并访问高级硬件字段）
interface VMConfigPersistExt extends VMConfigPersist {
  machine?: string
  displayDevice?: string
  networkDevice?: string
  audioDevice?: string
}

class VMMeta {
  id: string = ''
  name: string = ''
  osType: string = 'Windows'
  status: VMStatus = 'stopped'
  createdAt: number = Date.now()
  config: QemuConfig = new QemuConfig()
  previewPath: string = ''  // 截图预览路径
  hasGuestAgent: boolean = false  // 是否有Guest Agent
  runningApps: string[] = []  // 运行中的应用（如果有Guest Agent）
}

// 架构显示名称转换
function getArchDisplayName(arch: string): string {
  switch (arch) {
    case 'aarch64': return 'ARM64'
    case 'x86_64': return 'X64'
    case 'i386': return 'X32'
    default: return arch.toUpperCase()
  }
}

// 状态显示名称
// 注意：paused 对应 QEMU 的 suspend，用户看到的是"暂停"
function getStatusDisplayName(status: VMStatus): string {
  switch (status) {
    case 'running': return '运行中'
    case 'stopped': return '已关机'
    case 'paused': return '暂停中'  // QEMU suspend
    case 'backup': return '备份中'
    case 'creating': return '创建中'
    case 'preparing': return '准备中'
    case 'starting': return '启动中'
    case 'stopping': return '关闭中'
    case 'failed': return '出错'
    default: return '未知'
  }
}

// 获取系统图标资源
function getOsIcon(osType: string): Resource {
  switch (osType.toLowerCase()) {
    case 'windows': return $r('app.media.ic_os_windows')
    case 'linux': return $r('app.media.ic_os_linux')
    case 'macos': return $r('app.media.ic_os_macos')
    case 'harmonyos': return $r('app.media.ic_os_harmonyos')
    case 'bsd': return $r('app.media.ic_os_bsd')
    default: return $r('app.media.ic_os_linux')
  }
}

// ========== 主页面 ==========
@Entry
@Component
struct Index {
  // ========== 状态 ==========
  @State currentTab: number = 0
  @State vms: VMMeta[] = []
  @State selectedVmId: string = ''
  @State isLoading: boolean = false
  @State errorMessage: string = ''
  @State testResult: string = '点击检测按钮开始诊断'
  
  // 窗口状态（从 AppStorage 读取）
  @StorageLink('showCustomTitleBar') showCustomTitleBar: boolean = true
  @StorageLink('safeAreaTop') safeAreaTop: number = 0
  @StorageLink('windowMode') windowMode: string = 'unknown'
  
  // 断点状态（响应式布局）
  @StorageLink('currentBreakpoint') currentBreakpoint: string = 'lg'
  @StorageLink('isCompact') isCompact: boolean = false
  @StorageLink('tabBarPosition') tabBarPosition: string = 'left'
  @StorageLink('usePhoneSheet') usePhoneSheet: boolean = false
  
  // Sheet 控制
  @State sheetVisible: boolean = false
  @State currentSheet: SheetType = 'none'
  @State startTargetVM: VMMeta | null = null
  @State keymapsAvailable: boolean = true  // 由 KeymapsManager 结果驱动，用于控制 VNC 启用状态
  
  // 向导状态
  @State wizardStep: WizardStep = 'mode'
  @State wizardMode: 'kvm' | 'tcg' = 'tcg'
  @State wizardMachine: string = 'virt'
  @State wizardArch: string = 'aarch64'
  @State wizardOS: string = 'Windows'
  @State wizardName: string = ''
  @State wizardMemory: number = 6144
  @State wizardDisk: number = 64
  @State wizardNoDisk: boolean = false
  @State wizardISOPath: string = ''
  // 可选：导入现有 QEMU 磁盘镜像
  @State wizardImportedDiskPath: string = ''
  
  // Popup 控制
  @State showX86Popup: boolean = false
  
  // 命令面板
  @State showCommandPalette: boolean = false
  // 侧边栏显示控制（仅在虚拟机页面使用）
  @State showSidebar: boolean = true
  // 窗口宽度（用于响应式布局）
  @State windowWidth: number = 1920
  @State windowHeight: number = 1080
  // 搜索关键字（用于过滤 VM 列表）
  @State searchKeyword: string = ''
  
  // 桌面快捷方式相关
  @StorageLink('launchShortcutId') launchShortcutId: string = ''
  @State activeShortcutId: string = ''
  @State shortcutSelectedVmId: string = ''
  @State shortcutMode: 'standard' | 'debug' | 'install' = 'standard'
  
  // 串口控制台状态
  @State consoleVmId: string = ''
  @State consoleLogs: string = ''
  @State consoleInput: string = ''
  private scroller: Scroller = new Scroller()
  
  // 屏幕预览状态（QMP screendump 替代 VNC）
  @State previewImagePath: string = ''
  @State previewLoading: boolean = false
  @State previewError: string = ''
  private previewTimerId: number = -1
  private statusTimerId: number = -1
  private readonly PREVIEW_INTERVAL: number = 2000  // 每 2 秒刷新一次预览
  
  // 设置项
  @State settingsDefaultMemory: number = 6144
  @State settingsDefaultDisk: number = 64
  @State settingsDefaultCpu: number = 4
  @State settingsDefaultMachine: string = 'virt'
  @State settingsAutoStartVnc: boolean = true
  @State settingsDefaultDisplay: string = 'vnc' // 默认显示方式
  
  // VNC 设置（仅原生 VNC）
  @State settingsVncNativePort: number = 5901  // 原生VNC端口 (RFB)

  // 动态数据（从代码获取）
  private kvmAvailable: boolean = false
  private supportedMachines: MachineOption[] = []
  private supportedDisplays: MachineOption[] = []
  private supportedNetworks: MachineOption[] = []
  private supportedAudios: MachineOption[] = []
  private supportedArchs: ArchOption[] = []
  private supportedOS: OSOption[] = []
  @State private isKvmCandidateDevice: boolean = false
  
  private store?: VmStore

  // ========== 生命周期 ==========
  aboutToAppear(): void {
    this.setupImmersive()
    // initStore 是异步的：完成后再启动状态轮询，保证“安装模式打开新窗口”时主窗口也能看到状态变化
    this.initStore().then(() => {
      this.refreshVmStatusesOnce()
      this.startStatusTimer()
    }).catch((_e: Error) => {
      // initStore 内部已有日志
    })
    this.initVncSettings()
    this.loadCapabilities()
    this.detectKvmCandidateDevice()
    this.startPreviewTimer()
  }

  private async initVncSettings(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      await vncSettings.init(ctx)
      const s = vncSettings.getSettings()
      this.settingsVncNativePort = s.nativePort
      hilog.info(0x0000, 'INDEX', '已加载 VNC 设置: nativePort=%{public}d', this.settingsVncNativePort)
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '加载 VNC 设置失败: %{public}s', (e as Error).message)
    }
  }

  private persistVncPort(nativePort: number): void {
    this.settingsVncNativePort = nativePort
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      vncSettings.init(ctx).then(async () => {
        await vncSettings.setNativePort(nativePort)
      }).catch((e: Error) => {
        hilog.error(0x0000, 'INDEX', '保存 VNC 端口失败: %{public}s', e.message)
      })
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '保存 VNC 端口异常: %{public}s', (e as Error).message)
    }
  }
  
  aboutToDisappear(): void {
    this.stopPreviewTimer()
    this.stopStatusTimer()
  }
  
  // 启动预览定时器
  private startPreviewTimer(): void {
    if (this.previewTimerId !== -1) return
    this.previewTimerId = setInterval((): void => {
      this.refreshPreview()
    }, this.PREVIEW_INTERVAL)
    // 立即刷新一次
    this.refreshPreview()
  }
  
  // 停止预览定时器
  private stopPreviewTimer(): void {
    if (this.previewTimerId !== -1) {
      clearInterval(this.previewTimerId)
      this.previewTimerId = -1
    }
  }

  // ========== VM 状态同步 ==========
  // 说明：
  // - VNC 会在新的 Ability 窗口中打开，主窗口不会自动收到状态变化
  // - 这里通过 NAPI 的 getVmStatus 做轮询校准，并写回 VmStore，保证主窗口能看到真实状态
  private startStatusTimer(): void {
    if (this.statusTimerId !== -1) return
    this.statusTimerId = setInterval((): void => {
      this.refreshVmStatusesOnce()
    }, 2000)
  }

  private stopStatusTimer(): void {
    if (this.statusTimerId !== -1) {
      clearInterval(this.statusTimerId)
      this.statusTimerId = -1
    }
  }

  private async refreshVmStatusesOnce(): Promise<void> {
    try {
      if (!qemuModule?.getVmStatus) return
      let changed = false
      for (const vm of this.vms) {
        let live = ''
        try {
          live = String(qemuModule.getVmStatus(vm.name))
        } catch (_) {
          live = ''
        }
        if (!live) continue
        // 兼容 native 可能返回的 shutdown
        const normalized = (live === 'shutdown') ? 'stopped' : live
        const allowed: VMStatus[] = ['creating', 'preparing', 'starting', 'running', 'stopping', 'stopped', 'failed', 'paused', 'backup']
        if (!allowed.includes(normalized as VMStatus)) continue
        if (vm.status !== (normalized as VMStatus)) {
          vm.status = normalized as VMStatus
          changed = true
        }
      }
      if (changed) {
        // 重要：vms 是 @State 数组，元素是 class 实例。仅修改字段可能不会触发 UI 刷新，
        // 这里通过重新赋值数组来强制触发渲染更新。
        this.vms = [...this.vms]
        await this.saveAllVMs()
      }
    } catch (e) {
      hilog.warn(0x0000, 'INDEX', '刷新 VM 状态失败: %{public}s', (e as Error).message)
    }
  }
  
  // 刷新选中 VM 的屏幕预览
  private async refreshPreview(): Promise<void> {
    const selectedVm = this.getSelectedVM()
    if (!selectedVm || selectedVm.status !== 'running') {
      this.previewImagePath = ''
      return
    }
    
    try {
      this.previewLoading = true
      this.previewError = ''
      
      // 构建截图输出路径
      const screenshotPath = `/data/storage/el2/base/haps/entry/files/vms/${selectedVm.name}/preview.ppm`
      
      // 调用 QMP screendump
      const success = await QemuVMManager.getInstance().takeScreenshot(selectedVm.name, screenshotPath)
      
      if (success) {
        // 添加时间戳强制刷新图片
        this.previewImagePath = `file://${screenshotPath}?t=${Date.now()}`
        hilog.info(0x0000, 'INDEX', '预览截图成功: %{public}s', this.previewImagePath)
      } else {
        this.previewError = '截图失败'
      }
    } catch (e) {
      this.previewError = (e as Error).message
      hilog.error(0x0000, 'INDEX', '预览截图异常: %{public}s', this.previewError)
    } finally {
      this.previewLoading = false
    }
  }

  private async setupImmersive(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const win = await window.getLastWindow(ctx)
      await win.setWindowLayoutFullScreen(true)
      await win.setWindowSystemBarProperties({
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      })
      // 获取初始窗口宽度
      const props = win.getWindowProperties()
      this.windowWidth = px2vp(props.windowRect.width)
      this.windowHeight = px2vp(props.windowRect.height)
      // 监听窗口大小变化
      win.on('windowSizeChange', (size: window.Size): void => {
        this.windowWidth = px2vp(size.width)
        this.windowHeight = px2vp(size.height)
      })
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '沉浸式失败: %{public}s', (e as Error).message)
    }
  }

  // 右侧预览卡片高度：随窗口大小自适应（大屏更大，浮窗/小窗不至于挤爆）
  private getPreviewCardHeight(): number {
    // 基于窗口高度的 36%，再做 clamp
    const raw = Math.floor(this.windowHeight * 0.36)
    const minH = 260
    const maxH = 560
    const clamped = Math.max(minH, Math.min(maxH, raw))

    // 超宽屏稍微再拉高一点，视觉更平衡
    if (this.windowWidth >= 1600) {
      return Math.min(maxH, clamped + 40)
    }
    return clamped
  }

  // 加载设备能力 - 动态从 QEMU 模块获取
  private loadCapabilities(): void {
    // 从 QEMU 模块获取设备能力
    let capabilities: DeviceCapabilities | null = null
    try {
      capabilities = qemuModule?.getDeviceCapabilities?.() ?? null
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '获取设备能力失败: %{public}s', (e as Error).message)
    }
    
    // 检测 KVM 支持
    this.kvmAvailable = capabilities?.kvmSupported ?? (qemuModule?.kvmSupported() ?? false)
    
    // 检查 QEMU 库是否加载
    const hasQemuLib = qemuModule !== null
    
    // 异步扫描设备列表（不阻塞主线程）
    this.scanDevicesAsync()
    
    // 先使用同步版本获取缓存（如果有）
    let scannedDevices: string[] = []
    if (qemuModule?.scanQemuDevices) {
      try {
        const scanResult = qemuModule.scanQemuDevices()
        if (scanResult.success && scanResult.rawJson) {
          scannedDevices = this.parseQmpDeviceList(scanResult.rawJson)
          hilog.info(0x0000, 'INDEX', '设备扫描（缓存）成功，发现 %{public}d 个设备', scannedDevices.length)
        }
      } catch (e) {
        hilog.error(0x0000, 'INDEX', '设备扫描异常: %{public}s', (e as Error).message)
      }
    }
    const categorized = this.categorizeDevices(scannedDevices)
    
    // 获取缓存的设备列表（如果扫描失败）
    const supportedDevices: SupportedDevices | undefined = qemuModule?.getSupportedDevices ? qemuModule.getSupportedDevices() : undefined

    const machinesFromNative: DeviceOptionBase[] | undefined = supportedDevices?.machines ?? capabilities?.machines
    if (machinesFromNative && machinesFromNative.length > 0) {
      this.supportedMachines = machinesFromNative.map((m: DeviceOptionBase): MachineOption => {
        const option: MachineOption = {
          id: m.id,
          name: m.name,
          desc: m.desc,
          icon: 'sys.symbol.display'
        }
        return option
      })
    } else {
    this.supportedMachines = [
        { id: 'virt',        name: 'virt',        desc: '通用 ARM 虚拟机平台（推荐）', icon: 'sys.symbol.display' },
        { id: 'virt-2.12',   name: 'virt-2.12',   desc: 'virt 2.12 兼容版本',         icon: 'sys.symbol.display' },
        { id: 'vexpress-a15',name: 'vexpress-a15',desc: 'ARM Versatile Express A15',  icon: 'sys.symbol.cpu' },
        { id: 'vexpress-a9', name: 'vexpress-a9', desc: 'ARM Versatile Express A9',   icon: 'sys.symbol.cpu' },
        { id: 'raspi3b',     name: 'raspi3b',     desc: 'Raspberry Pi 3B',            icon: 'sys.symbol.desktopcomputer' },
        { id: 'sbsa-ref',    name: 'sbsa-ref',    desc: 'SBSA 参考平台',               icon: 'sys.symbol.server_rack' }
    ]
    }

    // 显卡列表（优先使用扫描结果）
    if (categorized.displays.length > 0) {
      this.supportedDisplays = categorized.displays.map((id: string): MachineOption => ({
        id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.display'
      }))
      this.supportedDisplays.push({ id: 'none', name: '无显示设备', desc: '仅串口/网络访问', icon: 'sys.symbol.display' })
    } else if (supportedDevices && supportedDevices.displays && supportedDevices.displays.length > 0) {
      this.supportedDisplays = supportedDevices.displays.map((d: DeviceOptionBase): MachineOption => ({
        id: d.id, name: d.name, desc: d.desc, icon: 'sys.symbol.display'
      }))
    } else {
      // 默认显卡列表
      this.supportedDisplays = [
        { id: 'virtio-gpu-pci', name: 'VirtIO GPU', desc: 'VirtIO 虚拟显卡', icon: 'sys.symbol.display' },
        { id: 'ramfb', name: 'RAM Framebuffer', desc: '简单帧缓冲显示', icon: 'sys.symbol.display' },
        { id: 'none', name: '无显示设备', desc: '仅串口/网络访问', icon: 'sys.symbol.display' },
      ]
    }

    // 网卡列表（优先使用扫描结果）
    if (categorized.networks.length > 0) {
      this.supportedNetworks = categorized.networks.map((id: string): MachineOption => ({
        id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.link'
      }))
      this.supportedNetworks.push({ id: 'none', name: '无网络', desc: '离线模式', icon: 'sys.symbol.link' })
    } else if (supportedDevices && supportedDevices.networks && supportedDevices.networks.length > 0) {
      this.supportedNetworks = supportedDevices.networks.map((n: DeviceOptionBase): MachineOption => ({
        id: n.id, name: n.name, desc: n.desc, icon: 'sys.symbol.link'
      }))
    } else {
      // 默认网卡列表
      this.supportedNetworks = [
        { id: 'virtio-net-pci', name: 'VirtIO 网卡', desc: 'VirtIO 高性能网卡', icon: 'sys.symbol.link' },
        { id: 'none', name: '无网络', desc: '离线模式', icon: 'sys.symbol.link' },
      ]
    }

    // 声卡列表（优先使用扫描结果）
    if (categorized.audios.length > 0) {
      this.supportedAudios = [{ id: 'none', name: '无声卡', desc: '静音模式', icon: 'sys.symbol.speaker' }]
      for (const id of categorized.audios) {
        this.supportedAudios.push({ id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.speaker' })
      }
    } else if (supportedDevices && supportedDevices.audios && supportedDevices.audios.length > 0) {
      this.supportedAudios = supportedDevices.audios.map((a: DeviceOptionBase): MachineOption => ({
        id: a.id, name: a.name, desc: a.desc, icon: 'sys.symbol.speaker'
      }))
    } else {
      // 默认声卡列表
      this.supportedAudios = [
        { id: 'none', name: '无声卡', desc: '静音模式', icon: 'sys.symbol.speaker' },
        { id: 'ich9-intel-hda', name: 'Intel HDA', desc: 'ich9-intel-hda + hda-duplex', icon: 'sys.symbol.speaker' },
      ]
    }
    
    // 动态检测支持的架构（只保留 ARM64）
    this.supportedArchs = [
      { id: 'aarch64', name: 'ARM64', desc: '', supported: hasQemuLib }
    ]
    
    // 系统列表：只保留 Windows 和 Linux
    this.supportedOS = []
    if (hasQemuLib) {
      this.supportedOS.push(
        { id: 'Windows', name: 'Windows', arch: 'aarch64' },
        { id: 'Linux', name: 'Linux', arch: 'aarch64' }
      )
    }
    
    // 记录设备能力日志
    if (capabilities) {
      hilog.info(0x0000, 'INDEX', '设备能力: KVM=%{public}s, JIT=%{public}s, 内存=%{public}d MB, CPU=%{public}d 核',
        String(capabilities.kvmSupported),
        String(capabilities.jitSupported),
        Math.floor(capabilities.totalMemory / 1024 / 1024),
        capabilities.cpuCores
      )
    }
    
    // 测试 QEMU
    this.testQemuFunctions()
  }

  // 检测是否为潜在支持 KVM 的设备，用于决定是否展示 KVM 模式占位
  // 支持 KVM 的设备：MateBook Pro、MateBook Fold、MatePad Edge
  private detectKvmCandidateDevice(): void {
    try {
      // 获取设备信息
      const productModel: string = deviceInfo.productModel || ''
      const brand: string = deviceInfo.brand || ''
      
      hilog.info(0x0000, 'INDEX', 'detectKvmCandidateDevice: productModel=%{public}s, brand=%{public}s',
        productModel, brand)
      
      // 首先检查是否是华为设备
      const brandLower = brand.toLowerCase()
      const isHuawei = brandLower.includes('huawei') || brandLower.includes('honor')
      if (!isHuawei) {
        hilog.info(0x0000, 'INDEX', 'detectKvmCandidateDevice: 非华为设备，跳过')
        this.isKvmCandidateDevice = false
        return
      }
      
      // 候选设备的代号前缀（小写）
      // MatePad Edge: QXS-W10, QXS-W10P 等
      // MateBook Pro / MateBook Fold: 代号待补充
      const codenamePrefixes: string[] = ['qxs']
      
      // 检查代号前缀
      const modelLower = productModel.toLowerCase()
      const matched = codenamePrefixes.some((prefix: string): boolean => modelLower.startsWith(prefix))
      
      this.isKvmCandidateDevice = matched
      hilog.info(0x0000, 'INDEX', 'detectKvmCandidateDevice 结果: %{public}s (model=%{public}s)',
        String(this.isKvmCandidateDevice), productModel)
    } catch (e) {
      this.isKvmCandidateDevice = false
      hilog.error(0x0000, 'INDEX', 'detectKvmCandidateDevice 失败: %{public}s', (e as Error).message)
    }
  }

  private async initStore(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      this.store = new VmStore(ctx)
      const list = await this.store.loadAll()
      this.vms = list.map((p: VMMetaPersist): VMMeta => {
        const m = new VMMeta()
        m.id = p.id
        m.name = p.name
        m.osType = p.osType
        m.createdAt = p.createdAt
        // 恢复持久化状态，避免每次进页面都把运行中的 VM 显示成“已关机”
        m.status = (p.status || 'stopped') as VMStatus

        const persistedCfg = p.config as VMConfigPersistExt
        const cfg = new QemuConfig()
        cfg.name = persistedCfg.name
        cfg.osType = persistedCfg.osType
        cfg.diskSizeGB = persistedCfg.diskSizeGB
        cfg.memoryMB = persistedCfg.memoryMB
        cfg.cpuCount = persistedCfg.cpuCount
        cfg.isoPath = persistedCfg.isoPath || ''
        cfg.archType = persistedCfg.archType ?? 'aarch64'

        // 恢复高级硬件配置（如果存在）
        cfg.machine = persistedCfg.machine
        cfg.displayDevice = persistedCfg.displayDevice
        cfg.networkDevice = persistedCfg.networkDevice
        cfg.audioDevice = persistedCfg.audioDevice

        m.config = cfg
        return m
      })
      if (this.vms.length > 0) this.selectedVmId = this.vms[0].id
      // 初始化完成后处理桌面快捷方式启动
      this.handleShortcutLaunch()
      } catch (e) {
      hilog.error(0x0000, 'INDEX', '加载失败: %{public}s', (e as Error).message)
    }
  }

  // 异步扫描设备列表（不阻塞主线程）
  private scanDevicesAsync(): void {
    if (!qemuModule?.scanQemuDevicesAsync) {
      hilog.warn(0x0000, 'INDEX', '异步设备扫描不可用')
      return
    }
    
    hilog.info(0x0000, 'INDEX', '开始异步扫描设备...')
    qemuModule.scanQemuDevicesAsync().then((result: ScanResult) => {
      if (result.success && result.rawJson) {
        const devices = this.parseQmpDeviceList(result.rawJson)
        const categorized = this.categorizeDevices(devices)
        hilog.info(0x0000, 'INDEX', '异步扫描完成，发现 %{public}d 个设备', devices.length)
        
        // 更新设备列表（如果扫描到了设备）
        if (categorized.displays.length > 0) {
          this.supportedDisplays = categorized.displays.map((id: string): MachineOption => ({
            id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.display'
          }))
          this.supportedDisplays.push({ id: 'none', name: '无显示设备', desc: '仅串口/网络访问', icon: 'sys.symbol.display' })
        }
        
        if (categorized.networks.length > 0) {
          this.supportedNetworks = categorized.networks.map((id: string): MachineOption => ({
            id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.link'
          }))
          this.supportedNetworks.push({ id: 'none', name: '无网络', desc: '离线模式', icon: 'sys.symbol.link' })
        }
        
        if (categorized.audios.length > 0) {
          this.supportedAudios = [{ id: 'none', name: '无声卡', desc: '静音模式', icon: 'sys.symbol.speaker' }]
          for (const id of categorized.audios) {
            this.supportedAudios.push({ id: id, name: id, desc: '从 QEMU 动态扫描', icon: 'sys.symbol.speaker' })
          }
        }
      } else if (result.error) {
        hilog.warn(0x0000, 'INDEX', '异步扫描失败: %{public}s', result.error)
      }
    }).catch((e: Error) => {
      hilog.error(0x0000, 'INDEX', '异步扫描异常: %{public}s', e.message)
    })
  }

  // 解析 QMP 返回的设备列表 JSON
  private parseQmpDeviceList(rawJson: string): string[] {
    const devices: string[] = []
    try {
      // QMP 返回格式：{"return": [{"name": "device-name", ...}, ...]}
      const response = JSON.parse(rawJson) as Record<string, object[]>
      const returnArray = response['return'] as Array<Record<string, string>>
      if (Array.isArray(returnArray)) {
        for (const item of returnArray) {
          if (item && typeof item['name'] === 'string') {
            devices.push(item['name'])
          }
        }
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '解析 QMP 设备列表失败: %{public}s', (e as Error).message)
    }
    return devices
  }

  // 根据设备名称分类
  private categorizeDevices(devices: string[]): CategorizedDevices {
    const displays: string[] = []
    const networks: string[] = []
    const audios: string[] = []
    
    // 显卡关键词
    const displayKeywords: string[] = ['vga', 'gpu', 'display', 'framebuffer', 'fb', 'bochs', 'cirrus', 'qxl', 'virtio-gpu', 'ramfb']
    // 网卡关键词
    const networkKeywords: string[] = ['net', 'nic', 'e1000', 'rtl', 'ne2k', 'pcnet', 'vmxnet', 'usb-net', 'virtio-net']
    // 声卡关键词
    const audioKeywords: string[] = ['audio', 'sound', 'hda', 'ac97', 'sb16', 'es1370', 'adlib', 'gus', 'cs4231', 'intel-hda']
    
    for (const device of devices) {
      const lower = device.toLowerCase()
      
      // 分类到显卡
      for (const kw of displayKeywords) {
        if (lower.includes(kw)) {
          displays.push(device)
          break
        }
      }
      
      // 分类到网卡
      for (const kw of networkKeywords) {
        if (lower.includes(kw)) {
          networks.push(device)
          break
        }
      }
      
      // 分类到声卡
      for (const kw of audioKeywords) {
        if (lower.includes(kw)) {
          audios.push(device)
          break
        }
      }
    }
    
    const result: CategorizedDevices = { displays: displays, networks: networks, audios: audios }
    return result
  }

  private testQemuFunctions(): void {
    try {
      if (!qemuModule) { this.testResult = '❌ QEMU模块未加载'; return }
      const version = qemuModule.version()
      const jit = qemuModule.enableJit()
      const kvm = qemuModule.kvmSupported()
      this.testResult = `QEMU ${version}\nJIT: ${jit ? '✓' : '✗'}  KVM: ${kvm ? '✓' : '✗'}`
      } catch (e) {
      this.testResult = '❌ ' + (e as Error).message
    }
  }

  // 处理从桌面快捷方式启动的场景：弹出绑定/启动半模态
  private handleShortcutLaunch(): void {
    if (!this.launchShortcutId) {
      return
    }
    if (this.vms.length === 0) {
      hilog.info(0x0000, 'INDEX', '快捷方式启动但当前没有虚拟机')
      AppStorage.set<string>('launchShortcutId', '')
      return
    }
    this.activeShortcutId = this.launchShortcutId
    if (!this.shortcutSelectedVmId) {
      this.shortcutSelectedVmId = this.vms[0].id
    }
    this.shortcutMode = 'standard'
    this.currentSheet = 'shortcut'
    this.sheetVisible = true
    hilog.info(0x0000, 'INDEX', '处理快捷方式启动, shortcutId=%{public}s', this.activeShortcutId)
    AppStorage.set<string>('launchShortcutId', '')
  }

  // ========== Sheet / 向导控制 ==========
  private openWizard(): void {
    hilog.info(0x0000, 'INDEX', '>>> 打开向导 <<<')
    this.wizardStep = 'mode'
    this.wizardMode = 'tcg'
    this.wizardMachine = this.settingsDefaultMachine // 使用默认设置
    this.wizardArch = 'aarch64'
    this.wizardOS = 'Windows'
    this.wizardMemory = this.settingsDefaultMemory // 使用默认设置
    this.wizardDisk = this.settingsDefaultDisk // 使用默认设置
    this.wizardNoDisk = false
    this.wizardISOPath = ''
    this.currentSheet = 'wizard'
    this.sheetVisible = true
    hilog.info(0x0000, 'INDEX', 'sheetVisible=%{public}s, currentSheet=%{public}s', String(this.sheetVisible), this.currentSheet)
  }

  private closeSheet(): void {
    hilog.info(0x0000, 'INDEX', '>>> 关闭 Sheet <<<')
    this.sheetVisible = false
    this.currentSheet = 'none'
  }
  
  // 导出所有 VM 日志到公共目录
  private async exportLogs(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      let exportedCount = 0
      
      // 遍历所有 VM 导出日志
      for (const vm of this.vms) {
        const result = await StoragePaths.exportVmLog(ctx, vm.name)
        if (result) {
          exportedCount++
          hilog.info(0x0000, 'INDEX', '导出日志: %{public}s -> %{public}s', vm.name, result)
        }
      }
      
      if (exportedCount > 0) {
        promptAction.showToast({
          message: `已导出 ${exportedCount} 个日志，可在应用内查看`,
          duration: 3000
        })
      } else {
        promptAction.showToast({
          message: '没有可导出的日志',
          duration: 2000
        })
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '导出日志失败: %{public}s', (e as Error).message)
      promptAction.showToast({
        message: '导出失败: ' + (e as Error).message,
        duration: 2000
      })
    }
  }

  private openSheet(type: SheetType): void {
    hilog.info(0x0000, 'INDEX', '>>> 打开 Sheet: %{public}s <<<', type)
    this.currentSheet = type
    if (type === 'startMode') {
      // 打开启动模式弹窗前刷新 keymaps 状态，确保按钮可用性正确
      void this.refreshKeymapsAvailability()
    }
    if (type === 'wizard') {
      this.openWizard()
    } else {
      this.sheetVisible = true
      hilog.info(0x0000, 'INDEX', 'sheetVisible=%{public}s', String(this.sheetVisible))
    }
  }

  // 刷新 keymaps 可用性，供启动模式弹窗按钮禁用判断
  private async refreshKeymapsAvailability(): Promise<void> {
    hilog.info(0x0000, 'INDEX', '>>> refreshKeymapsAvailability 开始 [v3-1225] <<<')
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      hilog.info(0x0000, 'INDEX', 'ctx 获取成功')
      const dir = await KeymapsManager.ensureKeymaps(ctx)
      hilog.info(0x0000, 'INDEX', 'ensureKeymaps 返回: %{public}s', dir || '(null)')
      this.keymapsAvailable = !!dir
      hilog.info(0x0000, 'INDEX', 'keymapsAvailable=%{public}s', String(this.keymapsAvailable))
    } catch (e) {
      this.keymapsAvailable = false
      hilog.error(0x0000, 'INDEX', '刷新 keymaps 状态失败: %{public}s', (e as Error).message)
    }
    hilog.info(0x0000, 'INDEX', '>>> refreshKeymapsAvailability 结束 <<<')
  }

  private async openConsole(vmId: string): Promise<void> {
    this.consoleVmId = vmId
    this.consoleLogs = '>>> 控制台已连接 (stdout/stderr) <<<\n'
    this.openSheet('console')
    
    // 注册回调
    try {
      await QemuVMManager.getInstance().setConsoleCallback((data: string) => {
        this.consoleLogs += data
        // 自动滚动到底部
        this.scroller.scrollEdge(Edge.Bottom)
      })
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '注册控制台回调失败: %{public}s', (e as Error).message)
    }
  }

  // 向导导航
  private wizardNext(): void {
    switch (this.wizardStep) {
      case 'mode':
        if (this.wizardMode === 'kvm' && !this.kvmAvailable) {
          this.wizardStep = 'kvm_unavailable'
        } else {
          this.wizardStep = 'arch'
        }
        break
      case 'kvm_unavailable':
        this.wizardStep = 'mode'
        break
      case 'arch':
        this.wizardStep = 'os'
        break
      case 'os':
        this.wizardStep = 'config'
        break
      case 'config':
        this.wizardStep = 'done'
        break
      case 'done':
        this.createVMFromWizard()
        break
    }
  }

  private wizardBack(): void {
    switch (this.wizardStep) {
      case 'kvm_unavailable':
      case 'arch':
        this.wizardStep = 'mode'
        break
      case 'os':
        this.wizardStep = 'arch'
        break
      case 'config':
        this.wizardStep = 'os'
        break
      case 'done':
        this.wizardStep = 'config'
        break
    }
  }

  // ========== ISO 选择 ==========
  private async selectISO(): Promise<void> {
    try {
      const docPicker = new filePicker.DocumentViewPicker()
      const result = await docPicker.select({ maxSelectNumber: 1 })
      if (result && result.length > 0) {
        this.wizardISOPath = result[0]
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '选择ISO失败: %{public}s', (e as Error).message)
    }
  }

  // 选择并导入现有 QEMU 磁盘镜像（qcow2/raw）
  private async selectDiskImage(): Promise<void> {
    try {
      const docPicker = new filePicker.DocumentViewPicker()
      const result = await docPicker.select({ maxSelectNumber: 1 })
      if (result && result.length > 0) {
        const rawPath = result[0] as string
        const normalized = this.normalizeDocumentPath(rawPath)
        this.wizardImportedDiskPath = normalized
        hilog.info(0x0000, 'INDEX', '已选择导入磁盘镜像: raw=%{public}s normalized=%{public}s', rawPath, normalized)
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '选择磁盘镜像失败: %{public}s', (e as Error).message)
    }
  }

  // 将 DocumentPicker 返回的 file://docs/... URI 转换为实际文件系统路径
  private normalizeDocumentPath(uri: string): string {
    if (!uri) {
      return uri
    }
    // HarmonyOS DocumentViewPicker 返回的路径形如:
    // file://docs/storage/Users/currentUser/Download/xxx.qcow2
    // 实际文件路径从 /storage 开始
    if (uri.startsWith('file://docs')) {
      return uri.replace('file://docs', '')
    }
    if (uri.startsWith('file://')) {
      return uri.replace('file://', '')
    }
    return uri
  }

  // 选择 ISO 并复制到沙箱 isos 目录；更新 VM 配置
  private async pickIsoForVm(vm: VMMeta): Promise<void> {
    try {
      const picker = new filePicker.DocumentViewPicker()
      const res = await picker.select({ maxSelectNumber: 1 })
      if (!res || res.length === 0) {
        return
      }
      const rawPath = res[0] as string
      const normalized = this.normalizeDocumentPath(rawPath)
      await StoragePaths.ensureDirectories()
      const safeName = vm.name.replace(/[^\w.-]/g, '_') || 'vm'
      const targetIso = `${StoragePaths.ISOS_DIR}/${safeName}.iso`
      if (normalized !== targetIso) {
        try { await fs.access(targetIso) } catch (_) { /* ignore */ }
        // 覆盖旧的同名 ISO
        await fs.copyFile(normalized, targetIso)
      }
      vm.config.isoPath = targetIso
      await this.saveAllVMs()
      promptAction.showToast({ message: 'ISO 已复制到沙箱并挂载', duration: 2000 })
      // UX：选完 ISO 自动关闭弹窗，避免“必须手动关 Sheet 才能继续用”
      try {
        this.closeSheet()
      } catch (_) {
        // ignore
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '选择/复制 ISO 失败: %{public}s', (e as Error).message)
      promptAction.showToast({ message: 'ISO 选择失败: ' + (e as Error).message, duration: 2500 })
    }
  }

  // 弹出 ISO：清空配置并删除沙箱内副本（若存在）
  private async ejectIso(vm: VMMeta): Promise<void> {
    try {
      const current = vm.config.isoPath
      if (current && current.startsWith(StoragePaths.ISOS_DIR)) {
        try { await fs.unlink(current) } catch (_) { /* ignore missing */ }
      }
      vm.config.isoPath = ''
      await this.saveAllVMs()
      promptAction.showToast({ message: '已弹出 ISO', duration: 1500 })
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '弹出 ISO 失败: %{public}s', (e as Error).message)
      promptAction.showToast({ message: '弹出失败: ' + (e as Error).message, duration: 2500 })
    }
  }

  // ========== VM 操作 ==========
  private async createVMFromWizard(): Promise<void> {
    try {
      this.isLoading = true
      const newVM = new VMMeta()
      newVM.id = Date.now().toString()
      const defaultName = `${this.wizardOS} VM`
      const rawName = this.wizardName ? this.wizardName.trim() : ''
      newVM.name = rawName || defaultName
      newVM.osType = this.wizardOS
      newVM.config.name = newVM.name
      newVM.config.osType = this.wizardOS
      newVM.config.archType = this.wizardArch
      newVM.config.diskSizeGB = this.wizardNoDisk ? 0 : this.wizardDisk
      newVM.config.memoryMB = this.wizardMemory
      newVM.config.cpuCount = 4
      newVM.config.isoPath = this.wizardISOPath

      // 如果用户选择了现有 QEMU 磁盘镜像，则在创建 VM 目录后复制过去
      if (this.wizardImportedDiskPath) {
        try {
          await StoragePaths.ensureVmDirectories(newVM.name)
          const destPath = StoragePaths.getVmDiskPath(newVM.name)
          // 覆盖已有磁盘（如果存在）
          await fs.copyFile(this.wizardImportedDiskPath, destPath)
          const stat = fs.statSync(destPath)
          const sizeGB = Math.max(1, Math.floor(stat.size / (1024 * 1024 * 1024)))
          newVM.config.diskSizeGB = sizeGB
          hilog.info(0x0000, 'INDEX', '已导入磁盘镜像到: %{public}s, 大小约 %{public}d GB', destPath, sizeGB)
        } catch (e) {
          hilog.error(0x0000, 'INDEX', '导入磁盘镜像失败: %{public}s', (e as Error).message)
          this.errorMessage = '导入磁盘镜像失败: ' + (e as Error).message
          this.isLoading = false
          return
        }
      }

      this.vms.push(newVM)
      this.selectedVmId = newVM.id
      await this.saveAllVMs()
      this.closeSheet()
      // 询问是否启动
      this.startTargetVM = newVM
      setTimeout((): void => { this.openSheet('startMode') }, 300)
    } catch (e) {
      this.errorMessage = (e as Error).message
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 从新向导结果创建虚拟机
   */
  private async createVMFromWizardResult(result: WizardResult): Promise<void> {
    try {
      this.isLoading = true
      const newVM = new VMMeta()
      newVM.id = Date.now().toString()
      newVM.name = result.name
      newVM.osType = result.osType
      newVM.config.name = result.name
      newVM.config.osType = result.osType
      newVM.config.archType = result.archType
      newVM.config.diskSizeGB = result.noDisk ? 0 : result.diskSizeGB
      newVM.config.memoryMB = result.memoryMB
      newVM.config.cpuCount = 4
      newVM.config.isoPath = result.isoPath
      // 高级硬件配置（如果是普通模式，这些字段会使用默认值）
      newVM.config.machine = result.machine
      newVM.config.displayDevice = result.displayDevice
      newVM.config.networkDevice = result.networkDevice
      newVM.config.audioDevice = result.audioDevice

      // 如果用户选择了现有磁盘镜像，复制到 VM 目录
      if (result.importedDiskPath) {
        try {
          await StoragePaths.ensureVmDirectories(newVM.name)
          const destPath = StoragePaths.getVmDiskPath(newVM.name)
          await fs.copyFile(result.importedDiskPath, destPath)
          const stat = fs.statSync(destPath)
          const sizeGB = Math.max(1, Math.floor(stat.size / (1024 * 1024 * 1024)))
          newVM.config.diskSizeGB = sizeGB
          hilog.info(0x0000, 'INDEX', '已导入磁盘镜像到: %{public}s, 大小约 %{public}d GB', destPath, sizeGB)
        } catch (e) {
          hilog.error(0x0000, 'INDEX', '导入磁盘镜像失败: %{public}s', (e as Error).message)
          this.errorMessage = '导入磁盘镜像失败: ' + (e as Error).message
          this.isLoading = false
          return
        }
      }

      this.vms.push(newVM)
      this.selectedVmId = newVM.id
      await this.saveAllVMs()
      this.closeSheet()
      
      // 询问是否启动
      this.startTargetVM = newVM
      setTimeout((): void => { this.openSheet('startMode') }, 300)
    } catch (e) {
      this.errorMessage = (e as Error).message
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 启动虚拟机
   * @param vm 虚拟机元数据
   * @param bootMode 启动模式:
   *   - 'standard': 普通启动 (VNC) - macOS/其他系统
   *   - 'debug': 调试模式 (串口TTL) - 无图形界面
   *   - 'install': 安装模式 (VNC) - 系统安装时使用
   */
  private async startVM(vm: VMMeta, bootMode: 'standard' | 'debug' | 'install'): Promise<void> {
    hilog.info(0x0000, 'INDEX', '>>> startVM 开始: vm=%{public}s, bootMode=%{public}s <<<', vm.name, bootMode)
    try {
      this.isLoading = true
      this.closeSheet()
      vm.status = 'starting'
      this.vms = [...this.vms]
      hilog.info(0x0000, 'INDEX', 'Sheet 已关闭，状态设为 starting')
      const ctx = getContext(this) as common.UIAbilityContext
      
      // 确保 UEFI 固件存在
      hilog.info(0x0000, 'INDEX', '>>> 检查 UEFI 固件 <<<')
      const firmware = await FirmwareManager.ensureUefi(ctx)
      hilog.info(0x0000, 'INDEX', '固件路径: %{public}s', firmware || '(null)')
      if (!firmware) { 
        hilog.error(0x0000, 'INDEX', '固件不存在，终止启动')
        this.errorMessage = '缺少UEFI固件'; vm.status = 'failed'; return 
      }
      
      // 非调试模式需要 keymaps（VNC需要显示）
      let qemuDataDir: string | null = null
      let keymapsAvailable = false
      if (bootMode !== 'debug') {
        qemuDataDir = await KeymapsManager.ensureKeymaps(ctx)
        if (!qemuDataDir) {
          console.warn('QEMU keymaps 初始化失败，VNC可能无法正常工作')
          this.keymapsAvailable = false
        } else {
          keymapsAvailable = true
          this.keymapsAvailable = true
        }
      } else {
        this.keymapsAvailable = false
      }
      
      // 如果选择了 ISO，将其拷贝到应用沙箱的 isos 目录，避免外部路径不可读
      let isoPath = vm.config.isoPath
      if (isoPath) {
        try {
          await StoragePaths.ensureDirectories()
          const safeName = vm.name.replace(/[^\w.-]/g, '_')
          const targetIsoDir = StoragePaths.ISOS_DIR
          const targetIso = `${targetIsoDir}/${safeName}.iso`
          // 如果源路径不同且目标不存在，则复制
          if (isoPath !== targetIso) {
            try { await fs.access(targetIso) } catch (_) {
              await fs.copyFile(isoPath, targetIso)
            }
            isoPath = targetIso
          }
        } catch (e) {
          console.warn('拷贝 ISO 到沙箱失败，仍然使用原路径:', (e as Error).message)
        }
      }

      // install 模式必须挂载 ISO，否则等同于“空盘启动”，UEFI 会无事可做，看起来像卡死
      // 这里直接拦截，避免用户白等数小时
      hilog.info(0x0000, 'INDEX', '启动参数检查: bootMode=%{public}s, isoPath=%{public}s',
        bootMode, isoPath || '(empty)')
      if (bootMode === 'install' && !isoPath) {
        hilog.error(0x0000, 'INDEX', 'install 模式缺少 ISO，终止启动')
        this.errorMessage = '安装模式需要先选择 ISO 镜像'
        promptAction.showToast({ message: '请先为该 VM 选择 ISO（安装镜像）', duration: 2500 })
        vm.status = 'failed'
        return
      }
      // install 模式 ISO 路径存在，但文件可能已被删除/拷贝失败（UI 看起来“挂载了”，实际 QEMU 读不到）
      if (bootMode === 'install' && isoPath) {
        try {
          await fs.access(isoPath)
          const st = await fs.stat(isoPath)
          if (st.size < 1024 * 1024) { // <1MB 基本不可能是可用 ISO
            throw new Error(`ISO 文件过小: ${st.size} bytes`)
          }
        } catch (e) {
          hilog.error(0x0000, 'INDEX', 'install ISO 不可用，终止启动: %{public}s', (e as Error).message)
          this.errorMessage = 'ISO 文件不可用，请重新选择'
          promptAction.showToast({ message: 'ISO 文件不存在/不可读，请重新选择 ISO', duration: 3000 })
          // 清空，避免下次继续误判“已挂载”
          vm.config.isoPath = ''
          await this.saveAllVMs()
          vm.status = 'failed'
          return
        }
      }
      
      // 根据启动模式配置 QEMU 参数
      let displayMode: string
      let nographic: boolean
      
      // 使用设置中的 VNC 端口
      // VNC display number = 端口 - 5900（如：5901 -> display :1）
      const nativePort = this.settingsVncNativePort  // 原生 RFB 端口从设置读取
      const vncDisplay = nativePort - 5900  // 计算 display number
      
      hilog.info(0x0000, 'INDEX', 'VNC 配置: nativePort=%{public}d, vncDisplay=%{public}d',
        nativePort, vncDisplay)
      
      switch (bootMode) {
        case 'standard':
        case 'install':
          // 普通启动/安装：原生 VNC（RFB）
          displayMode = `vnc=0.0.0.0:${vncDisplay}`
          nographic = false
          break
        case 'debug':
          // 调试模式：无图形，仅串口
          displayMode = 'none'
          nographic = true
          break
      }

      // 如果缺少 keymaps，则禁止 VNC/图形显示，强制无头
      if (!keymapsAvailable && bootMode !== 'debug') {
        console.warn('缺少 keymaps，禁用 VNC/图形，改为无头模式')
        displayMode = 'none'
        nographic = true
      }
      
      const manager = QemuVMManager.getInstance()
      // 将最终使用的 ISO 路径写回 VM 配置，便于后续查看/重启
      vm.config.isoPath = isoPath

      // 安装模式(aarch64)显示设备兜底：
      // - Windows ARM 安装/UEFI 阶段对 virtio-gpu-device(MMIO) 可能没有驱动，VNC 会长期停留在 "Display Output Is Not Active"
      // - ramfb 在固件阶段最稳定，优先保证“能出画面”
      let effectiveDisplayDevice: string | undefined = vm.config.displayDevice
      if (bootMode === 'install' && (vm.config.archType || 'aarch64') === 'aarch64') {
        if (!effectiveDisplayDevice || effectiveDisplayDevice === 'auto' || effectiveDisplayDevice === 'none' ||
          effectiveDisplayDevice.startsWith('virtio-gpu')) {
          effectiveDisplayDevice = 'ramfb'
          hilog.warn(0x0000, 'INDEX', 'install(aarch64) 显示设备兜底为 ramfb（原=%{public}s）',
            vm.config.displayDevice || '(empty)')
        }
      }

      hilog.info(0x0000, 'INDEX', '>>> 构建 VM 配置 <<<')
      hilog.info(0x0000, 'INDEX', 'displayMode=%{public}s, nographic=%{public}s, keymapsAvailable=%{public}s',
        displayMode, String(nographic), String(keymapsAvailable))
      
      const config = {
        name: vm.name,
        archType: (vm.config.archType || 'aarch64') as 'aarch64' | 'x86_64' | 'i386',
        isoPath: isoPath,
        diskSizeGB: vm.config.diskSizeGB,
        memoryMB: vm.config.memoryMB,
        cpuCount: vm.config.cpuCount,
        accelMode: this.kvmAvailable ? 'kvm' : 'tcg',
        displayMode: displayMode,
        nographic: nographic,
        efiFirmware: firmware as string,
        qemuDataDir: qemuDataDir || undefined,
        keymapsAvailable: keymapsAvailable,
        // 缺少 keymaps 时，强制禁用显示设备
        displayDevice: (!keymapsAvailable && bootMode !== 'debug') ? 'none' : effectiveDisplayDevice,
        // 将高级硬件配置下传到 Native 层
        machine: vm.config.machine,
        networkDevice: vm.config.networkDevice,
        audioDevice: vm.config.audioDevice
      } as ManagerVMConfig
      
      hilog.info(0x0000, 'INDEX', '>>> 调用 manager.startVM <<<')
      const result = await manager.startVM(config)
      hilog.info(0x0000, 'INDEX', 'startVM 返回: success=%{public}s, message=%{public}s', 
        String(result.success), result.message || '(无消息)')
      if (result.success) {
        vm.status = 'running'
        this.vms = [...this.vms]
        
        // 根据启动模式在新窗口中打开对应界面
        switch (bootMode) {
          case 'standard':
          case 'install':
            // 普通启动/安装：在新窗口打开 VNC
            hilog.info(0x0000, 'INDEX', '>>> 准备打开 VNC 窗口 (install 模式) <<<')
            this.openVNCWindow(vm)
            break
          case 'debug':
            // 调试模式：在新窗口打开串口控制台
            this.openConsoleWindow(vm)
            break
        }
        } else {
        vm.status = 'failed'
        this.vms = [...this.vms]
        this.errorMessage = result.message || '启动失败'
      }
    } catch (e) {
      hilog.error(0x0000, 'INDEX', '>>> startVM 异常: %{public}s <<<', (e as Error).message)
      vm.status = 'failed'
      this.vms = [...this.vms]
      this.errorMessage = (e as Error).message
    } finally {
      this.isLoading = false
      this.startTargetVM = null
      await this.saveAllVMs()
      hilog.info(0x0000, 'INDEX', '>>> startVM 结束 <<<')
    }
  }

  private async stopVM(vm: VMMeta): Promise<void> {
    try {
      this.isLoading = true; vm.status = 'stopping'
      this.vms = [...this.vms]
      const r = await QemuVMManager.getInstance().stopVM(vm.name)
      if (r.success) {
        vm.status = 'stopped'
        this.vms = [...this.vms]
      } else {
        // 停止失败时不要假装已关机，尽量恢复真实状态
        let live = ''
        try {
          if (qemuModule?.getVmStatus) live = String(qemuModule.getVmStatus(vm.name))
        } catch (_) {
          live = ''
        }
        // 兼容 native 可能返回的 shutdown
        if (live === 'shutdown') live = 'stopped'
        const allowed: VMStatus[] = ['creating', 'preparing', 'starting', 'running', 'stopping', 'stopped', 'failed', 'paused', 'backup']
        if (allowed.includes(live as VMStatus)) vm.status = live as VMStatus
        else vm.status = 'failed'
        this.vms = [...this.vms]
        this.errorMessage = r.message || '关闭虚拟机失败'
        promptAction.showToast({ message: this.errorMessage, duration: 3000 })
      }
    } catch (e) { this.errorMessage = (e as Error).message }
    finally { this.isLoading = false; await this.saveAllVMs() }
  }

  private async deleteVM(vm: VMMeta): Promise<void> {
    if (vm.status === 'running') {
      this.errorMessage = '请先停止虚拟机'
      return
    }

    // 确认对话框
    const result = await promptAction.showDialog({
      title: '确认删除',
      message: `确定要删除虚拟机 "${vm.name}" 吗？此操作不可撤销。`,
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF3B30' }
      ]
    })

    if (result.index !== 1) {
      return
    }

    try {
      this.isLoading = true

      // 删除磁盘等文件（内部目录）
      const vmDir = StoragePaths.getVmDir(vm.name)
      const files = ['disk.qcow2', 'qemu.log', 'vm_config.json', 'vm_status.txt', 'vmPerfence.json']
      for (const f of files) {
        const p = `${vmDir}/${f}`
        try {
          await fs.unlink(p)
        } catch (_) {
          // 文件可能不存在，忽略
        }
      }
      try {
        await fs.rmdir(vmDir)
      } catch (_) {
        // 目录可能非空或已删，忽略
      }

      // 从内存列表移除
    this.vms = this.vms.filter((v: VMMeta): boolean => v.id !== vm.id)
      if (this.selectedVmId === vm.id) {
        this.selectedVmId = this.vms.length > 0 ? this.vms[0].id : ''
      }
      await this.saveAllVMs()
    } catch (e) {
      this.errorMessage = `删除失败: ${(e as Error).message}`
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 在新窗口中打开 VNC 显示
   */
  private openVNCWindow(vm: VMMeta): void {
    const ctx = getContext(this) as common.UIAbilityContext
    
    const vncPort = this.settingsVncNativePort
    hilog.info(0x0000, 'INDEX', 'VNC(原生) 端口: %{public}d', vncPort)
    
    // 统一使用新窗口方式打开（原生 VNC）
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: 'VNCWindowAbility',
      parameters: {
        vmName: vm.name,
        vmId: vm.id,
        vncHost: '127.0.0.1',
        vncPort: vncPort
      }
    }
    ctx.startAbility(want).then(() => {
      hilog.info(0x0000, 'INDEX', 'VNC 窗口启动成功: %{public}s', vm.name)
    }).catch((err: Error) => {
      hilog.error(0x0000, 'INDEX', 'VNC 窗口启动失败: %{public}s', err.message)
      this.errorMessage = `无法打开 VNC 窗口: ${err.message}`
    })
  }

  /**
   * 在新窗口中打开串口控制台
   */
  private openConsoleWindow(vm: VMMeta): void {
    const ctx = getContext(this) as common.UIAbilityContext
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: 'ConsoleWindowAbility',
      parameters: {
        vmName: vm.name,
        vmId: vm.id
      }
    }
    ctx.startAbility(want).then(() => {
      hilog.info(0x0000, 'INDEX', '串口控制台窗口启动成功: %{public}s', vm.name)
    }).catch((err: Error) => {
      hilog.error(0x0000, 'INDEX', '串口控制台窗口启动失败: %{public}s', err.message)
      this.errorMessage = `无法打开控制台窗口: ${err.message}`
    })
  }

  private async saveAllVMs(): Promise<void> {
    if (!this.store) return
    const list: VMMetaPersist[] = this.vms.map((vm: VMMeta): VMMetaPersist => {
      const cfgPersist: VMConfigPersistExt = {
        name: vm.config.name,
        osType: vm.config.osType,
        diskSizeGB: vm.config.diskSizeGB,
        memoryMB: vm.config.memoryMB,
        cpuCount: vm.config.cpuCount,
        isoPath: vm.config.isoPath,
        archType: vm.config.archType as ('aarch64' | 'x86_64' | 'i386') | undefined,
        machine: vm.config.machine,
        displayDevice: vm.config.displayDevice,
        networkDevice: vm.config.networkDevice,
        audioDevice: vm.config.audioDevice
      }

      return {
        id: vm.id,
        name: vm.name,
        osType: vm.osType,
        status: vm.status,
        createdAt: vm.createdAt,
        config: cfgPersist
      }
    })
    await this.store.saveAll(list)
  }

  private getSelectedVM(): VMMeta | undefined {
    return this.vms.find((vm: VMMeta): boolean => vm.id === this.selectedVmId)
  }

  // 获取过滤后的 VM 列表（根据搜索关键字）
  private getFilteredVMs(): VMMeta[] {
    if (!this.searchKeyword || this.windowMode === 'floating') {
      return this.vms
    }
    const keyword = this.searchKeyword.toLowerCase()
    return this.vms.filter((vm: VMMeta): boolean => vm.name.toLowerCase().includes(keyword))
  }

  // ========== 向导内容 ==========
  @Builder WizardContent() {
    Column() {
      // 标题栏
      Row() {
        Text(this.getWizardTitle()).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          .onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 20 })

      // 内容区（可滚动）
      Scroll() {
        Column() {
          if (this.wizardStep === 'mode') {
            this.WizardModeStep()
          } else if (this.wizardStep === 'kvm_unavailable') {
            this.WizardKvmUnavailable()
          } else if (this.wizardStep === 'machine') {
            this.WizardMachineStep()
          } else if (this.wizardStep === 'arch') {
            this.WizardArchStep()
          } else if (this.wizardStep === 'os') {
            this.WizardOSStep()
          } else if (this.wizardStep === 'config') {
            this.WizardConfigStep()
          } else if (this.wizardStep === 'done') {
            this.WizardDoneStep()
          }
        }.width('100%')
      }.scrollBar(BarState.Auto)
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 32 })
  }

  private getWizardTitle(): string {
    return '创建向导'
  }

  // 选择模式 - KVM 或 TCG
  @Builder WizardModeStep() {
          Column() {
      Text('请问你要做什么虚拟机？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      // KVM 模式
            Row() {
              Column() {
                Row() {
            SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(20).fontColor([$r('app.color.accent')]).margin({ right: 12 })
            Text('KVM 模式').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width('100%')
        }.layoutWeight(1)
      }
      .width('100%').padding(16)
      .backgroundColor($r('app.color.sidebar_background'))
      .borderRadius(12).margin({ bottom: 8 })
      .onClick((): void => { this.wizardMode = 'kvm'; this.wizardNext() })

      // KVM 不可用提示（显示在卡片下方）
      if (!this.kvmAvailable) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(14).fontColor(['#FF9500']).margin({ right: 6 })
          Text('KVM 暂时不可用').fontSize(12).fontColor($r('app.color.text_tertiary'))
          Text('查看详情').fontSize(12).fontColor($r('app.color.accent')).margin({ left: 4 })
            .onClick((): void => { this.currentSheet = 'kvmDetail'; this.sheetVisible = true })
        }.width('100%').margin({ left: 16, bottom: 12 })
      }

      // 模拟模式 (TCG)
      Row() {
    Column() {
      Row() {
            SymbolGlyph($r('sys.symbol.display')).fontSize(20).fontColor([$r('app.color.accent')]).margin({ right: 12 })
            Text('模拟一台机器').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width('100%')
        }.layoutWeight(1)
      }
      .width('100%').padding(16)
      .backgroundColor($r('app.color.sidebar_background'))
      .borderRadius(12)
      .onClick((): void => { this.wizardMode = 'tcg'; this.wizardNext() })
    }.width('100%')
  }

  // KVM 不可用提示
  @Builder WizardKvmUnavailable() {
    Column() {
      Image($r('app.media.illust_access_denied'))
        .width(180)
        .height(135)
        .objectFit(ImageFit.Contain)
        .margin({ top: 24, bottom: 16 })
      Text('KVM 不可用').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).margin({ bottom: 12 })
      Text('华为限制我们使用 KVM 功能\n我们正在与其交涉并试图解锁此限制')
        .fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center).lineHeight(22).margin({ bottom: 32 })
      Button('我知道了').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.accent'))
        .onClick((): void => { this.wizardBack() })
    }.width('100%').alignItems(HorizontalAlign.Center)
  }

  // 选择机器类型 - 动态从 supportedMachines 获取
  @Builder WizardMachineStep() {
                    Column() {
      Text('你想模拟什么机器？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      ForEach(this.supportedMachines, (machine: MachineOption) => {
                      Row() {
                        Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.display')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Text(machine.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
            }.width('100%')
            Text(machine.desc).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 4, left: 36 })
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.sidebar_background'))
        .borderRadius(12).margin({ bottom: 12 })
        .onClick((): void => {
          this.wizardMachine = machine.id
          this.wizardNext()
        })
      })

      Blank()
      Button('返回').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ top: 20 })
        .onClick((): void => { this.wizardBack() })
    }.width('100%').height('100%')
  }

  // 选择架构 - 只显示支持的架构
  @Builder WizardArchStep() {
    Column() {
      Text('请选择您的 CPU 所基于的架构').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      // 只显示支持的架构（ARM64）
      ForEach(this.supportedArchs.filter((a: ArchOption): boolean => a.supported), (arch: ArchOption) => {
                      Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Text(arch.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.sidebar_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick((): void => {
          this.wizardArch = arch.id
          this.wizardNext()
        })
      })

      // x86_64 不可用提示（使用 popup）
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(14).fontColor(['#FF9500']).margin({ right: 6 })
        Text('x86_64 在此构建不可用').fontSize(12).fontColor($r('app.color.text_tertiary'))
        Text('查看详情').fontSize(12).fontColor($r('app.color.accent')).margin({ left: 4 })
          .bindPopup(this.showX86Popup, {
            builder: this.X86PopupBuilder(),
            placement: Placement.Top,
            popupColor: $r('app.color.card_background'),
            enableArrow: true,
            onStateChange: (e): void => {
              if (!e.isVisible) this.showX86Popup = false
            }
          })
          .onClick((): void => { this.showX86Popup = true })
      }.width('100%').margin({ left: 16, top: 8 })

      Blank()
      Button('返回').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ top: 20 })
        .onClick((): void => { this.wizardBack() })
    }.width('100%').height('100%')
  }

  // x86_64 不可用 Popup 内容
  @Builder X86PopupBuilder() {
          Column() {
      Text('您没有给这个 App 编译 ARM 到 x86_64 的 QEMU 库').fontSize(14).fontColor($r('app.color.text_primary')).margin({ bottom: 8 })
      Text('您可能需要等别人编译好，或者自己动手编译').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ bottom: 16 })
      Button('我知道了').type(ButtonType.Capsule).width('100%').height(36).backgroundColor($r('app.color.accent'))
        .onClick((): void => { this.showX86Popup = false })
    }.width(280).padding(16)
  }

  // 选择系统 - Windows / Linux
  @Builder WizardOSStep() {
            Column() {
      Text('请选择要运行的系统').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      ForEach(this.supportedOS.filter((os: OSOption): boolean => os.arch === this.wizardArch), (os: OSOption) => {
              Row() {
          SymbolGlyph($r(os.id === 'Windows' ? 'sys.symbol.rectangle_on_rectangle' : 'sys.symbol.terminal')).fontSize(20).fontColor([$r('app.color.accent')]).margin({ right: 12 })
          Text(os.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.sidebar_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick((): void => {
          this.wizardOS = os.id
          this.wizardNext()
        })
      })

      Blank()
      Button('返回').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ top: 20 })
        .onClick((): void => { this.wizardBack() })
    }.width('100%').height('100%')
  }

  // 步骤4: 配置资源
  @Builder WizardConfigStep() {
                Column() {
      // 虚拟机名称
      Column() {
        Text('虚拟机名称').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
        TextInput({ text: this.wizardName, placeholder: `${this.wizardOS} VM` })
          .height(40)
          .backgroundColor($r('app.color.sidebar_background'))
          .fontColor($r('app.color.text_primary'))
          .onChange((val: string): void => { this.wizardName = val })
      }.width('100%').margin({ bottom: 20 })

      Text('系统需要多大内存').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      // RAM 大小
                Column() {
        Row() {
          Text('RAM 大小').fontSize(13).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(`${(this.wizardMemory / 1024).toFixed(0)} GB`).fontSize(13).fontColor($r('app.color.text_primary'))
        }.width('100%').margin({ bottom: 8 })
        Row() {
          Slider({ value: this.wizardMemory, min: 1024, max: 16384, step: 1024 }).layoutWeight(1)
            .onChange((v: number): void => { this.wizardMemory = v })
          Button('随机').type(ButtonType.Capsule).height(32).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ left: 8 })
            .onClick((): void => { this.wizardMemory = Math.floor(Math.random() * 8 + 2) * 1024 })
        }.width('100%')
      }.width('100%').margin({ bottom: 20 })

      // 硬盘大小
      Column() {
        Row() {
          Text('硬盘大小').fontSize(13).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(`${this.wizardDisk} GB`).fontSize(13).fontColor($r('app.color.text_primary'))
        }.width('100%').margin({ bottom: 8 })
        Row() {
          Slider({ value: this.wizardDisk, min: 16, max: 256, step: 8 }).layoutWeight(1)
            .onChange((v: number): void => { this.wizardDisk = v })
          Button('随机').type(ButtonType.Capsule).height(32).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ left: 8 })
            .onClick((): void => { this.wizardDisk = Math.floor(Math.random() * 16 + 4) * 8 })
        }.width('100%')
      }.width('100%').margin({ bottom: 16 })

      // 不想新增虚拟盘
      Row() {
        Checkbox().select(this.wizardNoDisk).onChange((v: boolean): void => { this.wizardNoDisk = v })
        Text('不想新增虚拟盘').fontSize(14).fontColor($r('app.color.text_primary')).margin({ left: 8 })
      }.width('100%').margin({ bottom: 20 })

      // 可选：导入现有 QEMU 磁盘镜像
      Column() {
        Text('导入现有 QEMU 磁盘镜像 (qcow2/raw，可选)').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
        Row() {
          Text(this.wizardImportedDiskPath ? this.wizardImportedDiskPath.split('/').pop() || '已选择' : '未选择磁盘镜像')
            .fontSize(14)
            .fontColor(this.wizardImportedDiskPath ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('选择').type(ButtonType.Capsule).height(32).backgroundColor($r('app.color.sidebar_background'))
            .fontColor($r('app.color.text_primary'))
            .onClick((): void => { this.selectDiskImage() })
        }.width('100%').height(44).padding({ left: 12, right: 8 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10)
      }.width('100%').margin({ bottom: 20 }).alignItems(HorizontalAlign.Start)

      // ISO 选择
          Column() {
        Text('安装镜像 (ISO)').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
        Row() {
          Text(this.wizardISOPath ? this.wizardISOPath.split('/').pop() || '已选择' : '未选择镜像')
            .fontSize(14).fontColor(this.wizardISOPath ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('选择').type(ButtonType.Capsule).height(32).backgroundColor($r('app.color.accent'))
            .onClick((): void => { this.selectISO() })
        }.width('100%').height(44).padding({ left: 12, right: 8 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10)
      }.width('100%').alignItems(HorizontalAlign.Start)

      Blank()
              Row() {
        Button('返回').type(ButtonType.Capsule).height(40).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).layoutWeight(1).margin({ right: 8 })
          .onClick((): void => { this.wizardBack() })
        Button('下一步').type(ButtonType.Capsule).height(40).backgroundColor($r('app.color.accent')).layoutWeight(1)
          .onClick((): void => { this.wizardNext() })
      }.width('100%').margin({ top: 20 })
    }.width('100%').height('100%')
  }

  // 步骤5: 完成
  @Builder WizardDoneStep() {
          Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(64).fontColor(['#34C759']).margin({ top: 40, bottom: 20 })
      Text('您创建好了所有准备').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text('现在启动吧！').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 8, bottom: 40 })

      // 配置摘要
            Column() {
        Row() { Text('模式').fontSize(13).fontColor($r('app.color.text_tertiary')); Blank(); Text(this.wizardMode === 'kvm' ? 'KVM' : 'TCG').fontSize(13).fontColor($r('app.color.text_primary')) }.width('100%').margin({ bottom: 8 })
        Row() { Text('架构').fontSize(13).fontColor($r('app.color.text_tertiary')); Blank(); Text(this.wizardArch).fontSize(13).fontColor($r('app.color.text_primary')) }.width('100%').margin({ bottom: 8 })
        Row() { Text('系统').fontSize(13).fontColor($r('app.color.text_tertiary')); Blank(); Text(this.wizardOS).fontSize(13).fontColor($r('app.color.text_primary')) }.width('100%').margin({ bottom: 8 })
        Row() { Text('内存').fontSize(13).fontColor($r('app.color.text_tertiary')); Blank(); Text(`${(this.wizardMemory / 1024).toFixed(0)} GB`).fontSize(13).fontColor($r('app.color.text_primary')) }.width('100%').margin({ bottom: 8 })
        if (!this.wizardNoDisk) {
          Row() { Text('硬盘').fontSize(13).fontColor($r('app.color.text_tertiary')); Blank(); Text(`${this.wizardDisk} GB`).fontSize(13).fontColor($r('app.color.text_primary')) }.width('100%')
        }
      }.width('100%').padding(16).backgroundColor($r('app.color.sidebar_background')).borderRadius(12)

      Blank()
              Row() {
        Button('返回').type(ButtonType.Capsule).height(40).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).layoutWeight(1).margin({ right: 8 })
          .onClick((): void => { this.wizardBack() })
        Button('启动!').type(ButtonType.Capsule).height(40).backgroundColor('#34C759').layoutWeight(1)
          .onClick((): void => { this.wizardNext() })
      }.width('100%').margin({ top: 20 })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Center)
  }

  // ========== 其他 Sheet 内容 ==========
  @Builder StatusContent() {
                Column() {
            Row() {
        Text('系统状态').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')]).onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 16 })
      
      Column() { Text(this.testResult).fontSize(14).fontColor($r('app.color.text_secondary')).width('100%') }.padding(16).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).width('100%')
      if (this.errorMessage) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(16).fontColor(['#EF4444']).margin({ right: 8 })
          Text(this.errorMessage).fontSize(13).fontColor('#EF4444').layoutWeight(1)
        }.width('100%').padding(16).backgroundColor('#3C1414').borderRadius(12).margin({ top: 12 })
      }
      Button('重新检测').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.accent')).margin({ top: 20 })
        .onClick((): void => { this.testQemuFunctions() })
    }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  @Builder StartModeContent() {
    Column() {
            Row() {
        Text('启动模式').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')]).onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 8 })

      Text('选择虚拟机的启动方式').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })

      // ========== 安装模式 ==========
      Button('📀 安装模式')
        .type(ButtonType.Capsule)
        .width('100%').height(48)
        .backgroundColor(!this.keymapsAvailable ? $r('app.color.sidebar_background') : '#34C759')
        .fontColor(!this.keymapsAvailable ? $r('app.color.text_tertiary') : Color.White)
        .enabled(this.keymapsAvailable)
        .margin({ bottom: 8 })
        .onClick((): void => {
          hilog.info(0x0000, 'INDEX', '>>> 安装模式按钮点击 keymapsAvailable=%{public}s startTargetVM=%{public}s <<<',
            String(this.keymapsAvailable), this.startTargetVM?.id || '(null)')
          if (this.keymapsAvailable && this.startTargetVM) {
            this.startVM(this.startTargetVM, 'install')
          }
        })
      Text(!this.keymapsAvailable ? '缺少 keymaps，无法使用 VNC 安装模式' : '使用 VNC 进行系统安装，适合首次安装操作系统')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 16 })
        .width('100%')

      // ========== 普通启动 ==========
      Button('🖥️ 普通启动 (VNC)')
        .type(ButtonType.Capsule)
        .width('100%').height(48)
        .backgroundColor(!this.keymapsAvailable ? $r('app.color.sidebar_background') : '#FF9500')
        .fontColor(!this.keymapsAvailable ? $r('app.color.text_tertiary') : Color.White)
        .enabled(this.keymapsAvailable)
        .margin({ bottom: 8 })
        .onClick((): void => {
          hilog.info(0x0000, 'INDEX', '>>> 普通启动按钮点击 <<<')
          if (this.keymapsAvailable && this.startTargetVM) {
            this.startVM(this.startTargetVM, 'standard')
          }
        })
      Text(!this.keymapsAvailable ? '缺少 keymaps，无法使用 VNC 图形模式' : '使用 VNC 显示，适合 macOS 及不支持 RDP 的系统')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 16 })
        .width('100%')

      // ========== 调试模式 ==========
      Button('🔧 调试模式 (串口)').type(ButtonType.Capsule).width('100%').height(48)
        .backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ bottom: 8 })
        .onClick((): void => { if (this.startTargetVM) this.startVM(this.startTargetVM, 'debug') })
      Text('无图形界面，仅通过串口 TTL 终端操作')
        .fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ bottom: 20 }).width('100%')

      // ========== 取消 ==========
      Button('取消').type(ButtonType.Capsule).width('100%').height(44)
        .backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_secondary'))
        .onClick((): void => { this.closeSheet(); this.startTargetVM = null })
    }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  // ========== 紧凑模式 VM 列表 ==========
  @Builder CompactVmList() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('虚拟机').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Blank()
        Button() {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([$r('app.color.accent')])
        }
        .type(ButtonType.Circle)
        .width(36)
        .height(36)
        .backgroundColor($r('app.color.sidebar_background'))
        .onClick((): void => { this.openWizard() })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
      
      // VM 列表
      if (this.vms.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(64).fontColor([$r('app.color.text_tertiary')]).margin({ bottom: 16 })
          Text('还没有虚拟机').fontSize(18).fontColor($r('app.color.text_tertiary'))
          Text('点击右上角 + 创建').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 8 })
        }.layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.vms, (vm: VMMeta) => {
            ListItem() {
              this.VMCard(vm, this.selectedVmId === vm.id)
              }
              .onClick((): void => {
                this.selectedVmId = vm.id
              // 在紧凑模式下，打开启动模式选择
              this.startTargetVM = vm
              this.openSheet('startMode')
              })
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }
  
  // ========== VM 卡片 Builder ==========
  @Builder VMCard(vm: VMMeta, isSelected: boolean = false) {
    Stack() {
      // 背景层：运行中显示模糊截图，关机显示默认背景
      if (vm.status === 'running' && vm.previewPath) {
        Image(vm.previewPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(20)
          .opacity(0.4)
      }
      
      // 渐变遮罩（从下往上变暗）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.6)', 1]]
        })
      
      // 内容层
      Column() {
        // 顶部：右上角状态标识
              Row() {
          Blank()
          // 状态徽章
          Row() {
            Circle()
              .width(6)
              .height(6)
              .fill(vm.status === 'running' ? '#34C759' : 
                    vm.status === 'paused' ? '#FF9500' : 
                    vm.status === 'backup' ? '#5856D6' :
                    vm.status === 'starting' || vm.status === 'stopping' ? '#007AFF' :
                    '#8E8E93')
              .margin({ right: 4 })
            Text(getStatusDisplayName(vm.status))
              .fontSize(10)
              .fontColor(Color.White)
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(vm.status === 'running' ? 'rgba(52,199,89,0.3)' :
                          vm.status === 'paused' ? 'rgba(255,149,0,0.3)' :
                          'rgba(0,0,0,0.5)')
          .borderRadius(10)
        }.width('100%')
        
        Blank()
        
        // 底部信息区
        Row() {
          // 左侧：系统图标 + 虚拟机信息
                Column() {
                  Row() {
              // 系统图标
              Image(getOsIcon(vm.osType))
                .width(20)
                .height(20)
                .fillColor(Color.White)
                .margin({ right: 8 })
              // 虚拟机名称
              Text(vm.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            
            // 架构 · 状态
            Row() {
              Text(getArchDisplayName(vm.config.archType))
                .fontSize(11)
                .fontColor('rgba(255,255,255,0.7)')
              Text(' · ')
                .fontSize(11)
                .fontColor('rgba(255,255,255,0.5)')
              Text(getStatusDisplayName(vm.status))
                .fontSize(11)
                .fontColor(vm.status === 'running' ? '#34C759' :
                          vm.status === 'paused' ? '#FF9500' :
                          vm.status === 'backup' ? '#5856D6' :
                          'rgba(255,255,255,0.7)')
                  }.margin({ top: 4 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                
          // 右侧：RAM + 硬盘
          Column() {
            Text(`${Math.round(vm.config.memoryMB / 1024)}+${vm.config.diskSizeGB}`)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Text('GB')
              .fontSize(10)
              .fontColor('rgba(255,255,255,0.6)')
              .margin({ top: 2 })
          }.alignItems(HorizontalAlign.End)
        }.width('100%')
        
        // Guest Agent 应用图标（如果有）
        if (vm.hasGuestAgent && vm.runningApps.length > 0) {
          Row() {
            Blank()
            // 叠放的应用图标
            Stack() {
              ForEach(vm.runningApps.slice(0, 3), (app: string, index: number) => {
                Row()
                  .width(16)
                  .height(16)
                  .backgroundColor('#007AFF')
                  .borderRadius(4)
                  .border({ width: 1, color: 'rgba(255,255,255,0.3)' })
                  .position({ right: index * 10, top: 0 })
              })
            }.width(36).height(16)
          }.width('100%').margin({ top: 8 })
        }

        // 右下角更多操作按钮（右键菜单：重命名 / 设置 / 删除）
        Row() {
          Blank()
          Button() {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2'))
              .fontSize(14)
              .fontColor(['rgba(255,255,255,0.9)'])
          }
          .type(ButtonType.Circle)
          .width(28)
          .height(28)
          .backgroundColor('rgba(0,0,0,0.45)')
          .bindMenu([
            {
              value: '重命名',
              action: (): void => {
                this.renameVM(vm)
              }
            },
            {
              value: '虚拟机设置',
              action: (): void => {
                this.selectedVmId = vm.id
                this.openSheet('vmSettings')
              }
            },
            {
              value: '删除虚拟机',
              action: (): void => {
                this.selectedVmId = vm.id
                this.deleteVM(vm)
            }
            }
          ])
        }
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
      .padding(12)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .height(120)
    .backgroundColor(isSelected ? '#2C2C2E' : '#1C1C1E')
    .borderRadius(12)
    .border({ width: isSelected ? 2 : 0, color: $r('app.color.accent') })
    .clip(true)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.3)', offsetY: 2 })
  }

  private async renameVM(vm: VMMeta): Promise<void> {
    if (vm.status === 'running') {
      this.errorMessage = '请先停止虚拟机再重命名'
      return
    }

    const accentColor: string = String($r('app.color.accent'))

    const result = await promptAction.showDialog({
      title: '重命名虚拟机',
      message: `请输入新的名称（当前：${vm.name}）`,
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确定', color: accentColor }
      ]
      // ArkTS 当前的 showDialog 不支持内置编辑框，这里仅保留占位逻辑：
      // 真实重命名入口建议放到「虚拟机设置」里做完整表单。
    })

    if (result.index !== 1) {
      return
    }

    // 这里暂时使用原名称，避免类型错误；后续可以改成从设置页输入的新名称
    const newName = vm.name.trim()
    if (!newName || newName === vm.name) {
      return
    }

    // 由于当前对话框未提供编辑结果，这里暂不真正修改名称，后续在设置页中实现完整重命名流程
  }
  
  // ========== Apps 页面（共用）==========
  @Builder AppsPage() {
    Column() {
      // 标题靠左
      Text('应用').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .width('100%').margin({ top: 16, left: 24 })
      
      // 内容区域居中
      Column() {
        Image($r('app.media.illust_under_construction'))
          .width(240)
          .height(180)
          .objectFit(ImageFit.Contain)
        Text('功能开发中').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).margin({ top: 20 })
        Text('我们正在努力构建更多功能，敬请期待！').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)  // 外层靠左，让标题自然靠左
  }
  
  // ========== 我的页面（共用）==========
  @Builder MyPage() {
    Scroll() {
      Column() {
        // 标题
        Text('我的').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .width('100%').margin({ bottom: 16 })

        // 实用工具
        Column() {
          Text('实用工具').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 16 }).width('100%')
          Row() {
            Column() {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(28).fontColor([$r('app.color.accent')]).margin({ bottom: 8 })
              Text('设备能力').fontSize(13).fontColor($r('app.color.text_primary'))
              Text('JIT/KVM检测').fontSize(11).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Center).onClick((): void => { this.openSheet('status') })
            
            Column() {
              SymbolGlyph($r('sys.symbol.doc_text')).fontSize(28).fontColor(['#FF9500']).margin({ bottom: 8 })
              Text('日志查看').fontSize(13).fontColor($r('app.color.text_primary'))
              Text('导出诊断日志').fontSize(11).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Center).onClick((): void => { this.exportLogs() })
            
            Column() {
              SymbolGlyph($r('sys.symbol.folder')).fontSize(28).fontColor(['#34C759']).margin({ bottom: 8 })
              Text('ISO 管理').fontSize(13).fontColor($r('app.color.text_primary'))
              Text('镜像文件管理').fontSize(11).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Center)
          }.width('100%')
        }.padding(20).backgroundColor($r('app.color.card_background')).borderRadius(16).margin({ bottom: 16 })

        // 设置
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
            Text('设置').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width('100%').height(52).padding({ left: 16, right: 16 }).backgroundColor($r('app.color.card_background')).borderRadius(16)
          .onClick((): void => { this.openSheet('settings') })
        }.width('100%').margin({ bottom: 16 })

        // 关于
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
            Text('关于').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Text('v1.0.0').fontSize(13).fontColor($r('app.color.text_tertiary'))
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')]).margin({ left: 8 })
          }.width('100%').height(52).padding({ left: 16, right: 16 }).backgroundColor($r('app.color.card_background')).borderRadius(16)
        }.width('100%')
        
      }.width('100%').padding({ left: 24, right: 24, top: 16 }).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)  // 内容从顶部开始
  }

  // ========== 左侧 TabBar（展开模式）==========
  @Builder LeftTabBar() {
    Column() {
      Column() {
        SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(24).fontColor([this.currentTab === 0 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('虚拟机').fontSize(10).fontColor(this.currentTab === 0 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 4 })
      }.width('100%').height(64).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).onClick((): void => {
        this.currentTab = 0
        // 非自由多窗模式下，点击虚拟机 Tab 展开侧边栏
        if (this.windowMode !== 'floating') {
          this.showSidebar = true
        }
      })

      Column() {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(24).fontColor([this.currentTab === 1 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('Apps').fontSize(10).fontColor(this.currentTab === 1 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 4 })
      }.width('100%').height(64).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).onClick((): void => { this.currentTab = 1 })

      Column() {
        SymbolGlyph($r('sys.symbol.person')).fontSize(24).fontColor([this.currentTab === 2 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('我的').fontSize(10).fontColor(this.currentTab === 2 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 4 })
      }.width('100%').height(64).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).onClick((): void => { this.currentTab = 2 })

      Blank()
    }.width(68).height('100%').backgroundColor($r('app.color.sidebar_background')).padding({ top: this.showCustomTitleBar ? 8 : 48 })
  }
  
  // ========== 底部 TabBar（紧凑模式）==========
  @Builder BottomTabBar() {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(22).fontColor([this.currentTab === 0 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('虚拟机').fontSize(10).fontColor(this.currentTab === 0 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 2 })
      }.layoutWeight(1).height('100%').justifyContent(FlexAlign.Center).onClick((): void => { this.currentTab = 0 })

      Column() {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(22).fontColor([this.currentTab === 1 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('Apps').fontSize(10).fontColor(this.currentTab === 1 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 2 })
      }.layoutWeight(1).height('100%').justifyContent(FlexAlign.Center).onClick((): void => { this.currentTab = 1 })

      Column() {
        SymbolGlyph($r('sys.symbol.person')).fontSize(22).fontColor([this.currentTab === 2 ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        Text('我的').fontSize(10).fontColor(this.currentTab === 2 ? $r('app.color.accent') : $r('app.color.text_tertiary')).margin({ top: 2 })
      }.layoutWeight(1).height('100%').justifyContent(FlexAlign.Center).onClick((): void => { this.currentTab = 2 })
    }
    .width('100%')
    .height(56)
    .backgroundColor($r('app.color.sidebar_background'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  // ========== 主界面 ==========
  build() {
    Stack() {
      Column() {
        // 悬浮窗/自由多窗顶部控制条避让
        if (this.isCompact && this.safeAreaTop > 0) {
          Row().height(this.safeAreaTop).width('100%')
        }

        // 自定义标题栏（仅在自由多窗/分屏模式下显示）
        // 自定义标题栏（自由多窗模式下不显示窗口控制按钮，系统已提供）
        if (this.showCustomTitleBar) {
          CustomTitleBar({
            windowTitle: 'Aether Engine',
            showSearch: true,
            showWindowControls: this.windowMode === 'split',  // 分屏显示控制键，浮窗用系统键
            onSearchClick: (): void => { this.showCommandPalette = true }
          })
        }
        
        // 根据断点选择布局
        if (this.isCompact) {
          // ========== 紧凑模式：主内容 + 底部 TabBar ==========
          Column() {
            // 紧凑模式下的主内容（简化版）
            if (this.currentTab === 0) {
              // VM 列表（紧凑版）
              this.CompactVmList()
            } else if (this.currentTab === 1) {
              // Apps 页面
              this.AppsPage()
            } else {
              // 我的页面
              this.MyPage()
            }
          }.layoutWeight(1).width('100%').backgroundColor($r('app.color.page_background'))
          
          this.BottomTabBar()
        } else {
          // ========== 展开模式：左侧 TabBar + 主内容 ==========
          Row() {
            this.LeftTabBar()
            Divider().vertical(true).color($r('app.color.divider'))

            // 主内容区
            if (this.currentTab === 0) {
            Row() {
            // VM 列表侧边栏
            if (this.showSidebar) {
            Column() {
                Row() {
                  SymbolGlyph($r('sys.symbol.list_bullet'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_secondary')])
                    .onClick((): void => { this.showSidebar = false })
                }.width('100%').height(44).justifyContent(FlexAlign.Start)
              // 搜索框（窗口宽度 >= 1153vp 时显示）
              if (this.windowWidth >= 1153) {
            Row() {
                SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(16).fontColor([$r('app.color.text_tertiary')]).margin({ right: 8 })
                  if (this.windowMode !== 'floating') {
                    // 非自由多窗模式：可输入搜索框
                    TextInput({ text: this.searchKeyword, placeholder: '搜索虚拟机' })
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
                      .placeholderColor($r('app.color.text_tertiary'))
                      .backgroundColor(Color.Transparent)
                      .layoutWeight(1)
                      .height(36)
                      .onChange((value: string): void => { this.searchKeyword = value })
                  } else {
                    // 自由多窗模式：点击打开命令面板
                    Text('搜索').fontSize(14).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
                      .onClick((): void => { this.showCommandPalette = true })
                  }
              }.width('100%').height(36).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.card_background')).borderRadius(10).margin({ bottom: 16 })
              }

              List({ space: 8 }) {
                  ForEach(this.getFilteredVMs(), (vm: VMMeta) => {
                  ListItem() {
                    this.VMCard(vm, this.selectedVmId === vm.id)
                  }
                  .onClick((): void => { this.selectedVmId = vm.id })
                })
              }.width('100%').layoutWeight(1)

              Divider().color($r('app.color.divider')).margin({ top: 8, bottom: 8 })
              Row() { Text('添加列表').fontSize(14).fontColor($r('app.color.text_secondary')) }
                .width('100%').height(44).justifyContent(FlexAlign.Center)
                .onClick((): void => { this.openWizard() })
            }.width(280).height('100%').padding({ left: 12, right: 12, top: 16, bottom: 20 }).backgroundColor($r('app.color.sidebar_background'))

            Divider().vertical(true).color($r('app.color.divider'))
            }

            // VM 详情
            Column() {
              // 顶部工具栏：当侧边栏关闭时显示 open_sidebar 按钮
              if (!this.showSidebar) {
                Row() {
                  SymbolGlyph($r('sys.symbol.list_bullet'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_secondary')])
                    .onClick((): void => { this.showSidebar = true })
                  Blank()
                }
                .width('100%')
                .height(44)
                .padding({ left: 16, right: 16 })
              }
              if (this.vms.length === 0 || !this.getSelectedVM()) {
                Column() {
                  SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(64).fontColor([$r('app.color.text_tertiary')]).margin({ bottom: 16 })
                  Text('选择一个虚拟机').fontSize(20).fontColor($r('app.color.text_tertiary'))
                  Text('或点击"添加列表"创建新的').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 8 })
                  Button('创建第一个虚拟机').type(ButtonType.Capsule).height(44).backgroundColor($r('app.color.accent')).margin({ top: 24 })
                    .onClick((): void => { this.openWizard() })
                }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              } else {
                Scroll() {
                Column() {
                    // ========== 屏幕预览区域（始终显示，占大块区域）==========
                    Stack({ alignContent: Alignment.Center }) {
                      // 预览背景
        Column() {
                        if (this.getSelectedVM()!.status === 'running' && this.previewImagePath) {
                          // 运行中且有截图：显示截图
                          Image(this.previewImagePath)
                            .width('100%')
                            .height('100%')
                            .objectFit(ImageFit.Contain)
                        }
                      }
                      .width('100%')
                      .height('100%')
                      .backgroundColor('#0D0D0D')
                      .borderRadius(16)

                      // 未运行时的占位符：灰色 + 播放按钮
                      if (this.getSelectedVM()!.status !== 'running') {
                    Column() {
                          Button() {
                            SymbolGlyph($r('sys.symbol.play_fill')).fontSize(48).fontColor([Color.White])
                          }
                          .type(ButtonType.Circle)
                          .width(80)
                          .height(80)
                          .backgroundColor('rgba(52, 199, 89, 0.9)')
                          .shadow({ radius: 20, color: 'rgba(52, 199, 89, 0.5)', offsetX: 0, offsetY: 4 })
                          .onClick((): void => {
                            this.startTargetVM = this.getSelectedVM()!
                            this.openSheet('startMode')
                          })
                          
                          Text('点击启动虚拟机').fontSize(14).fontColor('#888888').margin({ top: 16 })
                            }
                      }
                      
                      // 运行中但无截图：加载状态
                      if (this.getSelectedVM()!.status === 'running' && !this.previewImagePath) {
                        Column() {
                        if (this.previewLoading) {
                            LoadingProgress().width(48).height(48).color('#007AFF')
                          } else {
                            SymbolGlyph($r('sys.symbol.display')).fontSize(48).fontColor(['#555555'])
                          }
                          Text(this.previewError || '正在获取屏幕...').fontSize(12).fontColor('#666666').margin({ top: 12 })
                        }
                        }
                        
                      // 刷新按钮（运行中时显示）
                      if (this.getSelectedVM()!.status === 'running') {
                        Button() {
                          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([Color.White])
                        }
                        .type(ButtonType.Circle)
                        .width(36)
                        .height(36)
                        .backgroundColor('rgba(0,0,0,0.6)')
                        .position({ right: 12, top: 12 })
                        .onClick((): void => { this.refreshPreview() })
                      }
                    }
                    .width('100%')
                    .height(this.getPreviewCardHeight())
                    .borderRadius(16)
                    .clip(true)
                    
                    // ========== VM 名称和状态 ==========
                    Column() {
                      Row() {
                        Column() {
                          Text(this.getSelectedVM()!.name).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
                          Row() {
                            Circle().width(8).height(8).fill(this.getSelectedVM()!.status === 'running' ? '#34C759' : '#888888').margin({ right: 8 })
                            Text(this.getSelectedVM()!.status === 'running' ? '运行中' : '已停止').fontSize(13).fontColor($r('app.color.text_secondary'))
                            Text(' · ').fontSize(13).fontColor($r('app.color.text_tertiary'))
                            Text(this.getSelectedVM()!.config.archType || 'aarch64').fontSize(13).fontColor($r('app.color.text_tertiary'))
                          }.margin({ top: 6 })
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      }.width('100%')
                      
                      // ========== 控制按钮组 ==========
                      Row() {
                        if (this.getSelectedVM()!.status === 'running') {
                          // 运行中：暂停 + 停止
                          Button() {
                            Row() {
                              SymbolGlyph($r('sys.symbol.pause_fill')).fontSize(18).fontColor([Color.White])
                              Text('暂停').fontSize(14).fontColor(Color.White).margin({ left: 6 })
                            }
                          }
                          .type(ButtonType.Capsule)
                          .height(44)
                          .layoutWeight(1)
                          .backgroundColor('#FF9500')
                          .onClick((): void => { /* TODO: 暂停功能 */ })
                          
                          Button() {
                            Row() {
                              SymbolGlyph($r('sys.symbol.xmark_circle')).fontSize(18).fontColor([Color.White])
                              Text('关闭虚拟机').fontSize(14).fontColor(Color.White).margin({ left: 6 })
                            }
                          }
                          .type(ButtonType.Capsule)
                          .height(44)
                          .layoutWeight(1)
                          .backgroundColor('#FF3B30')
                          .margin({ left: 12 })
                          .onClick((): void => { this.stopVM(this.getSelectedVM()!) })
                        } else {
                          // 已停止：启动
                          Button() {
                            Row() {
                              SymbolGlyph($r('sys.symbol.play_fill')).fontSize(18).fontColor([Color.White])
                              Text('启动虚拟机').fontSize(14).fontColor(Color.White).margin({ left: 6 })
                            }
                          }
                          .type(ButtonType.Capsule)
                          .height(44)
                          .width('100%')
                          .backgroundColor('#34C759')
                          .onClick((): void => {
                            this.startTargetVM = this.getSelectedVM()!
                            this.openSheet('startMode')
                          })
                        }
                      }.width('100%').margin({ top: 16 })
                    }.padding(20).backgroundColor($r('app.color.card_background')).borderRadius(16).margin({ top: 16, bottom: 16 })

                    // ========== 配置信息 ==========
                  Column() {
                    Text('配置信息').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 16 }).width('100%')
            Row() {
                        Column() {
                          Text('CPU').fontSize(12).fontColor($r('app.color.text_tertiary'))
                          Text(`${this.getSelectedVM()!.config.cpuCount} 核`).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).margin({ top: 4 })
                        }.layoutWeight(1)
                      Divider().vertical(true).height(40).color($r('app.color.divider'))
                        Column() {
                          Text('内存').fontSize(12).fontColor($r('app.color.text_tertiary'))
                          Text(`${(this.getSelectedVM()!.config.memoryMB / 1024).toFixed(0)} GB`).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).margin({ top: 4 })
                        }.layoutWeight(1)
                      Divider().vertical(true).height(40).color($r('app.color.divider'))
                        Column() {
                          Text('磁盘').fontSize(12).fontColor($r('app.color.text_tertiary'))
                          Text(`${this.getSelectedVM()!.config.diskSizeGB} GB`).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).margin({ top: 4 })
                        }.layoutWeight(1)
                    }.width('100%')
                    }.padding(20).backgroundColor($r('app.color.card_background')).borderRadius(16).margin({ bottom: 16 })
                    
                    // ========== 虚拟机设置 ==========
                    Column() {
                      // 设置入口
                      Row() {
                        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
                        Text('虚拟机设置').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
                        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
                      }
                      .width('100%')
                      .height(52)
                      .onClick((): void => { this.openSheet('vmSettings') })
                      
                      Divider().color($r('app.color.divider'))
                      
                      // 删除虚拟机
                      Row() {
                        SymbolGlyph($r('sys.symbol.trash')).fontSize(20).fontColor(['#FF3B30']).margin({ right: 12 })
                        Text('删除虚拟机').fontSize(15).fontColor('#FF3B30').layoutWeight(1)
                      }
                      .width('100%')
                      .height(52)
                      .onClick((): void => { this.deleteVM(this.getSelectedVM()!) })
                    }.padding({ left: 16, right: 16 }).backgroundColor($r('app.color.card_background')).borderRadius(16)
                    
                  }.width('100%').padding({ left: 24, right: 24, top: 16, bottom: 24 })
                }
                .width('100%')
                .height('100%')
                .scrollBar(BarState.Off)
              }
            }.layoutWeight(1).height('100%').backgroundColor($r('app.color.page_background'))
          }.layoutWeight(1).height('100%')
        } else if (this.currentTab === 1) {
          // ========== Apps 页面 ==========
          Column() {
            // 标题放在左上角
            Text('应用').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              .width('100%').margin({ top: 16, left: 24, bottom: 16 })
            
            // 开发中提示 - 内容居中显示
            Column() {
              Image($r('app.media.illust_under_construction')).width(160).height(160).objectFit(ImageFit.Contain).opacity(0.5)
              Text('功能开发中').fontSize(16).fontColor($r('app.color.text_tertiary')).margin({ top: 16 })
              Text('敬请期待').fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ top: 4 })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)  // 内容水平居中
          }.layoutWeight(1).height('100%').backgroundColor($r('app.color.page_background')).alignItems(HorizontalAlign.Start)
        } else {
          // ========== 我的页面 ==========
          Scroll() {
            Column() {
              // 标题
              Text('我的').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
                .width('100%').margin({ bottom: 16 })

              // 实用工具
              Column() {
                Text('实用工具').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 16 }).width('100%')
            Row() {
                  Column() {
                    SymbolGlyph($r('sys.symbol.gearshape')).fontSize(28).fontColor([$r('app.color.accent')]).margin({ bottom: 8 })
                    Text('设备检测').fontSize(13).fontColor($r('app.color.text_primary'))
                    Text('JIT/KVM状态').fontSize(11).fontColor($r('app.color.text_secondary'))
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center).onClick((): void => { this.openSheet('status') })
                  Column() {
                    SymbolGlyph($r('sys.symbol.doc_text')).fontSize(28).fontColor(['#FF9500']).margin({ bottom: 8 })
                    Text('日志查看').fontSize(13).fontColor($r('app.color.text_primary'))
                    Text('导出诊断日志').fontSize(11).fontColor($r('app.color.text_secondary'))
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center).onClick((): void => { this.exportLogs() })
                  Column() {
                    SymbolGlyph($r('sys.symbol.folder')).fontSize(28).fontColor(['#34C759']).margin({ bottom: 8 })
                    Text('ISO 管理').fontSize(13).fontColor($r('app.color.text_primary'))
                    Text('镜像文件').fontSize(11).fontColor($r('app.color.text_secondary'))
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center)
                }.width('100%')
              }.padding(20).backgroundColor($r('app.color.card_background')).borderRadius(16).margin({ bottom: 16 })

              // 设置
              Column() {
                Row() {
                  SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
                  Text('设置').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
                }.width('100%').height(52)
              }
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(16)
              .margin({ bottom: 16 })
              .onClick((): void => { this.openSheet('settings') })

              // 关于
              Column() {
            Row() {
                  SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
                  Text('关于').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  Text('v1.0.0').fontSize(13).fontColor($r('app.color.text_tertiary'))
                  SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')]).margin({ left: 8 })
                }.width('100%').height(52)
              }.padding({ left: 16, right: 16 }).backgroundColor($r('app.color.card_background')).borderRadius(16)

            }.width('100%').padding({ left: 24, right: 24, top: 16 }).alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor($r('app.color.page_background'))
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)  // 内容从顶部开始
        }
          }.layoutWeight(1)
        } // 结束展开模式的 else
      }.width('100%').height('100%')
      // ========== 系统半模态弹窗（统一使用一个 bindSheet） ==========
      .bindSheet(
        this.sheetVisible,
        this.SheetContentBuilder(),
        {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          showClose: true,
          maskColor: '#66000000',
          backgroundColor: $r('app.color.card_background'),
          blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
          preferType: SheetType.CENTER,
          onDisappear: (): void => {
            hilog.info(0x0000, 'INDEX', '>>> Sheet onDisappear 触发，currentSheet=%{public}s <<<', this.currentSheet)
            this.sheetVisible = false
            this.currentSheet = 'none'
          }
        }
      )
      
      // ========== 命令面板覆盖层 ==========
      if (this.showCommandPalette) {
        CommandPalette({
          vmList: this.vms.map((vm: VMMeta): VMInfo => ({
            id: vm.id,
            name: vm.name,
            status: vm.status,
            osType: vm.osType
          })),
          onClose: (): void => { this.showCommandPalette = false },
          onNavigateToVm: (vmId: string): void => {
            this.selectedVmId = vmId
            this.currentTab = 0
            this.showCommandPalette = false
          },
          onExecuteInVm: (vmName: string, command: string): void => {
            hilog.info(0x0000, 'INDEX', '在 VM %{public}s 执行命令: %{public}s', vmName, command)
            // TODO: 通过 QMP 或 SSH 执行命令
            promptAction.showToast({ message: `执行: ${command}` })
          },
          onCreateVm: (): void => {
            this.showCommandPalette = false
            this.openWizard()
          },
          onStartVm: (vmId: string): void => {
            const vm = this.vms.find((v: VMMeta): boolean => v.id === vmId)
            if (vm) {
              // 命令面板触发的 /vm.start 打开启动模式选择面板
              this.showCommandPalette = false
              this.startTargetVM = vm
              this.openSheet('startMode')
            }
          },
          onStopVm: (vmId: string): void => {
            const vm = this.vms.find((v: VMMeta): boolean => v.id === vmId)
            if (vm) this.stopVM(vm)
          },
          onOpenVnc: (vmId: string): void => {
            const vm = this.vms.find((v: VMMeta): boolean => v.id === vmId)
            if (vm) {
              this.openVNCWindow(vm)
            }
          },
          onOpenConsole: (vmId: string): void => {
            this.showCommandPalette = false
            this.openConsole(vmId)
          },
          onExportLogs: (): void => { this.exportLogs() },
          onOpenSettings: (): void => {
            this.showCommandPalette = false
            this.currentSheet = 'settings'
            this.sheetVisible = true
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  // 半模态内容 Builder（根据 currentSheet 类型渲染不同内容）
  @Builder SheetContentBuilder() {
    Column() {
      if (this.currentSheet === 'wizard') {
        VMCreateWizard({
          isKvmCandidateDevice: this.isKvmCandidateDevice,
          machineOptions: this.supportedMachines.map((m: MachineOption): MachineOption => ({
            id: m.id,
            name: m.name,
            desc: m.desc,
            icon: m.icon
          })),
          displayOptions: this.supportedDisplays,
          networkOptions: this.supportedNetworks,
          audioOptions: this.supportedAudios,
          onShowKvmDetail: (): void => {
            this.currentSheet = 'kvmDetail'
            this.sheetVisible = true
          },
          onComplete: (result: WizardResult): void => {
            this.createVMFromWizardResult(result)
          },
          onCancel: (): void => {
            this.closeSheet()
          }
        })
      } else if (this.currentSheet === 'status') {
        this.StatusContent()
      } else if (this.currentSheet === 'startMode') {
        this.StartModeContent()
      } else if (this.currentSheet === 'kvmDetail') {
        this.KvmDetailContent()
      } else if (this.currentSheet === 'settings') {
        this.SettingsContent()
      } else if (this.currentSheet === 'console') {
        this.ConsoleContent()
      } else if (this.currentSheet === 'shortcut') {
        this.ShortcutBindContent()
      } else if (this.currentSheet === 'vmSettings') {
        this.VMSettingsContent()
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 480, minHeight: 200 })
  }

  // 控制台内容
  @Builder ConsoleContent() {
    Column() {
      // 标题栏
      Row() {
        Text('串口控制台 (TTL)').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          .onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 8 })
      
      // 日志显示区
      Scroll(this.scroller) {
        Text(this.consoleLogs)
          .fontSize(12)
          .fontColor('#00FF00')
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#1E1E1E')
      .padding(8)
      .borderRadius(8)
      .align(Alignment.TopStart)
      
      // 输入框
      Row() {
        TextInput({ text: this.consoleInput, placeholder: '输入命令...' })
          .layoutWeight(1)
          .height(40)
          .backgroundColor($r('app.color.sidebar_background'))
          .onChange((val: string) => { this.consoleInput = val })
          .onSubmit(() => {
            if (this.consoleInput) {
              QemuVMManager.getInstance().writeToVmConsole(this.consoleInput + '\n')
              this.consoleInput = ''
            }
          })
        
        Button('发送')
          .type(ButtonType.Capsule)
          .height(36)
          .margin({ left: 8 })
          .onClick(() => {
            if (this.consoleInput) {
              QemuVMManager.getInstance().writeToVmConsole(this.consoleInput + '\n')
              this.consoleInput = ''
            }
          })
      }.width('100%').margin({ top: 8 })
      
    }.width('100%').height('100%').padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  // ========== 虚拟机设置 Sheet ==========
  @Builder VMSettingsContent() {
    Column() {
      // 标题栏
      Row() {
        Text('虚拟机设置').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          .onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 16 })
      
      if (this.getSelectedVM()) {
        // 基本信息
        Text('基本信息').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 12 }).width('100%')
        
        // 虚拟机名称
        Row() {
          Text('名称').fontSize(14).fontColor($r('app.color.text_primary')).width(80)
          Text(this.getSelectedVM()!.name).fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1).textAlign(TextAlign.End)
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 8 })
        
        // 架构
        Row() {
          Text('架构').fontSize(14).fontColor($r('app.color.text_primary')).width(80)
          Text(this.getSelectedVM()!.config.archType || 'aarch64').fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1).textAlign(TextAlign.End)
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 16 })
        
        // 硬件配置
        Text('硬件配置').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 12 }).width('100%')
        
        // CPU
        Row() {
          Text('CPU 核心数').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(`${this.getSelectedVM()!.config.cpuCount} 核`).fontSize(14).fontColor($r('app.color.accent'))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')]).margin({ left: 8 })
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 8 })
        
        // 内存
        Row() {
          Text('内存').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(`${(this.getSelectedVM()!.config.memoryMB / 1024).toFixed(0)} GB`).fontSize(14).fontColor($r('app.color.accent'))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')]).margin({ left: 8 })
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 8 })
        
        // 磁盘
        Row() {
          Text('磁盘大小').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(`${this.getSelectedVM()!.config.diskSizeGB} GB`).fontSize(14).fontColor($r('app.color.accent'))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')]).margin({ left: 8 })
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 16 })
        
        // 存储
        Text('存储').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 12 }).width('100%')
        
        // ISO 镜像
        Row() {
          SymbolGlyph($r('sys.symbol.opticaldisc')).fontSize(20).fontColor([$r('app.color.accent')]).margin({ right: 12 })
          Column() {
            Text('ISO 镜像').fontSize(14).fontColor($r('app.color.text_primary'))
            Text(this.getSelectedVM()!.config.isoPath || '未挂载').fontSize(11).fontColor($r('app.color.text_tertiary')).margin({ top: 2 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.getSelectedVM()!.config.isoPath ? '更换' : '选择').type(ButtonType.Capsule).height(28).fontSize(12).backgroundColor($r('app.color.accent'))
            .onClick(() => { this.pickIsoForVm(this.getSelectedVM()!) })
          Button('弹出').type(ButtonType.Capsule).height(28).fontSize(12).backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ left: 8 })
            .enabled(!!this.getSelectedVM()!.config.isoPath)
            .onClick(() => { this.ejectIso(this.getSelectedVM()!) })
        }.width('100%').height(56).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 16 })
        
        // 高级设置
        Text('高级').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).margin({ bottom: 12 }).width('100%')
        
        // 添加虚拟设备
        Row() {
          SymbolGlyph($r('sys.symbol.plus_circle')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
          Text('添加虚拟设备').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 8 })
        
        // 网络设置
        Row() {
          SymbolGlyph($r('sys.symbol.wifi')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
          Text('网络设置').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10).margin({ bottom: 8 })
        
        // 共享文件夹
        Row() {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(20).fontColor([$r('app.color.text_secondary')]).margin({ right: 12 })
          Text('共享文件夹').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
        }.width('100%').height(44).padding({ left: 12, right: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(10)
      }
    }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  // 桌面快捷方式绑定 / 启动内容
  @Builder ShortcutBindContent() {
    Column() {
      // 标题栏
      Row() {
        Text('快捷方式启动').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          .onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 12 })

      // 当前槽位说明
      Text(`当前来自桌面快捷方式：${this.activeShortcutId || '未知'}`)
        .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 12 }).width('100%')

      // 选择要启动的虚拟机
      Text('请选择要启动的虚拟机').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 }).width('100%')
      Column() {
        ForEach(this.vms, (vm: VMMeta) => {
          Row() {
            Column() {
              Text(vm.name)
                .fontSize(15)
                .fontColor(this.shortcutSelectedVmId === vm.id ? $r('app.color.accent') : $r('app.color.text_primary'))
              Row() {
                Circle().width(8).height(8).fill(vm.status === 'running' ? '#34C759' : $r('app.color.text_tertiary')).margin({ right: 6 })
                Text(vm.status === 'running' ? '运行中' : '已停止').fontSize(12).fontColor($r('app.color.text_secondary'))
              }.margin({ top: 2 })
            }.layoutWeight(1)
            if (this.shortcutSelectedVmId === vm.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.shortcutSelectedVmId === vm.id ? $r('app.color.sidebar_item_selected') : $r('app.color.card_background'))
          .borderRadius(10)
          .margin({ bottom: 8 })
          .onClick((): void => { this.shortcutSelectedVmId = vm.id })
        })
      }.width('100%').margin({ bottom: 16 })

      // 启动方式选择
      Text('启动方式').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 }).width('100%')
      // 第一行：增强启动 / 普通启动
      Row() {
        Button('🖥️ 普通 (VNC)').type(ButtonType.Capsule).height(36).layoutWeight(1).backgroundColor(this.shortcutMode === 'standard' ? '#FF9500' : $r('app.color.sidebar_background'))
          .fontColor(this.shortcutMode === 'standard' ? Color.White : $r('app.color.text_primary'))
          .onClick((): void => { this.shortcutMode = 'standard' })
      }.width('100%').margin({ bottom: 8 })
      // 第二行：安装模式 / 调试模式
      Row() {
        Button('📀 安装 (VNC)').type(ButtonType.Capsule).height(36).layoutWeight(1)
          .backgroundColor(this.shortcutMode === 'install' ? '#34C759' : $r('app.color.sidebar_background'))
          .fontColor(this.shortcutMode === 'install' ? Color.White : $r('app.color.text_primary'))
          .onClick((): void => { this.shortcutMode = 'install' })
        Button('🔧 调试 (串口)').type(ButtonType.Capsule).height(36).layoutWeight(1).margin({ left: 8 })
          .backgroundColor(this.shortcutMode === 'debug' ? $r('app.color.sidebar_background') : $r('app.color.sidebar_background'))
          .fontColor($r('app.color.text_primary'))
          .border({ width: this.shortcutMode === 'debug' ? 2 : 0, color: $r('app.color.accent') })
          .onClick((): void => { this.shortcutMode = 'debug' })
      }.width('100%').margin({ bottom: 20 })

      // 操作按钮
      Row() {
        Button('取消').type(ButtonType.Capsule).height(40).layoutWeight(1)
          .backgroundColor($r('app.color.sidebar_background')).fontColor($r('app.color.text_primary')).margin({ right: 8 })
          .onClick((): void => { this.closeSheet(); this.activeShortcutId = ''; this.shortcutSelectedVmId = '' })
        Button('启动').type(ButtonType.Capsule).height(40).layoutWeight(1)
          .backgroundColor($r('app.color.accent')).fontColor(Color.White)
          .onClick((): void => {
            const vm = this.vms.find((v: VMMeta): boolean => v.id === this.shortcutSelectedVmId)
            if (vm) {
              this.startVM(vm, this.shortcutMode)
            }
            this.activeShortcutId = ''
          })
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  // KVM 详情内容
  @Builder KvmDetailContent() {
    Column() {
      Image($r('app.media.illust_access_denied'))
        .width(200)
        .height(150)
        .objectFit(ImageFit.Contain)
        .margin({ top: 16, bottom: 16 })
      Text('KVM 不可用').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).margin({ bottom: 12 })
      Text('华为限制我们使用 KVM 功能').fontSize(15).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
      Text('我们正在与华为沟通，试图让他们解锁此限制。\n\nKVM 是一种硬件虚拟化技术，可以显著提升虚拟机性能。目前您只能使用 TCG 模式运行虚拟机。')
        .fontSize(14).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center).lineHeight(22).margin({ bottom: 24 })
      
      Button('我知道了').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.accent'))
        .onClick((): void => { this.closeSheet() })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
    .alignItems(HorizontalAlign.Center)
  }

  // 设置内容
  @Builder SettingsContent() {
    Column() {
      // 标题
      Row() {
        Text('设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          .onClick((): void => { this.closeSheet() }).padding(8)
      }.width('100%').margin({ bottom: 24 })

      Scroll() {
        Column() {
          // 默认机器配置
          Text('默认机器配置').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: 12 })
          
          // 默认机器类型
          Column() {
            Row() {
              Text('机器类型').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(this.settingsDefaultMachine).fontSize(14).fontColor($r('app.color.text_tertiary'))
            }.width('100%').height(48)
          }.padding({ left: 16, right: 16 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 8 })

          // 默认内存
          Column() {
            Row() {
              Text('默认内存').fontSize(15).fontColor($r('app.color.text_primary'))
              Blank()
              Text(`${(this.settingsDefaultMemory / 1024).toFixed(0)} GB`).fontSize(14).fontColor($r('app.color.text_tertiary'))
            }.width('100%').margin({ bottom: 8 })
            Slider({ value: this.settingsDefaultMemory, min: 1024, max: 16384, step: 1024 })
              .onChange((v: number): void => { this.settingsDefaultMemory = v })
          }.padding(16).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 8 })

          // 默认磁盘
          Column() {
            Row() {
              Text('默认磁盘').fontSize(15).fontColor($r('app.color.text_primary'))
              Blank()
              Text(`${this.settingsDefaultDisk} GB`).fontSize(14).fontColor($r('app.color.text_tertiary'))
            }.width('100%').margin({ bottom: 8 })
            Slider({ value: this.settingsDefaultDisk, min: 16, max: 256, step: 8 })
              .onChange((v: number): void => { this.settingsDefaultDisk = v })
          }.padding(16).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 8 })

          // 默认 CPU 核心数
          Column() {
            Row() {
              Text('CPU 核心数').fontSize(15).fontColor($r('app.color.text_primary'))
              Blank()
              Text(`${this.settingsDefaultCpu} 核`).fontSize(14).fontColor($r('app.color.text_tertiary'))
            }.width('100%').margin({ bottom: 8 })
            Slider({ value: this.settingsDefaultCpu, min: 1, max: 8, step: 1 })
              .onChange((v: number): void => { this.settingsDefaultCpu = v })
          }.padding(16).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 16 })

          // 其他设置
          Text('其他设置').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: 12 })

          // 默认显示方式
          Column() {
            Text('启动虚拟机时使用').fontSize(15).fontColor($r('app.color.text_primary')).width('100%').margin({ bottom: 12 })
            Row() {
              Row() {
                Radio({ value: 'vnc', group: 'displayMode' })
                  .checked(this.settingsDefaultDisplay === 'vnc')
                  .onChange((isChecked: boolean): void => { if (isChecked) this.settingsDefaultDisplay = 'vnc' })
                Text('VNC').fontSize(14).fontColor($r('app.color.text_primary')).margin({ left: 8 })
              }.layoutWeight(1)
            }.width('100%')
            Text('当前版本使用 VNC 图形模式').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: 8 })
          }.padding({ left: 16, right: 16, top: 12, bottom: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 8 })

          // 安装完成后自动打开显示
          Column() {
            Row() {
              Text('创建后自动打开').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settingsAutoStartVnc })
                .onChange((isOn: boolean): void => { this.settingsAutoStartVnc = isOn })
            }.width('100%').height(48)
            Text('创建虚拟机后自动打开显示器').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
          }.padding({ left: 16, right: 16, top: 12, bottom: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(12).margin({ bottom: 16 })

          // VNC 设置
          Text('VNC 设置').fontSize(13).fontColor($r('app.color.text_secondary')).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: 12 })
          
          // VNC 端口设置
          Column() {
            Row() {
              Text('原生 VNC 端口 (RFB)').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              TextInput({ text: this.settingsVncNativePort.toString() })
                .width(80)
                .height(36)
                .type(InputType.Number)
                .fontSize(14)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius(8)
                .onChange((value: string): void => { 
                  const port = parseInt(value) || 5901
                  const p = Math.max(1024, Math.min(65535, port))
                  this.persistVncPort(p)
                })
            }.width('100%')
            
            Text('提示：原生端口为 QEMU VNC 的 RFB 协议端口')
              .fontSize(11).fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: 8 })
          }.padding({ left: 16, right: 16, top: 12, bottom: 12 }).backgroundColor($r('app.color.sidebar_background')).borderRadius(12)

        }.width('100%')
      }.layoutWeight(1)

      // 保存按钮
      Button('保存设置').type(ButtonType.Capsule).width('100%').height(44).backgroundColor($r('app.color.accent')).margin({ top: 16 })
        .onClick((): void => { this.closeSheet() })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }
}
