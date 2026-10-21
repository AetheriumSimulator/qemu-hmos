import assert from 'node:assert/strict';
import test from 'node:test';
import {
  state, reset, restore, context, appForeground, screen, MockWindow,
  deferred, flush, tick, window
} from './platform.mjs';

let fixtureId = 0;
test.afterEach(() => restore());

async function fixture({ enabled = true, subscribeFailure = '', visibilityObserved = true } = {}) {
  reset();
  state.failApplicationSubscribe = subscribeFailure === 'application';
  state.failScreenSubscribe = subscribeFailure === 'screen';
  const { MicrophoneManager } = await import(`./MicrophoneManager.ts?fixture=${++fixtureId}`);
  const manager = MicrophoneManager.getInstance();
  const mainContext = context('entry');
  const main = new MockWindow();
  const mainId = manager.registerAbility(mainContext, 'EntryAbility');
  manager.attachWindow(mainId, main);
  manager.contentReady(mainId);
  if (visibilityObserved) main.visibility(true);
  manager.foreground(mainId, true);
  if (state.applicationCallbacks) appForeground(true);
  if (enabled) await manager.enable('vm', false, mainContext);
  return { manager, mainContext, main, mainId };
}

function enables() {
  return state.nativeCalls.filter(call => call.enabled);
}

function secondary(f, { kind = 'VNCWindowAbility', session = 1, handoff = 0,
  visible = true, failOn = '', name = 'viewer' } = {}) {
  const ctx = context(name);
  const win = new MockWindow();
  win.showing = visible;
  win.failOn = failOn;
  const id = f.manager.registerAbility(ctx, kind, 'vm', session, handoff);
  f.manager.attachWindow(id, win);
  f.manager.contentReady(id);
  win.visibility(visible);
  f.manager.foreground(id, visible);
  return { ctx, win, id };
}

function hideMain(f) {
  f.main.visibility(false);
  f.manager.foreground(f.mainId, false);
}

test('Entry to VNC with target visible before source background keeps approved input', async () => {
  const f = await fixture();
  assert.equal(enables().length, 1);
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  assert.ok(handoff > 0);
  secondary(f, { handoff });
  hideMain(f);
  await tick();
  assert.equal(state.storage.get('microphoneEnabled'), true);
  assert.equal(enables().length, 1);
  assert.equal(state.nativeCalls.filter(call => !call.enabled).length, 0);
});

test('source background before target foreground pauses Native through the handoff gap', async () => {
  const f = await fixture();
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  hideMain(f);
  assert.equal(state.storage.get('microphoneStatus'), 'suspended');
  assert.equal(state.nativeCalls.at(-1).enabled, false);
  assert.equal(state.nativeStatus, 'disabled');
  await tick();
  assert.equal(enables().length, 1);
  const target = secondary(f, { handoff, visible: false });
  target.win.visibility(true);
  f.manager.foreground(target.id, true);
  await flush();
  assert.equal(state.storage.get('microphoneEnabled'), true);
  assert.equal(enables().length, 2);
  assert.equal(state.permissionCalls.length, 0);
});

test('real application background and lock cancel gap even when target arrives late', async () => {
  for (const reason of ['background', 'locked', 'off']) {
    const f = await fixture();
    const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
    hideMain(f);
    if (reason === 'background') appForeground(false);
    else screen(reason);
    secondary(f, { handoff });
    if (reason === 'background') appForeground(true);
    else { state.active = true; screen('unlocked'); }
    await tick();
    assert.equal(enables().length, 1, reason);
    assert.equal(state.storage.get('microphoneEnabled'), false, reason);
    assert.equal(state.nativeStatus, 'disabled', reason);
  }
});

test('window hide cancels unresolved authorization and its late positive reply', async () => {
  const f = await fixture({ enabled: false });
  state.granted = false;
  const request = deferred();
  state.permissionRequest = () => request.promise;
  const pending = f.manager.enable('vm', false, f.mainContext);
  await flush();
  assert.equal(state.permissionCalls.length, 1);
  hideMain(f);
  state.granted = true;
  request.resolve();
  await pending;
  f.main.visibility(true);
  f.manager.foreground(f.mainId, true);
  await tick();
  assert.equal(enables().length, 0);
  assert.equal(state.storage.get('microphoneEnabled'), false);
});

test('another visible window cannot inherit an unresolved grant from a hidden request owner', async () => {
  for (const lost of ['hidden', 'destroyed']) {
    const f = await fixture({ enabled: false });
    secondary(f);
    state.granted = false;
    const request = deferred();
    state.permissionRequest = () => request.promise;
    const pending = f.manager.enable('vm', false, f.mainContext);
    await flush();
    assert.equal(state.permissionCalls.length, 1);
    if (lost === 'hidden') hideMain(f);
    else f.manager.removeAbility(f.mainId);
    state.granted = true;
    request.resolve();
    await pending;
    await tick();
    assert.equal(enables().length, 0, lost);
    assert.equal(state.storage.get('microphoneEnabled'), false, lost);
  }
});

test('fresh request-owner visibility blocks a late grant even before hide events arrive', async () => {
  for (const pollBeforeGrant of [false, true]) {
    const f = await fixture({ enabled: false });
    secondary(f);
    state.granted = false;
    const request = deferred();
    state.permissionRequest = () => request.promise;
    const pending = f.manager.enable('vm', false, f.mainContext);
    await flush();
    assert.equal(state.permissionCalls.length, 1);
    f.main.showing = false; // Intentionally deliver neither window nor Ability events.
    if (pollBeforeGrant) await tick();
    state.granted = true;
    request.resolve();
    await pending;
    assert.equal(enables().length, 0, `pollBeforeGrant=${pollBeforeGrant}`);
    assert.equal(state.storage.get('microphoneEnabled'), false);
    f.main.showing = true;
    await tick();
    assert.equal(enables().length, 0);
  }
});

test('same-name VM restart cannot receive a pending handoff or old window consent', async () => {
  const f = await fixture();
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  hideMain(f);
  state.sessions.set('vm', 2);
  secondary(f, { handoff, session: 1 });
  secondary(f, { session: 2, name: 'new-session' });
  await tick();
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
});

test('window subscription failure invalidates the matching handoff and removes listeners', async () => {
  for (const failOn of ['windowEvent', 'windowVisibilityChange']) {
    const f = await fixture();
    const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
    hideMain(f);
    const target = secondary(f, { handoff, failOn });
    target.win.windowEvent(true);
    f.manager.foreground(target.id, true);
    await tick();
    assert.equal(enables().length, 1, failOn);
    assert.equal(state.storage.get('microphoneEnabled'), false, failOn);
    assert.equal((target.win.listeners.get('windowEvent') ?? []).length, 0);
    assert.equal((target.win.listeners.get('windowVisibilityChange') ?? []).length, 0);
  }
});

test('Native fault after pause is not overwritten by target visibility', async () => {
  const f = await fixture();
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  hideMain(f);
  state.nativeStatus = 'error';
  secondary(f, { handoff });
  await flush();
  assert.equal(enables().length, 1);
  assert.equal(state.nativeStatus, 'error');
  assert.equal(state.storage.get('microphoneEnabled'), false);
});

test('late launch rejection closes capture after the visible handoff already completed', async () => {
  for (const gap of [false, true]) {
    const f = await fixture();
    const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
    assert.ok(handoff > 0);
    if (gap) hideMain(f);
    secondary(f, { handoff });
    if (!gap) hideMain(f);
    await flush();
    assert.equal(state.storage.get('microphoneEnabled'), true);
    const priorEnables = enables().length;
    f.manager.handoffFailed(handoff);
    assert.equal(state.nativeCalls.at(-1).enabled, false);
    assert.equal(state.storage.get('microphoneEnabled'), false);
    await tick();
    assert.equal(enables().length, priorEnables);
  }
});

test('a second launch during a paused handoff cancels its old ticket and approved intent', async () => {
  const f = await fixture();
  const original = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  hideMain(f);
  assert.equal(state.storage.get('microphoneStatus'), 'suspended');
  const next = f.manager.beginHandoff(f.mainContext, 'ConsoleWindowAbility', 'vm');
  assert.equal(next, 0);
  assert.equal(state.storage.get('microphoneEnabled'), false);
  assert.notEqual(state.storage.get('microphoneStatus'), 'suspended');
  secondary(f, { handoff: original });
  secondary(f, { kind: 'ConsoleWindowAbility', handoff: next, name: 'second-launch' });
  await tick();
  assert.equal(enables().length, 1);
  assert.equal(state.nativeStatus, 'disabled');
});

test('destroying an old multiton instance does not destroy the visible new instance', async () => {
  const f = await fixture();
  const old = secondary(f, { visible: false, name: 'old-viewer' });
  const staleCallback = old.win.listeners.get('windowEvent')[0];
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  const current = secondary(f, { handoff, name: 'new-viewer' });
  hideMain(f);
  f.manager.removeAbility(old.id);
  staleCallback(window.WindowEventType.WINDOW_HIDDEN);
  await tick();
  assert.equal(state.storage.get('microphoneEnabled'), true);
  assert.equal(enables().length, 1);
  f.manager.removeAbility(current.id);
  await tick();
  assert.equal(state.storage.get('microphoneEnabled'), false);
  assert.equal(state.nativeCalls.at(-1).enabled, false);
});

test('destroying pending target cancels handoff and stale callbacks cannot re-enable', async () => {
  const f = await fixture();
  const handoff = f.manager.beginHandoff(f.mainContext, 'ConsoleWindowAbility', 'vm');
  hideMain(f);
  const target = secondary(f, { kind: 'ConsoleWindowAbility', handoff, visible: false });
  const staleCallback = target.win.listeners.get('windowEvent')[0];
  f.manager.removeAbility(target.id);
  target.win.showing = true;
  staleCallback(window.WindowEventType.WINDOW_SHOWN);
  f.manager.foreground(target.id, true);
  await tick();
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
});

test('unknown or missing UI context cannot request or enable a microphone', async () => {
  const f = await fixture({ enabled: false });
  await f.manager.enable('vm');
  await f.manager.enable('vm', false, context('unregistered'));
  assert.equal(enables().length, 0);
  assert.equal(state.permissionCalls.length, 0);
});

test('guard subscription failure and visibility-query failure stay closed', async () => {
  for (const subscribeFailure of ['application', 'screen']) {
    const f = await fixture({ enabled: false, subscribeFailure });
    await f.manager.enable('vm', false, f.mainContext);
    assert.equal(enables().length, 0, subscribeFailure);
    assert.equal(state.permissionCalls.length, 0, subscribeFailure);
  }
  const f = await fixture();
  f.main.failQuery = true;
  await tick();
  assert.equal(state.storage.get('microphoneEnabled'), false);
  assert.equal(state.nativeCalls.at(-1).enabled, false);
});

test('background during asynchronous resume token check defeats a late grant', async () => {
  const f = await fixture();
  const handoff = f.manager.beginHandoff(f.mainContext, 'VNCWindowAbility', 'vm');
  hideMain(f);
  const check = deferred();
  state.permissionCheck = () => check.promise;
  secondary(f, { handoff });
  await flush();
  assert.equal(state.storage.get('microphoneBusy'), true);
  appForeground(false);
  appForeground(true);
  check.resolve(true);
  await flush();
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
});

test('an initial showing snapshot without an observed visibility event cannot authorize', async () => {
  const f = await fixture({ enabled: false, visibilityObserved: false });
  assert.equal(f.main.isWindowShowing(), true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 0);
  assert.equal(state.permissionCalls.length, 0);
  f.main.visibility(true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 1);
});

test('late Ability foreground cannot erase a WINDOW_HIDDEN veto', async () => {
  const f = await fixture();
  f.main.windowEvent(false);
  f.main.showing = true; // A later snapshot alone does not erase the hidden event.
  f.manager.foreground(f.mainId, true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
  f.main.windowEvent(true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 2);
});

test('late WINDOW_SHOWN cannot erase an Ability background veto', async () => {
  const f = await fixture();
  f.manager.foreground(f.mainId, false);
  f.main.windowEvent(true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
  f.manager.foreground(f.mainId, true);
  await f.manager.enable('vm', false, f.mainContext);
  assert.equal(enables().length, 2);
});

test('hiding and returning during lock preflight invalidates its late unlocked response', async () => {
  const f = await fixture({ enabled: false });
  const lock = deferred();
  state.lockCheck = () => lock.promise;
  const pending = f.manager.enable('vm', false, f.mainContext);
  hideMain(f);
  f.main.visibility(true);
  f.manager.foreground(f.mainId, true);
  lock.resolve(false);
  await pending;
  assert.equal(enables().length, 0);
  assert.equal(state.permissionCalls.length, 0);
});

test('viewer denial retains exact diagnostic session and settings retry uses its own context', async () => {
  const f = await fixture({ enabled: false });
  const viewer = secondary(f);
  hideMain(f);
  state.granted = false;
  await f.manager.enable('vm', false, viewer.ctx);
  assert.equal(state.storage.get('microphoneStatus'), 'denied');
  assert.equal(state.storage.get('microphoneVm'), 'vm');
  assert.equal(state.storage.get('microphoneSession'), 1);
  assert.equal(enables().length, 0);
  state.permissionRequest = async () => { state.granted = true; };
  await f.manager.enable('vm', true, viewer.ctx);
  assert.equal(state.permissionCalls.at(-1).settings, true);
  assert.equal(state.permissionCalls.at(-1).owner, viewer.ctx);
  assert.equal(enables().length, 1);
  f.manager.vmStopped('vm');
  state.sessions.set('vm', 2);
  await tick();
  assert.equal(state.storage.get('microphoneSession'), 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
  assert.equal(enables().length, 1);
});

test('inactive screen snapshot closes capture without a delivered screen event', async () => {
  const f = await fixture();
  state.active = false;
  await tick();
  assert.equal(state.nativeCalls.at(-1).enabled, false);
  state.active = true;
  await tick();
  assert.equal(enables().length, 1);
  assert.equal(state.storage.get('microphoneEnabled'), false);
});
