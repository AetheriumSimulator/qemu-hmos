/**
 * 串口控制台 独立窗口页面
 * 在新窗口中显示虚拟机的串口 TTL 终端
 */
import common from '@ohos.app.ability.common'
import hilog from '@ohos.hilog'
import { QemuVMManager } from '../managers/QemuVMManager'
import { MicrophoneManager } from '../managers/MicrophoneManager'
import qemu from 'qemu_hmos'

@Entry({ useSharedStorage: true })
@Component
struct ConsoleWindow {
  @LocalStorageProp('console_vmName') vmName: string = ''
  @LocalStorageProp('console_vmId') vmId: string = ''
  @LocalStorageProp('viewer_microphoneSession') viewerMicrophoneSession: number = 0
  @StorageLink('microphoneVm') microphoneVm: string = ''
  @StorageLink('microphoneSession') microphoneSession: number = 0
  @StorageLink('microphoneEnabled') microphoneEnabled: boolean = false
  @StorageLink('microphoneBusy') microphoneBusy: boolean = false
  @StorageLink('microphoneStatus') microphoneStatus: string = 'disabled'
  @StorageLink('microphoneMessage') microphoneMessage: string = '麦克风已关闭'
  @State microphoneSessionValid: boolean = false
  
  @State consoleOutput: string[] = []
  @State inputText: string = ''
  @State isConnected: boolean = true
  
  private scrollerRef: Scroller = new Scroller()
  private maxLines: number = 1000
  private microphoneTimer: number = -1
  
  aboutToAppear(): void {
    this.refreshMicrophoneSession()
    if (this.microphoneTimer === -1) {
      this.microphoneTimer = setInterval((): void => { this.refreshMicrophoneSession() }, 500)
    }
    hilog.info(0x0000, 'ConsoleWindow', '页面加载: vmName=%{public}s vmId=%{public}s', this.vmName, this.vmId)
    
    // 注册控制台输出回调
    this.setupConsoleCallback()
    
    // 添加欢迎信息
    this.appendOutput(`\x1b[32m╭──────────────────────────────────────╮\x1b[0m`)
    this.appendOutput(`\x1b[32m│\x1b[0m  QEMU Serial Console - ${this.vmName}`)
    this.appendOutput(`\x1b[32m│\x1b[0m  Type commands and press Enter to send`)
    this.appendOutput(`\x1b[32m╰──────────────────────────────────────╯\x1b[0m`)
    this.appendOutput('')
  }

  aboutToDisappear(): void {
    if (this.microphoneTimer !== -1) {
      clearInterval(this.microphoneTimer)
      this.microphoneTimer = -1
    }
  }

  private refreshMicrophoneSession(): void {
    try {
      this.microphoneSessionValid = this.viewerMicrophoneSession > 0 &&
        qemu.getMicrophoneSession(this.vmName) === this.viewerMicrophoneSession
    } catch (_) {
      this.microphoneSessionValid = false
    }
  }

  private matchesMicrophone(): boolean {
    return this.viewerMicrophoneSession > 0 && this.microphoneVm === this.vmName &&
      this.microphoneSession === this.viewerMicrophoneSession
  }

  private microphoneFeedback(): string {
    if (!this.microphoneSessionValid || !this.matchesMicrophone()) {
      return '本窗口录音未启用'
    }
    if (this.microphoneStatus === 'suspended') {
      return '窗口切换中，录音已暂停'
    }
    return this.microphoneMessage
  }

  private canCancelMicrophone(): boolean {
    return this.microphoneEnabled || this.microphoneBusy || this.microphoneStatus === 'suspended'
  }

  private microphoneCancelLabel(): string {
    if (!this.matchesMicrophone()) {
      return this.microphoneBusy ? '取消其他窗口请求' : '关闭其他窗口录音'
    }
    return this.microphoneBusy || this.microphoneStatus === 'suspended' ? '取消录音' : '关闭麦克风'
  }

  private enableMicrophone(useSettings: boolean = false): void {
    this.refreshMicrophoneSession()
    if (!this.microphoneSessionValid) return
    const context = getContext(this) as common.UIAbilityContext
    void MicrophoneManager.getInstance().enable(this.vmName, useSettings, context)
  }
  
  private setupConsoleCallback(): void {
    try {
      QemuVMManager.getInstance().setConsoleCallback((data: string) => {
        this.appendOutput(data)
      })
    } catch (e) {
      hilog.error(0x0000, 'ConsoleWindow', '设置控制台回调失败: %{public}s', (e as Error).message)
    }
  }
  
  private appendOutput(text: string): void {
    // 按行分割
    const lines = text.split('\n')
    for (const line of lines) {
      this.consoleOutput.push(line)
    }
    
    // 限制最大行数
    if (this.consoleOutput.length > this.maxLines) {
      this.consoleOutput = this.consoleOutput.slice(-this.maxLines)
    }
    
    // 滚动到底部
    setTimeout(() => {
      this.scrollerRef.scrollEdge(Edge.Bottom)
    }, 50)
  }
  
  private sendCommand(): void {
    if (!this.inputText.trim()) return
    
    const cmd = this.inputText
    this.inputText = ''
    
    // 显示输入的命令
    this.appendOutput(`\x1b[36m> ${cmd}\x1b[0m`)
    
    // 发送到 QEMU
    try {
      QemuVMManager.getInstance().writeToVmConsole(cmd + '\n')
    } catch (e) {
      this.appendOutput(`\x1b[31m[错误] 发送失败: ${(e as Error).message}\x1b[0m`)
    }
  }
  
  build() {
    Column() {
      // 顶部状态栏
      Row() {
        // VM 名称
        Text(`🔧 ${this.vmName} - 串口控制台`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        
        Blank()
        
        // 连接状态
        Row() {
          Circle()
            .width(8)
            .height(8)
            .fill(this.isConnected ? '#34C759' : '#FF3B30')
          Text(this.isConnected ? 'TTY' : '断开')
            .fontSize(12)
            .fontColor('#AAAAAA')
            .margin({ left: 6 })
        }
        
        // 清屏按钮
        Button() {
          Text('🗑️').fontSize(14)
        }
        .type(ButtonType.Circle)
        .width(32)
        .height(32)
        .backgroundColor('rgba(255, 255, 255, 0.1)')
        .margin({ left: 12 })
        .onClick(() => {
          this.consoleOutput = []
        })
        
        // 关闭按钮
        Button() {
          Text('✕').fontSize(16).fontColor('#888888')
        }
        .type(ButtonType.Circle)
        .width(32)
        .height(32)
        .backgroundColor('rgba(255, 255, 255, 0.1)')
        .margin({ left: 8 })
        .onClick(() => {
          this.closeWindow()
        })
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .backgroundColor('rgba(30, 30, 30, 0.95)')

      Row({ space: 8 }) {
        Text(this.microphoneFeedback()).fontSize(12).fontColor('#CCCCCC').layoutWeight(1)
        if (this.canCancelMicrophone()) {
          Button(this.microphoneCancelLabel()).fontSize(12).height(32)
            .onClick((): void => { MicrophoneManager.getInstance().disable() })
        }
        if (!this.matchesMicrophone() || !this.canCancelMicrophone()) {
          Button('启用麦克风').fontSize(12).height(32)
            .enabled(this.microphoneSessionValid && !this.microphoneBusy)
            .onClick((): void => { this.enableMicrophone() })
        }
        if (this.matchesMicrophone() && this.microphoneStatus === 'denied' && !this.microphoneBusy) {
          Button('重新授权').fontSize(12).height(32)
            .enabled(this.microphoneSessionValid)
            .onClick((): void => { this.enableMicrophone(true) })
        }
      }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
      
      // 控制台输出区域
      Scroll(this.scrollerRef) {
        Column() {
          ForEach(this.consoleOutput, (line: string, index: number) => {
            Text(this.parseAnsiColors(line))
              .fontSize(13)
              .fontFamily('monospace')
              .fontColor('#00FF00')
              .width('100%')
              .textAlign(TextAlign.Start)
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#0D0D0D')
      .scrollBar(BarState.Auto)
      
      // 输入区域
      Row() {
        Text('>')
          .fontSize(14)
          .fontFamily('monospace')
          .fontColor('#00FF00')
          .margin({ right: 8 })
        
        TextInput({ text: this.inputText, placeholder: '输入命令...' })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontFamily('monospace')
          .fontColor('#00FF00')
          .placeholderColor('#336633')
          .backgroundColor('rgba(0, 255, 0, 0.05)')
          .borderRadius(8)
          .caretColor('#00FF00')
          .onChange((val: string) => {
            this.inputText = val
          })
          .onSubmit(() => {
            this.sendCommand()
          })
        
        Button('发送')
          .type(ButtonType.Capsule)
          .height(36)
          .fontSize(13)
          .backgroundColor('#007AFF')
          .margin({ left: 12 })
          .onClick(() => {
            this.sendCommand()
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .backgroundColor('rgba(30, 30, 30, 0.95)')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D0D0D')
  }
  
  // 简单的 ANSI 颜色解析（仅用于显示，实际颜色通过样式控制）
  private parseAnsiColors(text: string): string {
    // 移除 ANSI 转义序列，保留纯文本
    return text.replace(/\x1b\[[0-9;]*m/g, '')
  }
  
  private closeWindow(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    ctx.terminateSelf()
  }
}

