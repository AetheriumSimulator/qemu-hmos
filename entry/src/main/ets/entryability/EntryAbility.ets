import { FlutterAbility, FlutterEngine, MethodChannel, MethodCall, MethodResult, MethodCallHandler } from '../stubs/flutter_ohos'
import Want from '@ohos.app.ability.Want'
import AbilityConstant from '@ohos.app.ability.AbilityConstant'
import window from '@ohos.window'
import { logI, logE } from '../utils/Hilog'
import QemuFlutterBridge, { BridgePayload, BridgeErrorResult } from '../bridge/QemuFlutterBridge'

interface ErrorCarrier {
  error?: string
}

export default class EntryAbility extends FlutterAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam)
    logI('[EntryAbility] onCreate (Flutter shell mode)')
  }

  onDestroy(): void {
    logI('[EntryAbility] onDestroy')
    super.onDestroy()
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    logI('[EntryAbility] onWindowStageCreate -> FlutterAbility will attach Flutter UI')
    super.onWindowStageCreate(windowStage)
  }

  onWindowStageDestroy(): void {
    logI('[EntryAbility] onWindowStageDestroy')
    super.onWindowStageDestroy()
  }

  onForeground(): void {
    logI('[EntryAbility] onForeground')
    super.onForeground()
  }

  onBackground(): void {
    logI('[EntryAbility] onBackground')
    super.onBackground()
  }

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    logI('[EntryAbility] configureFlutterEngine')
    super.configureFlutterEngine(flutterEngine)

    const methodChannel = new MethodChannel(flutterEngine.dartExecutor, 'qemu.bridge')
    const handler: MethodCallHandler = {
      onMethodCall: async (call: MethodCall, result: MethodResult) => {
        logI(`[EntryAbility] MethodChannel call -> ${call.method}`)
        try {
          const args = EntryAbility.pickArgs(call)
          const payload = await QemuFlutterBridge.handle(call.method, args)
          if (EntryAbility.isErrorResult(payload)) {
            logE(`[EntryAbility] MethodChannel error: ${payload.error}`)
            result.error('QEMU_ERROR', payload.error, null)
          } else {
            result.success(payload)
          }
        } catch (err) {
          const message = err instanceof Error ? err.message : `${err}`
          logE(`[EntryAbility] MethodChannel exception: ${message}`)
          result.error('QEMU_EXCEPTION', message, null)
        }
      }
    }
    methodChannel.setMethodCallHandler(handler)
  }

  private static pickArgs(call: MethodCall): BridgePayload {
    if (call.arguments !== undefined) {
      const primary = BridgePayload.from(call.arguments)
      if (primary.hasData()) {
        return primary
      }
    }
    if (call.args !== undefined) {
      return BridgePayload.from(call.args)
    }
    return new BridgePayload()
  }

  private static isErrorResult(value: unknown): value is BridgeErrorResult {
    if (value && typeof value === 'object') {
      const carrier = value as ErrorCarrier
      return typeof carrier.error === 'string'
    }
    return false
  }
}
