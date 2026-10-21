import common from '@ohos.app.ability.common'
import hilog from '@ohos.hilog'
import image from '@ohos.multimedia.image'
import qemu from 'qemu_hmos'
import { MicrophoneManager } from '../managers/MicrophoneManager'

interface VncPoint {
  x: number
  y: number
}

interface QemuVncInputApi {
  vncSendPointer?: (id: number, x: number, y: number, buttonMask: number) => boolean
  vncSendKey?: (id: number, keysym: number, down: boolean) => boolean
}
interface ExtendedKeyEvent {
  keyText?: string
  keyCode?: number
}

@Entry({ useSharedStorage: true })
@Component
struct VNCNativeViewer {
  // WindowStage supplies a separate LocalStorage for each Ability instance.
  @LocalStorageProp('vnc_vmName') vmName: string = ''
  @LocalStorageProp('vnc_host') vncHost: string = '127.0.0.1'
  @LocalStorageProp('vnc_port') vncPort: number = 5901
  @LocalStorageProp('viewer_microphoneSession') viewerMicrophoneSession: number = 0
  @StorageLink('microphoneVm') microphoneVm: string = ''
  @StorageLink('microphoneSession') microphoneSession: number = 0
  @StorageLink('microphoneEnabled') microphoneEnabled: boolean = false
  @StorageLink('microphoneBusy') microphoneBusy: boolean = false
  @StorageLink('microphoneStatus') microphoneStatus: string = 'disabled'
  @StorageLink('microphoneMessage') microphoneMessage: string = '麦克风已关闭'
  @State microphoneSessionValid: boolean = false
  
  @State status: string = '准备中'
  @State connected: boolean = false
  @State frameWidth: number = 640
  @State frameHeight: number = 480
  @State pixelMap: image.PixelMap | null = null
  @State hasFocus: boolean = false
  @State viewWidth: number = 0
  @State viewHeight: number = 0
  private sessionId: number = -1
  
  private renderTimer: number = -1
  private renderInFlight: boolean = false
  private buttonMask: number = 0  // VNC button mask (1=left,2=middle,4=right,8=wheel up,16=wheel down)
  private lastInputLogTs: number = 0
  private microphoneTimer: number = -1

  private inputApi(): QemuVncInputApi {
    return qemu as QemuVncInputApi
  }

  aboutToAppear() {
    this.refreshMicrophoneSession()
    if (this.microphoneTimer === -1) {
      this.microphoneTimer = setInterval((): void => { this.refreshMicrophoneSession() }, 500)
    }

    hilog.info(0x0000, 'VNC_NATIVE', `初始化原生VNC: VM=${this.vmName}, ${this.vncHost}:${this.vncPort}`)

    // 自动连接（如果 VM 已经在运行）
    this.autoConnect()
  }

  aboutToDisappear() {
    if (this.microphoneTimer !== -1) {
      clearInterval(this.microphoneTimer)
      this.microphoneTimer = -1
    }
    this.stopRendering()
    this.disconnectNative()
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
    // Never adopt a replacement session just because its VM name is unchanged.
    this.refreshMicrophoneSession()
    if (!this.microphoneSessionValid) return
    const context = getContext(this) as common.UIAbilityContext
    void MicrophoneManager.getInstance().enable(this.vmName, useSettings, context)
  }

  async autoConnect() {
    if (!qemu.vncAvailable || !qemu.vncCreate || !qemu.vncConnect || !qemu.vncGetFrame || !qemu.vncDisconnect) {
      this.status = '❌ 原生VNC不可用'
      return
    }

    this.status = `🔗 连接 ${this.vncHost}:${this.vncPort}...`
    
    // 创建/连接会话
    if (!qemu.vncAvailable()) {
      this.status = '❌ 原生VNC不可用'
      return
    }
    if (this.sessionId <= 0) {
      this.sessionId = qemu.vncCreate()
    }
    const connected = qemu.vncConnect(this.sessionId, this.vncHost, this.vncPort)
    this.connected = connected

    if (connected) {
      this.status = '✅ 已连接'
      this.startRendering()
    } else {
      this.status = '❌ 连接失败，请确保 VM 已启动'
    }
  }

  startRendering() {
    if (this.renderTimer >= 0) return
    
    hilog.info(0x0000, 'VNC_NATIVE', '开始帧渲染循环')
    
    // 限帧：原生 VNC 路径主要瓶颈在 PixelMap 更新/内存拷贝，先默认 10 FPS
    this.renderTimer = setInterval(() => {
      this.renderFrame()
    }, 100)
  }

  stopRendering() {
    if (this.renderTimer >= 0) {
      clearInterval(this.renderTimer)
      this.renderTimer = -1
      hilog.info(0x0000, 'VNC_NATIVE', '停止帧渲染循环')
    }
  }

  async renderFrame() {
    if (!this.connected) return
    if (this.renderInFlight) return
    this.renderInFlight = true

    try {
      if (!qemu.vncGetFrame || this.sessionId <= 0) return
      const frame = qemu.vncGetFrame(this.sessionId)
      if (!frame || !frame.pixels) return

      this.frameWidth = frame.width
      this.frameHeight = frame.height

      const pixels = new Uint8Array(frame.pixels)

      // 创建新 PixelMap（已显著降压：仅新帧才触发 + 10FPS + 无 BGRA->RGBA 转换）
      const opts: image.InitializationOptions = {
        size: { width: frame.width, height: frame.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.OPAQUE
      }

      const next = await image.createPixelMap(pixels.buffer, opts)
      if (this.pixelMap) this.pixelMap.release()
      this.pixelMap = next

    } catch (e) {
      hilog.error(0x0000, 'VNC_NATIVE', `渲染帧失败: ${(e as Error).message}`)
    } finally {
      this.renderInFlight = false
    }
  }

  private goBack() {
    this.stopRendering()
    this.disconnectNative()
    const context = getContext(this) as common.UIAbilityContext
    void context.terminateSelf()
  }

  build() {
    Column() {
      // 顶部状态栏
      Row() {
        Button('返回')
          .onClick(() => this.goBack())
          .height(36)
          .backgroundColor('#333')
        
        Text(this.vmName || 'VNC')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFF')
          .margin({ left: 12 })
        
        Blank()
        
        Text(this.status)
          .fontSize(12)
          .fontColor(this.status.includes('❌') ? '#FF3B30' : 
                    this.status.includes('✅') ? '#34C759' : '#888')
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#1A1A1A')

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
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })

      // VNC 显示区域
      Stack() {
        if (this.pixelMap) {
          Image(this.pixelMap)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .focusable(true)
            // 关键：点到画面就自动获得焦点，否则键盘事件很容易收不到
            .focusOnTouch(true)
            .onFocus(() => { this.hasFocus = true })
            .onBlur(() => { this.hasFocus = false })
            .onAreaChange((_, newArea) => {
              const w = Number(newArea.width)
              const h = Number(newArea.height)
              this.viewWidth = isNaN(w) ? 0 : w
              this.viewHeight = isNaN(h) ? 0 : h
            })
            // 键盘：需要组件获得焦点才能收到 KeyEvent（HarmonyOS 输入模型）
            .onKeyEvent((event: KeyEvent) => {
              // 最小可用映射：字母数字/常见控制键（键盘输入的核心参考：HarmonyOS input overview）
              const keysym = this.mapKeyToX11Keysym(event)
              if (keysym > 0) {
                const api = this.inputApi()
                if (api.vncSendKey && this.sessionId > 0) {
                  api.vncSendKey(this.sessionId, keysym, event.type === KeyType.Down)
                  // 节流日志：确认 ArkTS 确实收到了键盘并下发到了 Native
                  const now = Date.now()
                  if (now - this.lastInputLogTs > 1500) {
                    this.lastInputLogTs = now
                    hilog.info(0x0000, 'VNC_NATIVE', `KeyEvent down=${event.type === KeyType.Down} keysym=0x${keysym.toString(16)}`)
                  }
                }
                return true
              }
              return false
            })
            // 触摸/鼠标：把指针事件转换为 VNC pointer
            .onTouch((ev: TouchEvent) => {
              this.handleTouch(ev)
            })
        } else {
          Column() {
            if (!this.connected) {
              Text('未连接')
                .fontSize(20)
                .fontColor('#666')
              
              Button('重新连接')
                .onClick(() => this.autoConnect())
                .margin({ top: 16 })
                .backgroundColor('#007AFF')
            } else {
              LoadingProgress()
                .width(40)
                .height(40)
                .color('#007AFF')
              
              Text('等待画面...')
                .fontSize(14)
                .fontColor('#666')
                .margin({ top: 12 })
            }
          }
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#000')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1A1A1A')
  }

  private clampPos(x: number, y: number): VncPoint {
    const xx = Math.max(0, Math.min(this.frameWidth - 1, Math.floor(x)))
    const yy = Math.max(0, Math.min(this.frameHeight - 1, Math.floor(y)))
    return { x: xx, y: yy }
  }

  // 把组件坐标映射到远端 framebuffer 坐标（ImageFit.Contain 简化版：按比例缩放，居中）
  private mapPointToFrame(localX: number, localY: number, viewW: number, viewH: number): VncPoint {
    if (this.frameWidth <= 0 || this.frameHeight <= 0 || viewW <= 0 || viewH <= 0) {
      return { x: 0, y: 0 }
    }
    const scale = Math.min(viewW / this.frameWidth, viewH / this.frameHeight)
    const drawW = this.frameWidth * scale
    const drawH = this.frameHeight * scale
    const offsetX = (viewW - drawW) / 2
    const offsetY = (viewH - drawH) / 2
    const fx = (localX - offsetX) / scale
    const fy = (localY - offsetY) / scale
    return this.clampPos(fx, fy)
  }

  private handleTouch(ev: TouchEvent): void {
    if (!this.connected) return
    if (this.frameWidth <= 0 || this.frameHeight <= 0) return
    if (!ev.touches || ev.touches.length === 0) return

    // ArkUI TouchEvent: 使用第一个触点，按 press/move/release 模拟左键
    const t = ev.touches[0]
    const pt = this.mapPointToFrame(t.x, t.y, this.viewWidth, this.viewHeight)

    if (ev.type === TouchType.Down) {
      this.buttonMask = 1
      const api = this.inputApi()
      if (api.vncSendPointer && this.sessionId > 0) api.vncSendPointer(this.sessionId, pt.x, pt.y, this.buttonMask)
    } else if (ev.type === TouchType.Move) {
      const api = this.inputApi()
      if (api.vncSendPointer && this.sessionId > 0) api.vncSendPointer(this.sessionId, pt.x, pt.y, this.buttonMask)
    } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
      this.buttonMask = 0
      const api = this.inputApi()
      if (api.vncSendPointer && this.sessionId > 0) api.vncSendPointer(this.sessionId, pt.x, pt.y, this.buttonMask)
    }
  }

  private disconnectNative(): void {
    try {
      if (qemu.vncDisconnect && this.sessionId > 0) qemu.vncDisconnect(this.sessionId)
    } catch (_) {}
    this.sessionId = -1
    this.connected = false
  }

  // 极简 keysym 映射（X11 keysyms）
  private mapKeyToX11Keysym(event: KeyEvent): number {
    // 仅处理按下/抬起
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) return 0
    // 优先使用 keyText（不同设备/系统版本 keyCode 可能差异很大）
    const anyEvent = event as ExtendedKeyEvent
    const keyText = (typeof anyEvent.keyText === 'string') ? anyEvent.keyText : ''
    if (keyText.length === 1) {
      // 字符键：直接用 ASCII（X11 keysyms 对于基本 ASCII 与码点一致）
      return keyText.charCodeAt(0)
    }
    // 常见功能键（尽量用 keyText 名称兜底）
    if (keyText === 'Enter') return 0xff0d
    if (keyText === 'Backspace') return 0xff08
    if (keyText === 'Tab') return 0xff09
    if (keyText === 'Escape' || keyText === 'Esc') return 0xff1b
    if (keyText === 'ArrowLeft') return 0xff51
    if (keyText === 'ArrowUp') return 0xff52
    if (keyText === 'ArrowRight') return 0xff53
    if (keyText === 'ArrowDown') return 0xff54

    const code = (typeof anyEvent.keyCode === 'number') ? anyEvent.keyCode : 0
    // 字母 A-Z
    if (code >= 2017 && code <= 2042) { // KeyCode.KEY_A..KEY_Z (HarmonyOS 常见范围，若不一致可后续按实际修正)
      const a = 'a'.charCodeAt(0)
      return a + (code - 2017)
    }
    // 数字 0-9
    if (code >= 2007 && code <= 2016) { // KeyCode.KEY_0..KEY_9
      const zero = '0'.charCodeAt(0)
      return zero + (code - 2007)
    }

    // 常用控制键（keysyms）
    // Enter=0xff0d, BackSpace=0xff08, Tab=0xff09, Escape=0xff1b, Left/Up/Right/Down=0xff51..0xff54
    if (code === 2050) return 0xff0d // Enter
    if (code === 2051) return 0xff08 // Backspace
    if (code === 2049) return 0xff09 // Tab
    if (code === 2052) return 0xff1b // Escape
    if (code === 2010) return 0xff51 // Left
    if (code === 2011) return 0xff52 // Up
    if (code === 2012) return 0xff53 // Right
    if (code === 2013) return 0xff54 // Down

    // Shift/Ctrl/Alt
    if (code === 2044) return 0xffe1 // Shift_L
    if (code === 2045) return 0xffe3 // Control_L
    if (code === 2046) return 0xffe9 // Alt_L

    return 0
  }
}
