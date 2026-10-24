/**
 * 虚拟机创建向导组件
 * 
 * 支持两种模式：
 * - 普通模式：架构 → 内存 → 硬盘 → 系统 → 镜像 → 名字 → 完成
 * - 高级模式：机器 → 显卡 → 网卡 → 声卡 → 内存 → 硬盘 → 系统 → 镜像 → 名字 → 完成
 */

import filePicker from '@ohos.file.picker'
import hilog from '@ohos.hilog'
import promptAction from '@ohos.promptAction'
import { StoragePaths } from '../utils/StoragePaths'

// 向导步骤定义
type WizardMode = 'normal' | 'advanced'
// 普通模式：包含架构步骤
type NormalStep = 'arch' | 'memory' | 'disk' | 'os' | 'image' | 'name' | 'done'
// 高级模式：同样包含 CPU 架构步骤，满足“高级设置也能选架构”的需求
type AdvancedStep = 'arch' | 'machine' | 'display' | 'network' | 'audio' | 'memory' | 'disk' | 'os' | 'image' | 'name' | 'done'
type WizardStep = 'select_mode' | NormalStep | AdvancedStep

// 机器类型选项
interface MachineOption {
  id: string
  name: string
  desc: string
}

// 显卡选项
interface DisplayOption {
  id: string
  name: string
  desc: string
}

// 网卡选项
interface NetworkOption {
  id: string
  name: string
  desc: string
}

// 声卡选项
interface AudioOption {
  id: string
  name: string
  desc: string
}

// 架构选项
interface ArchOption {
  id: string
  name: string
  supported: boolean
}

// 系统选项
interface OSOption {
  id: string
  name: string
  icon: string
  arch: string
}

// 向导结果
export interface WizardResult {
  name: string
  archType: string
  osType: string
  memoryMB: number
  diskSizeGB: number
  isoPath: string
  importedDiskPath: string
  noDisk: boolean
  // 高级选项
  machine: string
  displayDevice: string
  networkDevice: string
  audioDevice: string
}

@Component
export struct VMCreateWizard {
  // 回调
  onComplete: (result: WizardResult) => void = () => {}
  onCancel: () => void = () => {}
  // 外部传入：是否为潜在 KVM 设备（MateBook Pro / MateBook Fold / MatePad Edge）
  isKvmCandidateDevice: boolean = false
  // 外部传入：由宿主负责弹出 “KVM 详情” Sheet
  onShowKvmDetail: () => void = () => {}
  // 外部传入：QEMU 支持的机器类型列表（如果为空则使用默认列表）
  machineOptions: MachineOption[] = []
  // 外部传入：QEMU 支持的设备列表（如果为空则使用默认列表）
  displayOptions: DisplayOption[] = []
  networkOptions: NetworkOption[] = []
  audioOptions: AudioOption[] = []
  
  // 状态
  @State currentStep: WizardStep = 'select_mode'
  @State wizardMode: WizardMode = 'normal'
  
  // 配置值
  @State selectedArch: string = 'aarch64'
  @State selectedMachine: string = 'virt'
  // 默认不要用 none，否则 VNC 只会看到 “Parallel Console”
  @State selectedDisplay: string = 'virtio-gpu-pci'
  @State selectedNetwork: string = 'virtio-net'
  @State selectedAudio: string = 'none'
  @State selectedOS: string = 'Windows'
  @State memoryMB: number = 6144
  @State diskSizeGB: number = 64
  @State noDisk: boolean = false
  @State isoPath: string = ''
  @State importedDiskPath: string = ''
  @State vmName: string = ''
  @State filePickerBusy: boolean = false
  @State fileSelectionError: string = ''
  private selectionEpoch: number = 0
  private wizardActive: boolean = true
  
  // 默认机器选项（当外部没有提供 machineOptions 时使用）
  private defaultMachines: MachineOption[] = [
    { id: 'virt', name: 'virt (推荐)', desc: 'ARM 虚拟化平台，性能最佳' },
    { id: 'raspi3b', name: 'Raspberry Pi 3B', desc: '树莓派 3B 模拟' },
    { id: 'raspi4b', name: 'Raspberry Pi 4B', desc: '树莓派 4B 模拟' },
  ]
  
  // 显卡列表（基于 libqemu_full.so 实际支持的设备）
  private displays: DisplayOption[] = [
    { id: 'virtio-gpu-pci', name: 'VirtIO GPU', desc: 'VirtIO 虚拟显卡（推荐）' },
    { id: 'virtio-gpu-gl-pci', name: 'VirtIO GPU (GL)', desc: 'VirtIO GPU + OpenGL' },
    { id: 'ramfb', name: 'RAM Framebuffer', desc: '简单帧缓冲显示' },
    { id: 'bochs-display', name: 'Bochs Display', desc: 'Bochs 显示适配器' },
    { id: 'VGA', name: '标准 VGA', desc: '标准 VGA 显卡' },
    { id: 'cirrus-vga', name: 'Cirrus VGA', desc: 'Cirrus Logic 显卡' },
    { id: 'none', name: '无显示设备', desc: '仅串口/网络访问' },
  ]
  
  // 网卡列表（基于 libqemu_full.so 实际支持的设备）
  private networks: NetworkOption[] = [
    { id: 'virtio-net-pci', name: 'VirtIO 网卡', desc: 'VirtIO 高性能网卡（推荐）' },
    { id: 'e1000', name: 'Intel E1000', desc: 'Intel 千兆网卡' },
    { id: 'e1000e', name: 'Intel E1000e', desc: 'Intel 82574L 网卡' },
    { id: 'pcnet', name: 'AMD PCnet', desc: 'AMD PCnet 网卡' },
    { id: 'vmxnet3', name: 'VMXNET3', desc: 'VMware 高性能网卡' },
    { id: 'none', name: '无网络', desc: '离线模式' },
  ]

  // 声卡列表（基于 libqemu_full.so 实际支持的设备）
  private audios: AudioOption[] = [
    { id: 'none', name: '无声卡', desc: '静音模式（推荐）' },
    { id: 'hda', name: 'Intel HDA', desc: 'intel-hda + hda-duplex' },
    { id: 'ich9-intel-hda', name: 'ICH9 HDA', desc: 'ich9-intel-hda + hda-duplex' },
    { id: 'ac97', name: 'AC97', desc: 'AC97 声卡' },
    { id: 'virtio-sound-pci', name: 'VirtIO Sound', desc: 'VirtIO 虚拟声卡' },
  ]
  
  private archs: ArchOption[] = [
    { id: 'aarch64', name: 'ARM64 (aarch64)', supported: true },
    { id: 'x86_64', name: 'x86_64 (64位)', supported: false },
    { id: 'i386', name: 'i386 (32位)', supported: false },
  ]
  
  private osList: OSOption[] = [
    { id: 'Windows', name: 'Windows', icon: 'ic_os_windows', arch: 'aarch64' },
    { id: 'Linux', name: 'Linux', icon: 'ic_os_linux', arch: 'aarch64' },
    { id: 'macOS', name: 'macOS', icon: 'ic_os_macos', arch: 'aarch64' },
    { id: 'HarmonyOS', name: 'HarmonyOS', icon: 'ic_os_harmonyos', arch: 'aarch64' },
    { id: 'BSD', name: 'BSD', icon: 'ic_os_bsd', arch: 'aarch64' },
  ]
  
  build() {
    Column() {
      // 标题栏
      this.HeaderBar()
      
      // 进度指示器
      if (this.currentStep !== 'select_mode') {
        this.ProgressIndicator()
      }
      
      // 内容区
      Scroll() {
        Column() {
          if (this.currentStep === 'select_mode') {
            this.SelectModeStep()
          } else if (this.wizardMode === 'normal') {
            this.NormalModeContent()
          } else {
            this.AdvancedModeContent()
          }
        }.width('100%')
      }.layoutWeight(1).scrollBar(BarState.Auto)
      
      if (this.filePickerBusy) {
        Text('正在准备镜像，请稍候…').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 12 })
      }
      if (this.fileSelectionError) {
        Text(this.fileSelectionError).fontSize(12).fontColor('#E84026').margin({ top: 12 })
      }

      // 底部按钮
      if (this.currentStep !== 'select_mode') {
        this.BottomButtons()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
  }
  
  @Builder HeaderBar() {
    Row() {
      Text(this.getStepTitle()).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Blank()
      if (this.currentStep !== 'done') {
        Text('取消').fontSize(14).fontColor($r('app.color.accent'))
          .onClick(() => this.cancelWizard())
      }
    }.width('100%').margin({ bottom: 16 })
  }
  
  @Builder ProgressIndicator() {
    Row() {
      ForEach(this.getSteps(), (step: string, index: number) => {
        // 圆点
        Circle({ width: 8, height: 8 })
          .fill(this.getStepIndex() >= index ? $r('app.color.accent') : $r('app.color.divider'))
        // 连接线
        if (index < this.getSteps().length - 1) {
          Line().width(24).height(2)
            .backgroundColor(this.getStepIndex() > index ? $r('app.color.accent') : $r('app.color.divider'))
        }
      })
    }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 24 })
  }
  
  // ========== 选择模式步骤 ==========
  @Builder SelectModeStep() {
    Column() {
      // 顶部插画
      Image($r('app.media.illust_create_vm'))
        .width(200)
        .height(120)
        .objectFit(ImageFit.Contain)
        .margin({ bottom: 20 })
      
      Text('您想要什么设置流程？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 24 })

      // KVM 模式（仅在指定设备上展示，占位且不可用）
      if (this.isKvmCandidateDevice) {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.bolt_fill'))
                .fontSize(20)
                .fontColor([$r('app.color.accent')])
                .margin({ right: 12 })
              Column() {
                Text('KVM 模式')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('使用华为的虚拟化框架提供更快的运行速度')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.lock_fill'))
                .fontSize(16)
                .fontColor([$r('app.color.text_tertiary')])
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(12)
        .opacity(0.5)
        .enabled(false)
        .margin({ bottom: 12 })
      }
      
      // 普通模式
      Row() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
            Column() {
              Text('普通设置').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text('快速创建，适合大多数用户').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width('100%')
        }.layoutWeight(1)
      }
      .width('100%').padding(16)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(12).margin({ bottom: 12 })
      .onClick(() => {
        this.wizardMode = 'normal'
        this.currentStep = 'arch'
      })
      
      // 高级模式
      Row() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(24).fontColor(['#FF9500']).margin({ right: 12 })
            Column() {
              Text('高级设置').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text('自定义机器类型、显卡、网卡等').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width('100%')
        }.layoutWeight(1)
      }
      .width('100%').padding(16)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(12)
      .width('100%').padding(16)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(12)
      .onClick(() => {
        this.wizardMode = 'advanced'
        // 高级模式从“架构”开始，让两种模式都能显式选择 CPU 架构
        this.currentStep = 'arch'
      })

      // 高级设置下方的 KVM 不可用提示（仅在候选设备上展示）
      if (this.isKvmCandidateDevice) {
        Row() {
          Text('KVM 设置在本构建不可用')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
          Text('查看详情')
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .margin({ left: 4 })
            .onClick(() => {
              this.onShowKvmDetail()
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .justifyContent(FlexAlign.Start)
      }
    }.width('100%')
  }
  
  // ========== 普通模式内容 ==========
  @Builder NormalModeContent() {
    if (this.currentStep === 'arch') {
      this.ArchStep()
    } else if (this.currentStep === 'memory') {
      this.MemoryStep()
    } else if (this.currentStep === 'disk') {
      this.DiskStep()
    } else if (this.currentStep === 'os') {
      this.OSStep()
    } else if (this.currentStep === 'image') {
      this.ImageStep()
    } else if (this.currentStep === 'name') {
      this.NameStep()
    } else if (this.currentStep === 'done') {
      this.DoneStep()
    }
  }
  
  // ========== 高级模式内容 ==========
  @Builder AdvancedModeContent() {
    if (this.currentStep === 'arch') {
      this.ArchStep()
    } else if (this.currentStep === 'machine') {
      this.MachineStep()
    } else if (this.currentStep === 'display') {
      this.DisplayStep()
    } else if (this.currentStep === 'network') {
      this.NetworkStep()
    } else if (this.currentStep === 'audio') {
      this.AudioStep()
    } else if (this.currentStep === 'memory') {
      this.MemoryStep()
    } else if (this.currentStep === 'disk') {
      this.DiskStep()
    } else if (this.currentStep === 'os') {
      this.OSStep()
    } else if (this.currentStep === 'image') {
      this.ImageStep()
    } else if (this.currentStep === 'name') {
      this.NameStep()
    } else if (this.currentStep === 'done') {
      this.DoneStep()
    }
  }
  
  // ========== 各步骤 UI ==========
  
  @Builder ArchStep() {
    Column() {
      Text('请选择 CPU 架构').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.archs, (arch: ArchOption) => {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(24).fontColor([arch.supported ? $r('app.color.accent') : $r('app.color.text_tertiary')]).margin({ right: 12 })
              Text(arch.name).fontSize(16).fontColor(arch.supported ? $r('app.color.text_primary') : $r('app.color.text_tertiary')).layoutWeight(1)
              if (this.selectedArch === arch.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
              }
              if (!arch.supported) {
                Text('不可用').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ left: 8 })
              }
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedArch === arch.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .enabled(arch.supported)
        .opacity(arch.supported ? 1 : 0.5)
        .onClick(() => {
          if (arch.supported) {
            this.selectedArch = arch.id
          }
        })
      })
      
      // 切换到高级模式提示
      Row() {
        Text('想要更多控制？').fontSize(12).fontColor($r('app.color.text_tertiary'))
        Text('切换到高级设置').fontSize(12).fontColor($r('app.color.accent')).margin({ left: 4 })
          .onClick(() => {
            this.wizardMode = 'advanced'
            this.currentStep = 'machine'
          })
      }.width('100%').margin({ top: 16 }).justifyContent(FlexAlign.Center)
    }.width('100%')
  }
  
  @Builder MachineStep() {
    Column() {
      Text('您想虚拟什么机器？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.machineOptions.length > 0 ? this.machineOptions : this.defaultMachines, (machine: MachineOption) => {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.display')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Column() {
                Text(machine.name).fontSize(16).fontColor($r('app.color.text_primary'))
                Text(machine.desc).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.selectedMachine === machine.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
              }
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedMachine === machine.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick(() => { this.selectedMachine = machine.id })
      })
      
      // 切换回普通模式
      Row() {
        Text('太复杂了？').fontSize(12).fontColor($r('app.color.text_tertiary'))
        Text('切换到普通设置').fontSize(12).fontColor($r('app.color.accent')).margin({ left: 4 })
          .onClick(() => {
            this.wizardMode = 'normal'
            this.currentStep = 'arch'
          })
      }.width('100%').margin({ top: 16 }).justifyContent(FlexAlign.Center)
    }.width('100%')
  }
  
  @Builder DisplayStep() {
    Column() {
      Text('您想要什么显卡？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.displayOptions.length > 0 ? this.displayOptions : this.displays, (display: DisplayOption) => {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.display')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Column() {
                Text(display.name).fontSize(16).fontColor($r('app.color.text_primary'))
                Text(display.desc).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.selectedDisplay === display.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
              }
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedDisplay === display.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick(() => { this.selectedDisplay = display.id })
      })
    }.width('100%')
  }
  
  @Builder NetworkStep() {
    Column() {
      Text('您想要什么网卡？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.networkOptions.length > 0 ? this.networkOptions : this.networks, (network: NetworkOption) => {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.wifi')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Column() {
                Text(network.name).fontSize(16).fontColor($r('app.color.text_primary'))
                Text(network.desc).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.selectedNetwork === network.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
              }
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedNetwork === network.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick(() => { this.selectedNetwork = network.id })
      })
    }.width('100%')
  }

  @Builder AudioStep() {
    Column() {
      Text('您想要什么声卡？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.audioOptions.length > 0 ? this.audioOptions : this.audios, (audio: AudioOption) => {
        Row() {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.speaker_wave_2')).fontSize(24).fontColor([$r('app.color.accent')]).margin({ right: 12 })
              Column() {
                Text(audio.name).fontSize(16).fontColor($r('app.color.text_primary'))
                Text(audio.desc).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.selectedAudio === audio.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
              }
            }.width('100%')
          }.layoutWeight(1)
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedAudio === audio.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick(() => { this.selectedAudio = audio.id })
      })
    }.width('100%')
  }
  
  @Builder MemoryStep() {
    Column() {
      Text('您的系统需要多大内存？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 24 })
      
      // 内存大小显示
      Text(`${(this.memoryMB / 1024).toFixed(0)} GB`).fontSize(48).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent')).margin({ bottom: 16 })
      
      // 滑块
      Column() {
        Slider({ value: this.memoryMB, min: 1024, max: 16384, step: 1024 })
          .onChange((v: number) => { this.memoryMB = v })
        Row() {
          Text('1 GB').fontSize(12).fontColor($r('app.color.text_tertiary'))
          Blank()
          Text('16 GB').fontSize(12).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
      }.width('100%').margin({ bottom: 24 })
      
      // 快捷选项
      Text('快捷选择').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 12 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([2048, 4096, 6144, 8192, 12288, 16384], (mem: number) => {
          Button(`${mem / 1024} GB`)
            .type(ButtonType.Capsule)
            .height(36)
            .backgroundColor(this.memoryMB === mem ? $r('app.color.accent') : $r('app.color.card_background'))
            .fontColor(this.memoryMB === mem ? Color.White : $r('app.color.text_primary'))
            .margin({ right: 8, bottom: 8 })
            .onClick(() => { this.memoryMB = mem })
        })
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Center)
  }
  
  @Builder DiskStep() {
    Column() {
      Text('您的系统需要多大硬盘？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 24 })
      
      if (!this.noDisk) {
        // 硬盘大小显示
        Text(`${this.diskSizeGB} GB`).fontSize(48).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent')).margin({ bottom: 16 })
        
        // 滑块
        Column() {
          Slider({ value: this.diskSizeGB, min: 16, max: 512, step: 8 })
            .onChange((v: number) => { this.diskSizeGB = v })
          Row() {
            Text('16 GB').fontSize(12).fontColor($r('app.color.text_tertiary'))
            Blank()
            Text('512 GB').fontSize(12).fontColor($r('app.color.text_tertiary'))
          }.width('100%')
        }.width('100%').margin({ bottom: 24 })
        
        // 快捷选项
        Text('快捷选择').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 12 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([32, 64, 128, 256, 512], (size: number) => {
            Button(`${size} GB`)
              .type(ButtonType.Capsule)
              .height(36)
              .backgroundColor(this.diskSizeGB === size ? $r('app.color.accent') : $r('app.color.card_background'))
              .fontColor(this.diskSizeGB === size ? Color.White : $r('app.color.text_primary'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.diskSizeGB = size })
          })
        }.width('100%')
      } else {
        SymbolGlyph($r('sys.symbol.externaldrive')).fontSize(64).fontColor([$r('app.color.text_tertiary')]).margin({ bottom: 16 })
        Text('不创建新硬盘').fontSize(16).fontColor($r('app.color.text_secondary'))
      }

      // 导入现有磁盘（放在硬盘配置步骤中）
      Column() {
        Text('导入现有 QEMU 磁盘 (QCOW2，可选)').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
        Row() {
          Column() {
            Text(this.importedDiskPath ? this.getFileName(this.importedDiskPath) : '未选择磁盘')
              .fontSize(14)
              .fontColor(this.importedDiskPath ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.importedDiskPath) {
              Text(this.importedDiskPath).fontSize(11).fontColor($r('app.color.text_tertiary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.importedDiskPath ? '更换' : '选择')
            .type(ButtonType.Capsule).height(32)
            .backgroundColor($r('app.color.card_background'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.filePickerBusy)
            .onClick(() => this.selectDisk())
        }.width('100%').padding(12).backgroundColor($r('app.color.card_background')).borderRadius(12)
      }.width('100%').margin({ top: 24 }).alignItems(HorizontalAlign.Start)

      // 不需要新硬盘选项
      Row() {
        Checkbox().select(this.noDisk).onChange((v: boolean) => { this.noDisk = v })
        Text('我不需要新建硬盘').fontSize(14).fontColor($r('app.color.text_primary')).margin({ left: 8 })
      }.width('100%').margin({ top: 24 })
    }.width('100%').alignItems(HorizontalAlign.Center)
  }
  
  @Builder OSStep() {
    Column() {
      Text('您的系统是什么？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 20 })
      
      ForEach(this.osList.filter((os: OSOption) => os.arch === this.selectedArch), (os: OSOption) => {
        Row() {
          Image($r(`app.media.${os.icon}`))
            .width(32).height(32).margin({ right: 12 })
            .fillColor($r('app.color.text_primary'))  // 随主题切换颜色
          Text(os.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          if (this.selectedOS === os.id) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
          }
        }
        .width('100%').padding(16)
        .backgroundColor(this.selectedOS === os.id ? $r('app.color.sidebar_background') : $r('app.color.card_background'))
        .borderRadius(12).margin({ bottom: 8 })
        .onClick(() => { this.selectedOS = os.id })
      })
    }.width('100%')
  }
  
  @Builder ImageStep() {
    Column() {
      Text('您有要安装的镜像吗？').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
      Text('可以在下面选择安装镜像 (ISO)，没有镜像也可以先跳过，稍后再添加。')
        .fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ bottom: 24 })
      
      // ISO 镜像选择
      Column() {
        Text('安装镜像 (ISO)').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ bottom: 8 })
        Row() {
          Column() {
            Text(this.isoPath ? this.getFileName(this.isoPath) : '未选择镜像')
              .fontSize(14)
              .fontColor(this.isoPath ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.isoPath) {
              Text(this.isoPath).fontSize(11).fontColor($r('app.color.text_tertiary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.isoPath ? '更换' : '选择')
            .type(ButtonType.Capsule).height(32)
            .backgroundColor($r('app.color.accent'))
            .enabled(!this.filePickerBusy)
            .onClick(() => this.selectISO())
        }.width('100%').padding(12).backgroundColor($r('app.color.card_background')).borderRadius(12)
      }.width('100%').margin({ bottom: 20 }).alignItems(HorizontalAlign.Start)
      
      // 提示
      Row() {
        SymbolGlyph($r('sys.symbol.info_circle')).fontSize(14).fontColor([$r('app.color.text_tertiary')]).margin({ right: 6 })
        Text('没有镜像也可以跳过，稍后再添加').fontSize(12).fontColor($r('app.color.text_tertiary'))
      }.width('100%').margin({ top: 16 })
    }.width('100%')
  }
  
  @Builder NameStep() {
    Column() {
      Text('给虚拟机起个名字吧！').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ bottom: 24 })
      
      TextInput({ text: this.vmName, placeholder: `${this.selectedOS} VM` })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.card_background'))
        .fontColor($r('app.color.text_primary'))
        .borderRadius(12)
        .onChange((val: string) => { this.vmName = val })
      
      // 建议名称
      Text('建议名称').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 24, bottom: 12 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([`${this.selectedOS} VM`, `My ${this.selectedOS}`, `测试机`, `开发环境`], (name: string) => {
          Button(name)
            .type(ButtonType.Capsule)
            .height(36)
            .backgroundColor($r('app.color.card_background'))
            .fontColor($r('app.color.text_primary'))
            .margin({ right: 8, bottom: 8 })
            .onClick(() => { this.vmName = name })
        })
      }.width('100%')
    }.width('100%')
  }
  
  @Builder DoneStep() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(64).fontColor(['#34C759']).margin({ bottom: 16 })
      Text('准备就绪！').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text('虚拟机配置已完成').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 8, bottom: 32 })
      
      // 配置摘要
      Column() {
        this.SummaryRow('名称', this.vmName || `${this.selectedOS} VM`)
        this.SummaryRow('架构', this.selectedArch)
        this.SummaryRow('系统', this.selectedOS)
        this.SummaryRow('内存', `${(this.memoryMB / 1024).toFixed(0)} GB`)
        if (!this.noDisk) {
          this.SummaryRow('硬盘', `${this.diskSizeGB} GB`)
        }
        if (this.wizardMode === 'advanced') {
          this.SummaryRow('机器', this.selectedMachine)
          this.SummaryRow('显卡', this.selectedDisplay)
          this.SummaryRow('网卡', this.selectedNetwork)
        }
        if (this.isoPath) {
          this.SummaryRow('ISO', this.getFileName(this.isoPath))
        }
      }.width('100%').padding(16).backgroundColor($r('app.color.card_background')).borderRadius(12)
    }.width('100%').alignItems(HorizontalAlign.Center)
  }
  
  @Builder SummaryRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor($r('app.color.text_tertiary'))
      Blank()
      Text(value).fontSize(13).fontColor($r('app.color.text_primary'))
    }.width('100%').margin({ bottom: 8 })
  }
  
  @Builder BottomButtons() {
    Row() {
      if (this.currentStep !== 'done') {
        Button('返回')
          .type(ButtonType.Capsule)
          .height(44)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => this.goBack())
        
        Button('下一步')
          .type(ButtonType.Capsule)
          .height(44)
          .backgroundColor($r('app.color.accent'))
          .layoutWeight(1)
          .onClick(() => this.goNext())
      } else {
        Button('返回修改')
          .type(ButtonType.Capsule)
          .height(44)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => this.goBack())
        
        Button('创建并启动')
          .type(ButtonType.Capsule)
          .height(44)
          .backgroundColor('#34C759')
          .layoutWeight(1)
          .onClick(() => this.complete())
      }
    }.width('100%').margin({ top: 16 }).enabled(!this.filePickerBusy)
  }
  
  // ========== 辅助方法 ==========

  aboutToAppear(): void {
    this.wizardActive = true
    this.selectionEpoch++
    this.filePickerBusy = false
  }

  aboutToDisappear(): void {
    this.wizardActive = false
    this.selectionEpoch++
    this.filePickerBusy = false
  }

  private cancelWizard(): void {
    this.wizardActive = false
    this.selectionEpoch++
    this.filePickerBusy = false
    this.onCancel()
  }
  
  private getStepTitle(): string {
    const titles: Record<string, string> = {
      'select_mode': '创建虚拟机',
      'arch': '选择架构',
      'machine': '选择机器',
      'display': '选择显卡',
      'network': '选择网卡',
      'memory': '配置内存',
      'disk': '配置硬盘',
      'os': '选择系统',
      'image': '选择镜像',
      'name': '命名',
      'done': '完成'
    }
    return titles[this.currentStep] || '创建虚拟机'
  }
  
  private getSteps(): string[] {
    if (this.wizardMode === 'normal') {
      return ['arch', 'memory', 'disk', 'os', 'image', 'name', 'done']
    } else {
      return ['machine', 'display', 'network', 'audio', 'memory', 'disk', 'os', 'image', 'name', 'done']
    }
  }
  
  private getStepIndex(): number {
    const steps = this.getSteps()
    return steps.indexOf(this.currentStep as string)
  }
  
  private goNext(): void {
    if (this.filePickerBusy || !this.wizardActive) return
    const steps = this.getSteps()
    const currentIndex = this.getStepIndex()
    if (currentIndex < steps.length - 1) {
      this.currentStep = steps[currentIndex + 1] as WizardStep
    }
  }
  
  private goBack(): void {
    if (this.filePickerBusy || !this.wizardActive) return
    const steps = this.getSteps()
    const currentIndex = this.getStepIndex()
    if (currentIndex > 0) {
      this.currentStep = steps[currentIndex - 1] as WizardStep
    } else {
      this.currentStep = 'select_mode'
    }
  }
  
  private complete(): void {
    if (this.filePickerBusy || !this.wizardActive) return
    const result: WizardResult = {
      name: this.vmName || `${this.selectedOS} VM`,
      archType: this.selectedArch,
      osType: this.selectedOS,
      memoryMB: this.memoryMB,
      diskSizeGB: this.diskSizeGB,
      isoPath: this.isoPath,
      importedDiskPath: this.importedDiskPath,
      noDisk: this.noDisk,
      machine: this.selectedMachine,
      displayDevice: this.selectedDisplay,
      networkDevice: this.selectedNetwork,
      audioDevice: this.selectedAudio
    }
    this.onComplete(result)
  }
  
  private async selectISO(): Promise<void> {
    if (this.filePickerBusy || !this.wizardActive) return
    const epoch = ++this.selectionEpoch
    this.filePickerBusy = true
    this.fileSelectionError = ''
    try {
      const docPicker = new filePicker.DocumentViewPicker()
      const result = await docPicker.select({ maxSelectNumber: 1 })
      if (!this.wizardActive || epoch !== this.selectionEpoch) return
      if (result && result.length > 0) {
        // Keep the document URI intact and copy while its picker grant is valid.
        // A failed replacement leaves the previously imported ISO selected.
        const importedPath = await StoragePaths.importIso(result[0])
        if (!this.wizardActive || epoch !== this.selectionEpoch) return
        this.isoPath = importedPath
      }
    } catch (e) {
      hilog.error(0x0000, 'VMCreateWizard', '选择ISO失败: %{public}s', (e as Error).message)
      if (this.wizardActive && epoch === this.selectionEpoch) {
        this.fileSelectionError = 'ISO 导入失败，请重试：' + (e as Error).message
        promptAction.showToast({ message: this.fileSelectionError, duration: 3000 })
      }
    } finally {
      if (this.wizardActive && epoch === this.selectionEpoch) this.filePickerBusy = false
    }
  }
  
  private async selectDisk(): Promise<void> {
    if (this.filePickerBusy || !this.wizardActive) return
    const epoch = ++this.selectionEpoch
    this.filePickerBusy = true
    this.fileSelectionError = ''
    try {
      const docPicker = new filePicker.DocumentViewPicker()
      const result = await docPicker.select({ maxSelectNumber: 1 })
      if (!this.wizardActive || epoch !== this.selectionEpoch) return
      if (result && result.length > 0) {
        this.importedDiskPath = result[0]
      }
    } catch (e) {
      hilog.error(0x0000, 'VMCreateWizard', '选择磁盘失败: %{public}s', (e as Error).message)
      if (this.wizardActive && epoch === this.selectionEpoch) {
        this.fileSelectionError = '磁盘选择失败，请重试：' + (e as Error).message
        promptAction.showToast({ message: this.fileSelectionError, duration: 3000 })
      }
    } finally {
      if (this.wizardActive && epoch === this.selectionEpoch) this.filePickerBusy = false
    }
  }
  
  private getFileName(path: string): string {
    if (!path) return ''
    const parts = path.split('/')
    return parts[parts.length - 1] || path
  }
}

