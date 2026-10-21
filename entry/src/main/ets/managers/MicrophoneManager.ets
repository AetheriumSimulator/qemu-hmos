import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import bundleManager from '@ohos.bundle.bundleManager'
import common from '@ohos.app.ability.common'
import ApplicationStateChangeCallback from '@ohos.app.ability.ApplicationStateChangeCallback'
import commonEventManager from '@ohos.commonEventManager'
import power from '@ohos.power'
import screenLock from '@ohos.screenLock'
import window from '@ohos.window'
import qemu from 'qemu_hmos'
import { MicrophoneConsent, MicrophoneConsentPort, MicrophoneConsentState } from './MicrophoneConsent'
import { MicrophoneWindows } from './MicrophoneWindows'

interface MicrophoneNative {
  getMicrophoneSession(vmName: string): number
  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean
  getMicrophoneStatus(vmName: string): string
}

class MicrophoneAbility {
  context: common.UIAbilityContext
  win: window.Window | null = null
  onEvent: (event: window.WindowEventType) => void = (): void => {}
  onVisibility: (visible: boolean) => void = (): void => {}

  constructor(context: common.UIAbilityContext) {
    this.context = context
  }
}

// One application policy, with distinct identities for every multiton window.
// Handoffs retain approved intent only; an unproven visibility gap closes Native.
export class MicrophoneManager implements MicrophoneConsentPort {
  private static instance: MicrophoneManager
  private native: MicrophoneNative = qemu as MicrophoneNative
  private consent: MicrophoneConsent
  private windows: MicrophoneWindows
  private abilities: Map<number, MicrophoneAbility> = new Map()
  private application: common.ApplicationContext | null = null
  private subscriber: commonEventManager.CommonEventSubscriber | null = null
  private guardsReady: boolean = false
  private appForeground: boolean = false
  private screenBlocked: boolean = true
  private epoch: number = 0
  private requestOwner: number = 0
  private preflightOwner: number = 0
  private launchHandoff: number = 0
  private timer: number = -1
  private reconciling: boolean = false
  private applicationEvents: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => {
      this.appForeground = true
      this.windows.applicationForeground(true)
      this.updateTimer()
      this.reconcile()
    },
    onApplicationBackground: (): void => {
      this.appForeground = false
      this.windows.applicationForeground(false)
      this.hardClose('应用已进入后台，麦克风已关闭；返回后请重新启用')
      this.updateTimer()
    }
  }

  private constructor() {
    this.windows = new MicrophoneWindows((id: number): boolean => {
      const ability = this.abilities.get(id)
      return ability !== undefined && ability.win !== null && ability.win.isWindowShowing()
    }, (vmName: string): number => this.native.getMicrophoneSession(vmName))
    this.consent = new MicrophoneConsent(this, (state: MicrophoneConsentState): void => {
      AppStorage.setOrCreate<string>('microphoneVm', state.vmName)
      AppStorage.setOrCreate<number>('microphoneSession', state.targetSession)
      AppStorage.setOrCreate<boolean>('microphoneEnabled', state.enabled)
      AppStorage.setOrCreate<boolean>('microphoneBusy', state.busy)
      AppStorage.setOrCreate<string>('microphoneStatus', state.status)
      AppStorage.setOrCreate<string>('microphoneMessage', state.message)
      if (!state.enabled && !state.busy && state.status !== 'suspended') {
        this.windows.cancelHandoff()
      }
    })
  }

  static getInstance(): MicrophoneManager {
    if (!MicrophoneManager.instance) MicrophoneManager.instance = new MicrophoneManager()
    return MicrophoneManager.instance
  }

  private install(context: common.UIAbilityContext): void {
    if (this.application) return
    this.application = context.getApplicationContext()
    try {
      this.application.on('applicationStateChange', this.applicationEvents)
      this.subscriber = commonEventManager.createSubscriberSync({ events: [
        commonEventManager.Support.COMMON_EVENT_SCREEN_LOCKED,
        commonEventManager.Support.COMMON_EVENT_SCREEN_UNLOCKED,
        commonEventManager.Support.COMMON_EVENT_SCREEN_OFF
      ] })
      commonEventManager.subscribe(this.subscriber, (error, data): void => {
        if (error) {
          this.guardsReady = false
          this.windows.guards(false)
          this.hardClose('无法监听锁屏状态，麦克风保持关闭')
          return
        }
        if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_UNLOCKED) {
          // Unlock never restores consent or a cancelled handoff.
          this.screenBlocked = false
          this.windows.guards(this.guardsReady)
          return
        }
        this.screenBlocked = true
        this.windows.guards(false)
        this.hardClose('屏幕已锁定或关闭，麦克风已关闭；请重新启用')
      })
      this.guardsReady = true
    } catch (_) {
      this.guardsReady = false
      this.windows.guards(false)
      this.hardClose('当前设备无法提供窗口或锁屏保护，麦克风保持关闭')
    }
  }

  registerAbility(context: common.UIAbilityContext, kind: string,
    vmName: string = '', session: number = 0, handoff: number = 0): number {
    this.install(context)
    const id = this.windows.register(kind, vmName, session, handoff)
    this.abilities.set(id, new MicrophoneAbility(context))
    this.updateTimer()
    return id
  }

  attachWindow(id: number, win: window.Window): void {
    const ability = this.abilities.get(id)
    if (!ability || ability.win) return
    ability.win = win
    ability.onEvent = (event: window.WindowEventType): void => {
      if (this.abilities.get(id) !== ability) return
      if (event === window.WindowEventType.WINDOW_HIDDEN) {
        this.windows.shown(id, false)
        this.ownerHidden(id)
      } else if (event === window.WindowEventType.WINDOW_SHOWN) {
        this.windows.shown(id, true)
      }
      this.reconcile()
    }
    ability.onVisibility = (visible: boolean): void => {
      if (this.abilities.get(id) !== ability) return
      this.windows.visibility(id, visible)
      if (!visible) this.ownerHidden(id)
      this.reconcile()
    }
    try {
      win.on('windowEvent', ability.onEvent)
      win.on('windowVisibilityChange', ability.onVisibility)
      this.windows.attached(id)
      this.reconcile()
    } catch (_) {
      this.windowFailed(id)
    }
  }

  contentReady(id: number): void {
    this.windows.ready(id)
    this.reconcile()
  }

  pageVisible(context: common.UIAbilityContext, visible: boolean): void {
    const id = this.owner(context)
    this.windows.pageVisibility(id, visible)
    if (!visible) this.ownerHidden(id)
    this.reconcile()
  }

  foreground(id: number, foreground: boolean): void {
    this.windows.foreground(id, foreground)
    if (!foreground) this.ownerHidden(id)
    this.reconcile()
  }

  removeAbility(id: number): void {
    const ability = this.abilities.get(id)
    if (!ability) return
    this.ownerHidden(id)
    this.abilities.delete(id)
    if (ability.win) {
      try { ability.win.off('windowEvent', ability.onEvent) } catch (_) {}
      try { ability.win.off('windowVisibilityChange', ability.onVisibility) } catch (_) {}
    }
    if (this.requestOwner === id) this.requestOwner = 0
    if (this.windows.remove(id)) this.hardClose('窗口交接已取消，麦克风已关闭')
    this.reconcile()
    this.updateTimer()
  }

  windowFailed(id: number): void {
    this.removeAbility(id)
  }

  private owner(context: common.UIAbilityContext): number {
    for (const entry of this.abilities.entries()) {
      if (entry[1].context === context) return entry[0]
    }
    return 0
  }

  private activeScreen(): boolean {
    try { return power.isActive() } catch (_) { return false }
  }

  private hardClose(message: string): void {
    this.epoch++
    this.preflightOwner = 0
    this.launchHandoff = 0
    this.windows.cancelHandoff()
    this.consent.setForeground(false)
    this.consent.disable(message)
  }

  private ownerHidden(id: number): void {
    const state = this.consent.snapshot()
    if (id > 0 && (this.preflightOwner === id ||
      (state.busy && state.status === 'requesting' && this.requestOwner === id))) {
      this.hardClose('授权窗口已离开前台，已取消启用麦克风')
    }
  }

  private reconcile(): void {
    if (this.reconciling) return
    this.reconciling = true
    try {
      const state = this.consent.snapshot()
      if (state.session <= 0) return
      if (!this.appForeground || !this.guardsReady || this.screenBlocked || !this.activeScreen()) {
        this.hardClose('无法确认应用与屏幕处于前台，麦克风已关闭；请重新启用')
        return
      }
      if (state.busy && state.status === 'requesting' &&
        !this.windows.visible(this.requestOwner, state.vmName, state.session)) {
        this.hardClose('授权窗口已不可见，已取消启用麦克风')
        return
      }
      if (this.windows.anyVisible(state.vmName, state.session)) {
        if (state.status === 'suspended') {
          if (state.busy) return
          if (this.windows.completeHandoff(state.vmName, state.session)) {
            this.consent.setForeground(true)
            void this.consent.resume()
          }
        } else {
          this.windows.completeHandoff(state.vmName, state.session)
          this.consent.setForeground(true)
        }
      } else if (this.windows.hasHandoff(state.vmName, state.session) && !state.busy) {
        if (state.enabled) {
          if (!this.consent.suspend()) this.windows.cancelHandoff()
        } else if (state.status !== 'suspended') {
          this.hardClose('无法确认录音授权，窗口切换后请重新启用')
        }
      } else {
        this.hardClose('没有可确认的同会话可见窗口，麦克风已关闭；请重新启用')
      }
    } finally {
      this.reconciling = false
    }
  }

  private updateTimer(): void {
    if (this.timer !== -1) clearInterval(this.timer)
    this.timer = -1
    if (this.appForeground && this.abilities.size > 0) {
      // Revocation/status reconciliation, never a visibility grace period.
      this.timer = setInterval((): void => {
        this.reconcile()
        void this.consent.synchronize()
      }, 500)
    }
  }

  beginHandoff(context: common.UIAbilityContext, kind: string, vmName: string): number {
    const state = this.consent.snapshot()
    if (state.status === 'suspended' || (state.session > 0 && state.vmName !== vmName)) {
      this.hardClose('窗口目标已变化，麦克风已关闭；请重新启用')
      return 0
    }
    this.launchHandoff = 0
    if (!state.enabled || state.busy) {
      this.windows.cancelHandoff()
      return 0
    }
    this.reconcile()
    if (!this.consent.snapshot().enabled) return 0
    this.launchHandoff = this.windows.beginHandoff(this.owner(context), kind, vmName, state.session)
    return this.launchHandoff
  }

  handoffFailed(id: number): void {
    if (id > 0 && (this.windows.failHandoff(id) || this.launchHandoff === id)) {
      this.hardClose('打开窗口失败，麦克风已关闭；请重新启用')
    }
  }

  async enable(vmName: string, useSettings: boolean = false,
    context?: common.UIAbilityContext): Promise<void> {
    if (this.consent.snapshot().busy || !context) return
    this.disable()
    const epoch = this.epoch
    const id = this.owner(context)
    if (id <= 0) return
    this.preflightOwner = id
    try {
      const session = this.native.getMicrophoneSession(vmName)
      this.windows.bindEntry(id, vmName, session)
      this.requestOwner = id
      // Public since API7 (deprecated9), still in API17/18. It is only one
      // signal; positive window visibility and live event guards are also needed.
      const locked = await screenLock.isScreenLocked()
      if (epoch !== this.epoch) return
      this.screenBlocked = locked
      this.windows.guards(this.guardsReady && !locked)
      if (locked || !this.activeScreen() || !this.windows.visible(id, vmName, session)) {
        this.hardClose('无法确认当前会话窗口可见且屏幕未锁定，麦克风保持关闭')
        return
      }
      this.preflightOwner = 0
      this.consent.setForeground(true)
      await this.consent.enable(vmName, useSettings)
    } catch (_) {
      if (epoch === this.epoch) this.hardClose('无法确认窗口或锁屏状态，麦克风保持关闭')
    }
  }

  disable(): void {
    this.epoch++
    this.preflightOwner = 0
    this.launchHandoff = 0
    this.windows.cancelHandoff()
    this.consent.disable()
  }

  vmStopped(vmName: string): void {
    if (this.consent.snapshot().vmName === vmName) this.disable()
  }

  async checkPermission(): Promise<boolean> {
    const epoch = this.epoch
    const locked = await screenLock.isScreenLocked()
    if (epoch !== this.epoch || locked || this.screenBlocked || !this.activeScreen() ||
      !this.guardsReady || !this.appForeground) throw new Error('窗口或锁屏状态已变化')
    const info = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
    const result = await abilityAccessCtrl.createAtManager().checkAccessToken(
      info.appInfo.accessTokenId, 'ohos.permission.MICROPHONE')
    return result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
  }

  async requestPermission(useSettings: boolean): Promise<void> {
    const ability = this.abilities.get(this.requestOwner)
    const state = this.consent.snapshot()
    if (!ability || !this.windows.visible(this.requestOwner, state.vmName, state.session)) {
      throw new Error('麦克风授权窗口不可用')
    }
    const manager = abilityAccessCtrl.createAtManager()
    if (useSettings) {
      await manager.requestPermissionOnSetting(ability.context, ['ohos.permission.MICROPHONE'])
    } else {
      await manager.requestPermissionsFromUser(ability.context, ['ohos.permission.MICROPHONE'])
    }
  }

  getMicrophoneSession(vmName: string): number {
    return this.native.getMicrophoneSession(vmName)
  }

  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean {
    if (enabled) {
      const state = this.consent.snapshot()
      if (!this.activeScreen() || this.screenBlocked ||
        !this.windows.anyVisible(vmName, session) ||
        (state.busy && state.status === 'requesting' &&
          !this.windows.visible(this.requestOwner, vmName, session))) return false
    }
    return this.native.setMicrophoneEnabled(vmName, session, enabled)
  }

  getMicrophoneStatus(vmName: string): string {
    return this.native.getMicrophoneStatus(vmName)
  }
}
