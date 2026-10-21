/**
 * 串口控制台 独立窗口 Ability
 * 用于在新窗口中显示虚拟机的串口 TTL 终端
 */
import UIAbility from '@ohos.app.ability.UIAbility'
import Want from '@ohos.app.ability.Want'
import window from '@ohos.window'
import hilog from '@ohos.hilog'
import { MicrophoneManager } from '../managers/MicrophoneManager'

const TAG = 'ConsoleWindowAbility'

export default class ConsoleWindowAbility extends UIAbility {
  private mainWindow: window.Window | null = null
  private pageStorage: LocalStorage = new LocalStorage()
  private microphoneAbilityId: number = 0
  
  // 从 want 中获取的参数
  private vmName: string = ''
  private vmId: string = ''
  private microphoneSession: number = 0
  private microphoneHandoff: number = 0
  
  onCreate(want: Want, launchParam: object): void {
    hilog.info(0x0000, TAG, 'onCreate')
    
    // 解析启动参数
    if (want.parameters) {
      this.vmName = typeof want.parameters['vmName'] === 'string' ? String(want.parameters['vmName']) : ''
      this.vmId = String(want.parameters['vmId'] ?? '')
      const session = want.parameters['microphoneSession']
      const handoff = want.parameters['microphoneHandoff']
      if (typeof session === 'number' && Number.isSafeInteger(session) && session > 0) {
        this.microphoneSession = session
      }
      if (typeof handoff === 'number' && Number.isSafeInteger(handoff) && handoff > 0) {
        this.microphoneHandoff = handoff
      }
    }
    
    hilog.info(0x0000, TAG, '控制台参数: vmName=%{public}s vmId=%{public}s', this.vmName, this.vmId)
    
    // Each multiton Ability owns its page parameters and immutable VM session.
    this.pageStorage.setOrCreate<string>('console_vmName', this.vmName)
    this.pageStorage.setOrCreate<string>('console_vmId', this.vmId)
    this.pageStorage.setOrCreate<number>('viewer_microphoneSession', this.microphoneSession)
    this.microphoneAbilityId = MicrophoneManager.getInstance().registerAbility(
      this.context, 'ConsoleWindowAbility', this.vmName, this.microphoneSession, this.microphoneHandoff)
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'onWindowStageCreate')
    if (this.microphoneAbilityId === 0) {
      // A rebuilt stage receives a fresh identity; its one-shot handoff is spent.
      this.microphoneAbilityId = MicrophoneManager.getInstance().registerAbility(
        this.context, 'ConsoleWindowAbility', this.vmName, this.microphoneSession)
    }
    const id = this.microphoneAbilityId
    
    try {
      windowStage.getMainWindow().then((win: window.Window): void => {
        if (id !== this.microphoneAbilityId) return
        this.mainWindow = win
        MicrophoneManager.getInstance().attachWindow(id, win)

        try {
          win.setWindowDecorVisible(true)
        } catch (e) {
          hilog.warn(0x0000, TAG, '设置窗口装饰失败: %{public}s', (e as Error).message)
        }

      }).catch((err: Error): void => {
        MicrophoneManager.getInstance().windowFailed(id)
        hilog.error(0x0000, TAG, '获取主窗口失败: %{public}s', err.message)
      })
    } catch (e) {
      MicrophoneManager.getInstance().windowFailed(id)
      hilog.error(0x0000, TAG, '获取主窗口失败: %{public}s', (e as Error).message)
    }
    
    // 加载控制台页面
    try {
      windowStage.loadContent('pages/ConsoleWindow', this.pageStorage, (err, data) => {
        if (err.code) {
          MicrophoneManager.getInstance().windowFailed(id)
          hilog.error(0x0000, TAG, '加载内容失败: %{public}d, %{public}s', err.code, err.message)
          return
        }
        MicrophoneManager.getInstance().contentReady(id)
        hilog.info(0x0000, TAG, '控制台窗口内容加载成功')
      })
    } catch (e) {
      MicrophoneManager.getInstance().windowFailed(id)
      hilog.error(0x0000, TAG, '加载页面失败: %{public}s', (e as Error).message)
    }
  }

  onDestroy(): void {
    MicrophoneManager.getInstance().removeAbility(this.microphoneAbilityId)
    this.microphoneAbilityId = 0
    hilog.info(0x0000, TAG, 'onDestroy')
  }

  onWindowStageDestroy(): void {
    MicrophoneManager.getInstance().removeAbility(this.microphoneAbilityId)
    this.microphoneAbilityId = 0
    this.mainWindow = null
    hilog.info(0x0000, TAG, 'onWindowStageDestroy')
  }

  onForeground(): void {
    MicrophoneManager.getInstance().foreground(this.microphoneAbilityId, true)
    hilog.info(0x0000, TAG, 'onForeground')
  }

  onBackground(): void {
    MicrophoneManager.getInstance().foreground(this.microphoneAbilityId, false)
    hilog.info(0x0000, TAG, 'onBackground')
  }
}

