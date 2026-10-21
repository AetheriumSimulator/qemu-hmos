/** Window identities and one-shot internal handoffs; no platform APIs or timers. */
class MicrophoneWindow {
  id: number = 0
  kind: string = ''
  vmName: string = ''
  session: number = 0
  attached: boolean = false
  ready: boolean = false
  pageVisible: boolean = true
  foreground: boolean = false
  shown: number = -1
  visibility: number = -1
}

class MicrophoneHandoff {
  id: number = 0
  source: number = 0
  target: number = 0
  kind: string = ''
  vmName: string = ''
  session: number = 0
}

export class MicrophoneWindows {
  private windows: Map<number, MicrophoneWindow> = new Map()
  private nextId: number = 1
  private nextHandoff: number = 1
  private handoff: MicrophoneHandoff | null = null
  private appForeground: boolean = false
  private guardsReady: boolean = false
  private showing: (id: number) => boolean
  private currentSession: (vmName: string) => number

  constructor(showing: (id: number) => boolean, currentSession: (vmName: string) => number) {
    this.showing = showing
    this.currentSession = currentSession
  }

  register(kind: string, vmName: string, session: number, handoff: number = 0): number {
    const record = new MicrophoneWindow()
    record.id = this.nextId++
    record.kind = kind
    record.vmName = vmName
    record.session = session
    this.windows.set(record.id, record)
    const pending = this.handoff
    if (pending && pending.id === handoff && pending.target === 0 &&
      pending.kind === kind && pending.vmName === vmName && pending.session === session) {
      pending.target = record.id
    }
    return record.id
  }

  bindEntry(id: number, vmName: string, session: number): void {
    const record = this.windows.get(id)
    if (record && record.kind === 'EntryAbility') {
      record.vmName = vmName
      record.session = session
    }
  }

  attached(id: number): void {
    const record = this.windows.get(id)
    if (record) record.attached = true
  }

  ready(id: number, value: boolean = true): void {
    const record = this.windows.get(id)
    if (record) record.ready = value
  }

  foreground(id: number, value: boolean): void {
    const record = this.windows.get(id)
    if (record) record.foreground = value
  }

  pageVisibility(id: number, value: boolean): void {
    const record = this.windows.get(id)
    if (record) record.pageVisible = value
  }

  visibility(id: number, value: boolean): void {
    const record = this.windows.get(id)
    if (record) record.visibility = value ? 1 : 0
  }

  shown(id: number, value: boolean): void {
    const record = this.windows.get(id)
    if (record) record.shown = value ? 1 : 0
  }

  remove(id: number): boolean {
    this.windows.delete(id)
    if (this.handoff && (this.handoff.source === id || this.handoff.target === id)) {
      this.handoff = null
      return true
    }
    return false
  }

  applicationForeground(value: boolean): void {
    this.appForeground = value
    if (!value) this.cancelHandoff()
  }

  guards(value: boolean): void {
    this.guardsReady = value
    if (!value) this.cancelHandoff()
  }

  cancelHandoff(): void {
    this.handoff = null
  }

  failHandoff(id: number): boolean {
    if (!this.handoff || this.handoff.id !== id) return false
    this.cancelHandoff()
    return true
  }

  hasHandoff(vmName: string, session: number): boolean {
    return this.handoff !== null && this.handoff.vmName === vmName &&
      this.handoff.session === session && this.safeSession(vmName, session)
  }

  private safeSession(vmName: string, session: number): boolean {
    if (!this.appForeground || !this.guardsReady || session <= 0) return false
    try {
      return this.currentSession(vmName) === session
    } catch (_) {
      return false
    }
  }

  visible(id: number, vmName: string, session: number): boolean {
    const record = this.windows.get(id)
    if (!record || !this.safeSession(vmName, session) || !record.attached ||
      !record.ready || !record.pageVisible || !record.foreground || record.shown === 0 ||
      record.visibility !== 1 ||
      record.vmName !== vmName || record.session !== session) return false
    try {
      // A positive snapshot never overrides an explicit visibility=false veto.
      return this.showing(id)
    } catch (_) {
      return false
    }
  }

  anyVisible(vmName: string, session: number): boolean {
    for (const record of this.windows.values()) {
      if (this.visible(record.id, vmName, session)) return true
    }
    return false
  }

  beginHandoff(source: number, kind: string, vmName: string, session: number): number {
    this.cancelHandoff()
    if ((kind !== 'VNCWindowAbility' && kind !== 'ConsoleWindowAbility') ||
      !this.visible(source, vmName, session)) return 0
    const pending = new MicrophoneHandoff()
    pending.id = this.nextHandoff++
    pending.source = source
    pending.kind = kind
    pending.vmName = vmName
    pending.session = session
    this.handoff = pending
    return pending.id
  }

  completeHandoff(vmName: string, session: number): boolean {
    const pending = this.handoff
    if (!pending || !this.hasHandoff(vmName, session) ||
      !this.visible(pending.target, vmName, session)) return false
    this.cancelHandoff()
    return true
  }
}
