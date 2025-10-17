import UIAbility from '@ohos.app.ability.UIAbility'

export class BinaryMessenger {}

export class FlutterExecutor {
  messenger: BinaryMessenger

  constructor() {
    this.messenger = new BinaryMessenger()
  }
}

export class FlutterEngine {
  dartExecutor: FlutterExecutor

  constructor() {
    this.dartExecutor = new FlutterExecutor()
  }
}

export type MethodArgument = object | string | number | boolean | null

export interface MethodCall {
  method: string
  args?: MethodArgument
  arguments?: MethodArgument
}

export interface MethodResult {
  success(value?: MethodArgument): void
  error(code: string, message?: string, details?: MethodArgument): void
}

export interface MethodCallHandler {
  onMethodCall(call: MethodCall, result: MethodResult): Promise<void>
}

export class MethodChannel {
  private handler?: MethodCallHandler
  private executor: FlutterExecutor
  private name: string

  constructor(executor: FlutterExecutor, name: string) {
    this.executor = executor
    this.name = name
  }

  setMethodCallHandler(handler: MethodCallHandler): void {
    this.handler = handler
  }

  async simulateCall(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.handler) {
      await this.handler.onMethodCall(call, result)
    }
  }

  getExecutor(): FlutterExecutor {
    return this.executor
  }

  getName(): string {
    return this.name
  }
}

export class FlutterAbility extends UIAbility {
  configureFlutterEngine(_engine: FlutterEngine): void {}
}
