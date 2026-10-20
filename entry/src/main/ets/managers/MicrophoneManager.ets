import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import bundleManager from '@ohos.bundle.bundleManager'
import common from '@ohos.app.ability.common'
import qemu from 'qemu_hmos'
import { MicrophoneConsent, MicrophoneConsentPort, MicrophoneConsentState } from './MicrophoneConsent'

interface MicrophoneNative {
  getMicrophoneSession(vmName: string): number
  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean
  getMicrophoneStatus(vmName: string): string
}

// EntryAbility owns consent. Opening a separate VNC/console Ability suspends
// microphone use; returning never silently restores it. Nothing is persisted.
export class MicrophoneManager implements MicrophoneConsentPort {
  private static instance: MicrophoneManager
  private context: common.UIAbilityContext | null = null
  private native: MicrophoneNative = qemu as MicrophoneNative
  private timer: number = -1
  private consent: MicrophoneConsent

  private constructor() {
    this.consent = new MicrophoneConsent(this, (state: MicrophoneConsentState): void => {
      AppStorage.setOrCreate<string>('microphoneVm', state.vmName)
      AppStorage.setOrCreate<boolean>('microphoneEnabled', state.enabled)
      AppStorage.setOrCreate<boolean>('microphoneBusy', state.busy)
      AppStorage.setOrCreate<string>('microphoneStatus', state.status)
      AppStorage.setOrCreate<string>('microphoneMessage', state.message)
    })
  }

  static getInstance(): MicrophoneManager {
    if (!MicrophoneManager.instance) {
      MicrophoneManager.instance = new MicrophoneManager()
    }
    return MicrophoneManager.instance
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context
  }

  setForeground(foreground: boolean): void {
    this.consent.setForeground(foreground)
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
    if (foreground) {
      // API17 has no public selfPermissionStateChange event. Native checks its
      // own token on Start/read/callback; this poll keeps the UI in sync.
      this.timer = setInterval((): void => { void this.consent.synchronize() }, 500)
    }
  }

  destroy(): void {
    this.setForeground(false)
    this.context = null
  }

  async enable(vmName: string, useSettings: boolean = false): Promise<void> {
    await this.consent.enable(vmName, useSettings)
  }

  disable(): void {
    this.consent.disable()
  }

  vmStopped(vmName: string): void {
    this.consent.vmStopped(vmName)
  }

  async checkPermission(): Promise<boolean> {
    const info = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
    const result = await abilityAccessCtrl.createAtManager().checkAccessToken(
      info.appInfo.accessTokenId, 'ohos.permission.MICROPHONE')
    return result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
  }

  async requestPermission(useSettings: boolean): Promise<void> {
    if (!this.context) {
      throw new Error('麦克风授权窗口不可用')
    }
    const manager = abilityAccessCtrl.createAtManager()
    if (useSettings) {
      // Public since API12; only invoked by the separate user retry button,
      // after an ordinary request was refused.
      await manager.requestPermissionOnSetting(this.context, ['ohos.permission.MICROPHONE'])
    } else {
      await manager.requestPermissionsFromUser(this.context, ['ohos.permission.MICROPHONE'])
    }
  }

  getMicrophoneSession(vmName: string): number {
    return this.native.getMicrophoneSession(vmName)
  }

  setMicrophoneEnabled(vmName: string, session: number, enabled: boolean): boolean {
    return this.native.setMicrophoneEnabled(vmName, session, enabled)
  }

  getMicrophoneStatus(vmName: string): string {
    return this.native.getMicrophoneStatus(vmName)
  }
}
