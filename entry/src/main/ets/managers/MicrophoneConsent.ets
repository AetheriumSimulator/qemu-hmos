/**
 * Per-VM-session microphone consent. Platform APIs are injected so the same
 * state machine can be exercised without requesting or opening a microphone.
 */
export interface MicrophoneConsentPort {
  checkPermission(): Promise<boolean>
  requestPermission(useSettings: boolean): Promise<void>
  getMicrophoneSession(vmName: string): number
  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean
  getMicrophoneStatus(vmName: string): string
}

export class MicrophoneConsentState {
  vmName: string = ''
  session: number = 0
  enabled: boolean = false
  busy: boolean = false
  status: string = 'disabled'
  message: string = '麦克风已关闭；播放不受影响'
}

export class MicrophoneConsent {
  private port: MicrophoneConsentPort
  private publish: (state: MicrophoneConsentState) => void
  private state: MicrophoneConsentState = new MicrophoneConsentState()
  private foreground: boolean = false
  private generation: number = 0
  private synchronizing: boolean = false
  private requestedPermission: boolean = false

  constructor(port: MicrophoneConsentPort,
    publish: (state: MicrophoneConsentState) => void) {
    this.port = port
    this.publish = publish
  }

  snapshot(): MicrophoneConsentState {
    const result = new MicrophoneConsentState()
    result.vmName = this.state.vmName
    result.session = this.state.session
    result.enabled = this.state.enabled
    result.busy = this.state.busy
    result.status = this.state.status
    result.message = this.state.message
    return result
  }

  private emit(): void {
    this.publish(this.snapshot())
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground
    if (!foreground) {
      this.disable('已离开主窗口，麦克风已关闭；返回后请重新启用')
    } else {
      // Foregrounding never requests permission or restores old consent.
      this.emit()
    }
  }

  disable(message: string = '麦克风已关闭；播放不受影响'): void {
    this.generation++
    if (this.state.session > 0) {
      try {
        this.port.setMicrophoneEnabled(this.state.vmName, this.state.session, false)
      } catch (_) {
        // Native session teardown also clears capture consent. Never re-arm here.
      }
    }
    this.state.session = 0
    this.state.enabled = false
    this.state.status = 'disabled'
    this.state.message = message
    // An OS dialog cannot be cancelled by us. Keep busy until its promise settles.
    this.emit()
  }

  vmStopped(vmName: string): void {
    if (this.state.vmName === vmName) {
      this.disable('已关闭此虚拟机的麦克风')
    }
  }

  private current(generation: number, vmName: string, session: number): boolean {
    if (generation !== this.generation) {
      return false
    }
    if (!this.foreground || this.port.getMicrophoneSession(vmName) !== session) {
      this.disable('虚拟机或窗口状态已变化，请重新启用麦克风')
      return false
    }
    return true
  }

  private fail(status: string, message: string): void {
    this.disable(message)
    this.state.status = status
    this.emit()
  }

  private applyNativeStatus(status: string): void {
    if (status === 'armed' || status === 'capturing') {
      this.state.enabled = true
      this.state.status = status
      this.state.message = status === 'capturing'
        ? '虚拟机正在使用麦克风'
        : '麦克风已允许，等待虚拟机请求录音'
      this.emit()
    } else if (status === 'blocked') {
      this.fail('blocked', '麦克风权限已撤销或采集被系统阻止；播放不受影响，请重新授权')
    } else if (status === 'unavailable') {
      this.fail('unavailable', '当前音频核心不支持麦克风控制；播放不受影响')
    } else if (status === 'error') {
      this.fail('error', '麦克风采集失败或被中断；播放不受影响，可重新启用')
    } else {
      this.fail('disabled', '麦克风已停止；播放不受影响，可重新启用')
    }
  }

  /** Only call from an explicit user enable/retry or settings action. */
  async enable(vmName: string, useSettings: boolean = false): Promise<void> {
    if (this.state.busy) {
      return
    }
    if (!this.foreground) {
      this.disable('请返回主窗口后启用麦克风')
      return
    }

    this.disable()
    this.state.vmName = vmName
    let session = 0
    try {
      session = this.port.getMicrophoneSession(vmName)
    } catch (_) {
      this.fail('unavailable', '无法读取虚拟机状态，麦克风保持关闭')
      return
    }
    if (session <= 0) {
      this.fail('disabled', '请先启动虚拟机，再启用麦克风')
      return
    }
    this.state.session = session
    this.state.busy = true
    this.state.status = 'requesting'
    this.state.message = '正在检查麦克风权限；可随时取消'
    const generation = this.generation
    this.emit()

    try {
      let granted = await this.port.checkPermission()
      if (!this.current(generation, vmName, session)) {
        return
      }
      if (!granted) {
        if (useSettings && !this.requestedPermission) {
          this.fail('denied', '请先尝试启用麦克风，再前往权限设置')
          return
        }
        await this.port.requestPermission(useSettings)
        if (!useSettings) {
          this.requestedPermission = true
        }
        if (!this.current(generation, vmName, session)) {
          return
        }
        // Do not trust the dialog result as durable authorization.
        granted = await this.port.checkPermission()
        if (!this.current(generation, vmName, session)) {
          return
        }
      }
      if (!granted) {
        this.fail('denied', '未获得麦克风权限；播放不受影响，可重试或前往权限设置')
        return
      }
      if (!this.port.setMicrophoneEnabled(vmName, session, true)) {
        const status = this.port.getMicrophoneStatus(vmName)
        if (status === 'blocked' || status === 'unavailable' || status === 'error') {
          this.applyNativeStatus(status)
        } else {
          this.fail('error', '无法启用麦克风；请检查权限及虚拟机状态后重试')
        }
        return
      }
      this.applyNativeStatus(this.port.getMicrophoneStatus(vmName))
    } catch (_) {
      if (generation === this.generation) {
        this.fail('error', '麦克风授权或状态检查失败；播放不受影响，可重试')
      }
    } finally {
      this.state.busy = false
      this.emit()
    }
  }

  /** Reconcile revocation, native failure and VM exit without prompting. */
  async synchronize(): Promise<void> {
    if (this.synchronizing || !this.foreground ||
      this.state.session <= 0 || (!this.state.enabled && !this.state.busy)) {
      return
    }
    this.synchronizing = true
    const generation = this.generation
    const vmName = this.state.vmName
    const session = this.state.session
    try {
      if (!this.current(generation, vmName, session) || this.state.busy) {
        return
      }
      const granted = await this.port.checkPermission()
      if (!this.current(generation, vmName, session)) {
        return
      }
      if (!granted) {
        this.fail('blocked', '麦克风权限已撤销；播放不受影响，请重新授权')
        return
      }
      this.applyNativeStatus(this.port.getMicrophoneStatus(vmName))
    } catch (_) {
      if (generation === this.generation) {
        this.fail('error', '无法确认麦克风权限，已关闭录音输入；可重试')
      }
    } finally {
      this.synchronizing = false
    }
  }
}
