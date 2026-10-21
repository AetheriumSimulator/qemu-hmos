// Platform boundary mocks only. The tests execute unmodified Manager logic.
const realSetInterval = globalThis.setInterval;
const realClearInterval = globalThis.clearInterval;

export const state = {
  active: true,
  locked: false,
  granted: true,
  nativeStatus: 'disabled',
  sessions: new Map(),
  nativeCalls: [],
  permissionCalls: [],
  timers: new Map(),
  applicationCallbacks: null,
  eventCallback: null,
  failApplicationSubscribe: false,
  failScreenSubscribe: false,
  lockCheck: null,
  permissionCheck: null,
  permissionRequest: null,
  storage: new Map()
};

export function reset() {
  Object.assign(state, {
    active: true, locked: false, granted: true, nativeStatus: 'disabled',
    sessions: new Map([['vm', 1], ['other', 3]]), nativeCalls: [], permissionCalls: [],
    timers: new Map(), applicationCallbacks: null, eventCallback: null,
    failApplicationSubscribe: false, failScreenSubscribe: false,
    lockCheck: null, permissionCheck: null, permissionRequest: null,
    storage: new Map()
  });
  let timer = 0;
  globalThis.setInterval = callback => {
    const id = ++timer;
    state.timers.set(id, callback);
    return id;
  };
  globalThis.clearInterval = id => state.timers.delete(id);
  globalThis.AppStorage = {
    setOrCreate(key, value) { state.storage.set(key, value); },
    get(key) { return state.storage.get(key); }
  };
}

export function restore() {
  globalThis.setInterval = realSetInterval;
  globalThis.clearInterval = realClearInterval;
  delete globalThis.AppStorage;
}

export async function flush() {
  for (let i = 0; i < 24; i++) await Promise.resolve();
}

export async function tick() {
  for (const callback of [...state.timers.values()]) callback();
  await flush();
}

export function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

const application = {
  on(event, callback) {
    if (event !== 'applicationStateChange') throw Error('unexpected application event');
    if (state.failApplicationSubscribe) throw Error('synthetic application subscription failure');
    state.applicationCallbacks = callback;
  }
};

export function context(name) {
  return { name, getApplicationContext() { return application; } };
}

export function appForeground(value) {
  if (value) state.applicationCallbacks.onApplicationForeground();
  else state.applicationCallbacks.onApplicationBackground();
}

export function screen(event) {
  if (event === 'locked') state.locked = true;
  if (event === 'unlocked') state.locked = false;
  if (event === 'off') state.active = false;
  state.eventCallback(null, { event });
}

export const window = { WindowEventType: { WINDOW_SHOWN: 1, WINDOW_HIDDEN: 2 } };

export class MockWindow {
  showing = true;
  failOn = '';
  failQuery = false;
  listeners = new Map();

  isWindowShowing() {
    if (this.failQuery) throw Error('synthetic window query failure');
    return this.showing;
  }

  on(event, callback) {
    if (event === this.failOn) throw Error('synthetic window subscription failure');
    if (!this.listeners.has(event)) this.listeners.set(event, []);
    this.listeners.get(event).push(callback);
  }

  off(event, callback) {
    this.listeners.set(event, (this.listeners.get(event) ?? []).filter(item => item !== callback));
  }

  emit(event, value) {
    for (const callback of [...(this.listeners.get(event) ?? [])]) callback(value);
  }

  visibility(visible) {
    this.showing = visible;
    this.emit('windowVisibilityChange', visible);
  }

  windowEvent(visible) {
    this.showing = visible;
    this.emit('windowEvent', visible ? window.WindowEventType.WINDOW_SHOWN : window.WindowEventType.WINDOW_HIDDEN);
  }
}

export const power = { isActive() { return state.active; } };
export const screenLock = {
  async isScreenLocked() { return state.lockCheck ? state.lockCheck() : state.locked; }
};
export const bundleManager = {
  BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
  async getBundleInfoForSelf() { return { appInfo: { accessTokenId: 42 } }; }
};

const permissionManager = {
  async checkAccessToken() {
    const granted = state.permissionCheck ? await state.permissionCheck() : state.granted;
    return granted ? 0 : -1;
  },
  async requestPermissionsFromUser(owner, permissions) {
    state.permissionCalls.push({ settings: false, owner, permissions });
    if (state.permissionRequest) await state.permissionRequest();
  },
  async requestPermissionOnSetting(owner, permissions) {
    state.permissionCalls.push({ settings: true, owner, permissions });
    if (state.permissionRequest) await state.permissionRequest();
  }
};
export const abilityAccessCtrl = {
  GrantStatus: { PERMISSION_GRANTED: 0 },
  createAtManager() { return permissionManager; }
};
export const commonEventManager = {
  Support: {
    COMMON_EVENT_SCREEN_LOCKED: 'locked',
    COMMON_EVENT_SCREEN_UNLOCKED: 'unlocked',
    COMMON_EVENT_SCREEN_OFF: 'off'
  },
  createSubscriberSync() { return {}; },
  subscribe(subscriber, callback) {
    if (state.failScreenSubscribe) throw Error('synthetic screen subscription failure');
    state.eventCallback = callback;
  }
};

export const qemu = {
  getMicrophoneSession(vmName) { return state.sessions.get(vmName) ?? 0; },
  setMicrophoneEnabled(vmName, session, enabled) {
    state.nativeCalls.push({ vmName, session, enabled });
    if (!session || state.sessions.get(vmName) !== session) return false;
    if (enabled && !state.granted) {
      state.nativeStatus = 'blocked';
      return false;
    }
    if (enabled) state.nativeStatus = 'armed';
    else if (!['blocked', 'error', 'unavailable'].includes(state.nativeStatus)) {
      state.nativeStatus = 'disabled';
    }
    return true;
  },
  getMicrophoneStatus() { return state.nativeStatus; }
};
