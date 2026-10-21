import assert from 'node:assert/strict';
import test from 'node:test';
import { MicrophoneConsent } from './MicrophoneConsent.ts';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function fixture() {
  const calls = [];
  const snapshots = [];
  const data = { granted: false, session: 1, nativeStatus: 'disabled', requests: 0 };
  const port = {
    async checkPermission() { return data.granted; },
    async requestPermission(settings) { data.requests++; calls.push(['request', settings]); },
    getMicrophoneSession() { return data.session; },
    setMicrophoneEnabled(vm, session, enabled) {
      calls.push(['set', vm, session, enabled]);
      if (session !== data.session || !session) return false;
      // Native disable retains faults; only a later explicit enable may retry.
      if (enabled) data.nativeStatus = 'armed';
      else if (!['blocked', 'error', 'unavailable'].includes(data.nativeStatus)) {
        data.nativeStatus = 'disabled';
      }
      return true;
    },
    getMicrophoneStatus() { return data.nativeStatus; }
  };
  const controller = new MicrophoneConsent(port, state => snapshots.push(state));
  return { controller, port, data, calls, snapshots,
    enables: () => calls.filter(call => call[0] === 'set' && call[3]) };
}

async function flush() {
  await Promise.resolve();
  await Promise.resolve();
}

test('startup/foreground and a stopped VM never request permission', async () => {
  const f = fixture();
  await f.controller.enable('vm');
  f.controller.setForeground(true);
  await f.controller.synchronize();
  f.data.session = 0;
  await f.controller.enable('vm');
  assert.equal(f.data.requests, 0);
  assert.equal(f.enables().length, 0);
  assert.equal(f.controller.snapshot().enabled, false);
});

test('first grant rechecks actual permission and waits for guest capture', async () => {
  const f = fixture();
  let checks = 0;
  f.port.checkPermission = async () => { checks++; return f.data.granted; };
  f.port.requestPermission = async () => { f.data.requests++; f.data.granted = true; };
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  assert.equal(checks, 2);
  assert.equal(f.data.requests, 1);
  assert.equal(f.enables().length, 1);
  assert.equal(f.controller.snapshot().status, 'armed');
  f.data.nativeStatus = 'capturing';
  await f.controller.synchronize();
  assert.equal(f.controller.snapshot().status, 'capturing');
  assert.equal(f.controller.snapshot().busy, false);
});

test('existing grant does not prompt; denial and settings retry remain explicit', async () => {
  const f = fixture();
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().status, 'denied');
  assert.equal(f.enables().length, 0);
  await f.controller.synchronize();
  assert.equal(f.data.requests, 1);
  f.port.requestPermission = async settings => {
    assert.equal(settings, true);
    f.data.requests++;
    f.data.granted = true;
  };
  await f.controller.enable('vm', true);
  assert.equal(f.enables().length, 1);
  f.controller.disable();
  await f.controller.enable('vm');
  assert.equal(f.data.requests, 2);
  assert.equal(f.enables().length, 2);
});

test('settings requires an earlier ordinary permission request', async () => {
  const f = fixture();
  f.controller.setForeground(true);
  await f.controller.enable('vm', true);
  assert.equal(f.data.requests, 0);
  assert.equal(f.enables().length, 0);
  await f.controller.enable('vm');
  assert.equal(f.data.requests, 1);
  await f.controller.enable('vm', true);
  assert.deepEqual(f.calls.filter(call => call[0] === 'request'),
    [['request', false], ['request', true]]);
});

test('cancel keeps a pending dialog serialized and discards its late grant', async () => {
  const f = fixture();
  const request = deferred();
  f.port.requestPermission = async () => { f.data.requests++; await request.promise; };
  f.controller.setForeground(true);
  const pending = f.controller.enable('vm');
  await flush();
  f.controller.disable();
  assert.equal(f.controller.snapshot().busy, true);
  await f.controller.enable('vm');
  assert.equal(f.data.requests, 1);
  f.data.granted = true;
  request.resolve();
  await pending;
  assert.equal(f.enables().length, 0);
  assert.equal(f.controller.snapshot().busy, false);
  await f.controller.enable('vm');
  assert.equal(f.enables().length, 1);
});

test('background and foreground cannot restore a late grant or prior capture', async () => {
  const f = fixture();
  const check = deferred();
  f.port.checkPermission = () => check.promise;
  f.controller.setForeground(true);
  const pending = f.controller.enable('vm');
  f.controller.setForeground(false);
  f.controller.setForeground(true);
  check.resolve(true);
  await pending;
  assert.equal(f.enables().length, 0);
  f.port.checkPermission = async () => true;
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().enabled, true);
  f.controller.setForeground(false);
  assert.equal(f.controller.snapshot().enabled, false);
  assert.equal(f.calls.at(-1)[3], false);
  f.controller.setForeground(true);
  await f.controller.synchronize();
  assert.equal(f.enables().length, 1);
});

test('VM stop and same-name restart invalidate authorization in flight', async () => {
  for (const notify of [false, true]) {
    const f = fixture();
    const check = deferred();
    f.port.checkPermission = () => check.promise;
    f.controller.setForeground(true);
    const pending = f.controller.enable('vm');
    if (notify) f.controller.vmStopped('vm');
    f.data.session = 2;
    check.resolve(true);
    await pending;
    assert.equal(f.enables().length, 0);
    assert.equal(f.controller.snapshot().enabled, false);
  }
});

test('revocation closes input and requires explicit retry after a new grant', async () => {
  const f = fixture();
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  f.data.granted = false;
  await f.controller.synchronize();
  assert.equal(f.controller.snapshot().status, 'blocked');
  assert.equal(f.controller.snapshot().enabled, false);
  assert.equal(f.calls.at(-1)[3], false);
  f.data.granted = true;
  await f.controller.synchronize();
  assert.equal(f.enables().length, 1);
  assert.equal(f.data.requests, 0);
});

test('native stop, denial, unavailable backend and capture error all close input', async () => {
  for (const status of ['disabled', 'blocked', 'unavailable', 'error']) {
    const f = fixture();
    f.data.granted = true;
    f.controller.setForeground(true);
    await f.controller.enable('vm');
    f.data.nativeStatus = status;
    await f.controller.synchronize();
    assert.equal(f.controller.snapshot().enabled, false, status);
    assert.equal(f.controller.snapshot().status, status);
    assert.equal(f.calls.at(-1)[3], false);
  }
});

test('permission and native exceptions fail closed and permit a later retry', async () => {
  for (const operation of ['checkPermission', 'requestPermission', 'setMicrophoneEnabled']) {
    const f = fixture();
    const original = f.port[operation];
    f.port[operation] = () => { throw Error('synthetic failure'); };
    f.data.granted = operation === 'setMicrophoneEnabled';
    f.controller.setForeground(true);
    await f.controller.enable('vm');
    assert.equal(f.controller.snapshot().enabled, false, operation);
    assert.equal(f.controller.snapshot().busy, false, operation);
    assert.equal(f.controller.snapshot().status, 'error', operation);
    f.port[operation] = original;
    f.data.granted = true;
    await f.controller.enable('vm');
    assert.equal(f.controller.snapshot().enabled, true);
  }
});

test('native refusal cannot be reported as enabled', async () => {
  const f = fixture();
  f.data.granted = true;
  f.port.setMicrophoneEnabled = () => false;
  f.port.getMicrophoneStatus = () => 'armed';
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().enabled, false);
  assert.equal(f.controller.snapshot().status, 'error');
});

test('an obsolete poll cannot close a new session and polls cannot overlap', async () => {
  const f = fixture();
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  const check = deferred();
  let checks = 0;
  f.port.checkPermission = () => { checks++; return check.promise; };
  const pending = f.controller.synchronize();
  await f.controller.synchronize();
  assert.equal(checks, 1);
  f.controller.disable();
  f.data.session = 2;
  f.port.checkPermission = async () => true;
  await f.controller.enable('vm');
  check.resolve(false);
  await pending;
  assert.equal(f.controller.snapshot().session, 2);
  assert.equal(f.controller.snapshot().enabled, true);
});

test('snapshots are independent and VM exit is observed without a UI stop event', async () => {
  const f = fixture();
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  const before = f.controller.snapshot();
  f.data.session = 0;
  await f.controller.synchronize();
  assert.equal(before.enabled, true);
  assert.equal(f.controller.snapshot().enabled, false);
  assert.notEqual(before, f.snapshots.at(-1));
});

async function enabledFixture() {
  const f = fixture();
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  return f;
}

test('handoff stops Native immediately and resumes only approved same-session input', async () => {
  const f = await enabledFixture();
  f.data.nativeStatus = 'capturing';
  assert.equal(f.controller.suspend(), true);
  assert.equal(f.calls.at(-1)[3], false);
  assert.equal(f.data.nativeStatus, 'disabled');
  assert.equal(f.controller.snapshot().enabled, false);
  assert.equal(f.controller.snapshot().status, 'suspended');
  assert.equal(f.controller.snapshot().session, 1);
  f.controller.setForeground(true);
  await f.controller.synchronize();
  assert.equal(f.enables().length, 1);
  await f.controller.resume();
  assert.equal(f.enables().length, 2);
  assert.equal(f.controller.snapshot().enabled, true);
  assert.equal(f.controller.snapshot().status, 'armed');
  assert.equal(f.data.requests, 0);
});

test('resume without proven foreground cancels retained intent', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  await f.controller.resume();
  assert.equal(f.controller.snapshot().session, 0);
  f.controller.setForeground(true);
  await f.controller.resume();
  assert.equal(f.enables().length, 1);
});

test('suspend cannot retain a pending grant or create consent from disabled state', async () => {
  const f = fixture();
  const request = deferred();
  f.port.requestPermission = async () => { f.data.requests++; await request.promise; };
  f.controller.setForeground(true);
  const pending = f.controller.enable('vm');
  await flush();
  assert.equal(f.controller.suspend(), false);
  assert.equal(f.controller.snapshot().busy, true);
  f.controller.setForeground(true);
  f.data.granted = true;
  request.resolve();
  await pending;
  await f.controller.resume();
  assert.equal(f.enables().length, 0);
  assert.equal(f.controller.suspend(), false);
  f.controller.setForeground(true);
  await f.controller.resume();
  assert.equal(f.enables().length, 0);
});

test('disable, true background and VM stop invalidate suspended intent permanently', async () => {
  for (const stop of [
    controller => controller.disable(),
    controller => controller.setForeground(false),
    controller => controller.vmStopped('vm')
  ]) {
    const f = await enabledFixture();
    assert.equal(f.controller.suspend(), true);
    stop(f.controller);
    f.controller.setForeground(true);
    await f.controller.resume();
    assert.equal(f.enables().length, 1);
    assert.equal(f.controller.snapshot().session, 0);
    assert.equal(f.controller.snapshot().enabled, false);
  }
});

test('Native failure before suspension cannot be hidden by disable', async () => {
  for (const status of ['blocked', 'error', 'unavailable']) {
    const f = await enabledFixture();
    f.data.nativeStatus = status;
    assert.equal(f.controller.suspend(), false, status);
    assert.equal(f.data.nativeStatus, status);
    f.controller.setForeground(true);
    await f.controller.resume();
    assert.equal(f.enables().length, 1, status);
    assert.equal(f.controller.snapshot().session, 0);
  }
});

test('Native refusal or an unexpected stream state cannot establish suspension', async () => {
  for (const outcome of ['refused', 'still-capturing', 'exception']) {
    const f = await enabledFixture();
    f.port.setMicrophoneEnabled = () => {
      if (outcome === 'exception') throw Error('synthetic stop failure');
      f.data.nativeStatus = outcome === 'still-capturing' ? 'capturing' : 'disabled';
      return outcome !== 'refused';
    };
    assert.equal(f.controller.suspend(), false, outcome);
    f.controller.setForeground(true);
    await f.controller.resume();
    assert.equal(f.enables().length, 1, outcome);
    assert.equal(f.controller.snapshot().enabled, false);
  }
});

test('fault while suspended and revoked permission both prevent resume without prompting', async () => {
  for (const status of ['blocked', 'error', 'unavailable', 'armed', 'capturing', 'revoked']) {
    const f = await enabledFixture();
    assert.equal(f.controller.suspend(), true);
    if (status === 'revoked') f.data.granted = false;
    else f.data.nativeStatus = status;
    f.controller.setForeground(true);
    await f.controller.resume();
    assert.equal(f.enables().length, 1, status);
    assert.equal(f.controller.snapshot().session, 0);
    assert.equal(f.data.requests, 0);
  }
});

test('resume permission check failure cancels retained intent', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  f.port.checkPermission = async () => { throw Error('synthetic token error'); };
  f.controller.setForeground(true);
  await f.controller.resume();
  assert.equal(f.enables().length, 1);
  assert.equal(f.controller.snapshot().busy, false);
  assert.equal(f.controller.snapshot().status, 'error');
  assert.equal(f.controller.snapshot().session, 0);
});

test('an obsolete poll cannot cancel successful handoff resume', async () => {
  const f = await enabledFixture();
  const check = deferred();
  f.port.checkPermission = () => check.promise;
  const poll = f.controller.synchronize();
  assert.equal(f.controller.suspend(), true);
  f.port.checkPermission = async () => true;
  f.controller.setForeground(true);
  await f.controller.resume();
  check.resolve(false);
  await poll;
  assert.equal(f.controller.snapshot().enabled, true);
  assert.equal(f.enables().length, 2);
});

test('VM exit and same-name restart during resume cannot receive the old consent', async () => {
  for (const newSession of [0, 2]) {
    const f = await enabledFixture();
    assert.equal(f.controller.suspend(), true);
    const check = deferred();
    f.port.checkPermission = () => check.promise;
    f.controller.setForeground(true);
    const resume = f.controller.resume();
    f.data.session = newSession;
    check.resolve(true);
    await resume;
    assert.equal(f.enables().length, 1, String(newSession));
    assert.equal(f.controller.snapshot().session, 0);
    assert.equal(f.controller.snapshot().enabled, false);
  }
});

test('lost visibility cancels in-flight resume even if foreground returns before its reply', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  const check = deferred();
  f.port.checkPermission = () => check.promise;
  f.controller.setForeground(true);
  const resume = f.controller.resume();
  f.controller.setForeground(false);
  f.controller.setForeground(true);
  check.resolve(true);
  await resume;
  assert.equal(f.enables().length, 1);
  assert.equal(f.controller.snapshot().session, 0);
  assert.equal(f.controller.snapshot().busy, false);
});

test('resume requests serialize and cancellation prevents late resume from arming a new session', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  const check = deferred();
  let checks = 0;
  f.port.checkPermission = () => { checks++; return check.promise; };
  f.controller.setForeground(true);
  const resume = f.controller.resume();
  await f.controller.resume();
  assert.equal(checks, 1);
  f.controller.disable();
  f.data.session = 2;
  await f.controller.enable('vm');
  assert.equal(checks, 1);
  check.resolve(true);
  await resume;
  assert.equal(f.enables().length, 1);
  f.port.checkPermission = async () => true;
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().session, 2);
  assert.equal(f.controller.snapshot().enabled, true);
  assert.equal(f.enables().length, 2);
});

test('suspended polling keeps Native off and detects revocation without waiting for resume', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  await f.controller.synchronize();
  assert.equal(f.controller.snapshot().status, 'suspended');
  assert.equal(f.enables().length, 1);
  f.data.granted = false;
  await f.controller.synchronize();
  assert.equal(f.controller.snapshot().status, 'blocked');
  assert.equal(f.controller.snapshot().session, 0);
  assert.equal(f.data.requests, 0);
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.resume();
  assert.equal(f.enables().length, 1);
});

test('suspended polling detects Native faults, VM exit and token-check errors', async () => {
  for (const failure of ['blocked', 'error', 'unavailable', 'armed', 'exit', 'token']) {
    const f = await enabledFixture();
    assert.equal(f.controller.suspend(), true);
    if (failure === 'exit') f.data.session = 0;
    else if (failure === 'token') {
      f.port.checkPermission = async () => { throw Error('synthetic token failure'); };
    } else f.data.nativeStatus = failure;
    await f.controller.synchronize();
    assert.equal(f.controller.snapshot().session, 0, failure);
    assert.equal(f.controller.snapshot().enabled, false, failure);
    assert.equal(f.enables().length, 1, failure);
  }
});

test('a late suspended poll cannot cancel a subsequently validated resume', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  const check = deferred();
  f.port.checkPermission = () => check.promise;
  const poll = f.controller.synchronize();
  f.port.checkPermission = async () => true;
  f.controller.setForeground(true);
  await f.controller.resume();
  check.resolve(false);
  await poll;
  assert.equal(f.controller.snapshot().enabled, true);
  assert.equal(f.enables().length, 2);
});

test('a new handoff cannot retain intent from an in-flight resume', async () => {
  const f = await enabledFixture();
  assert.equal(f.controller.suspend(), true);
  const check = deferred();
  f.port.checkPermission = () => check.promise;
  f.controller.setForeground(true);
  const resume = f.controller.resume();
  assert.equal(f.controller.suspend(), false);
  f.controller.setForeground(true);
  check.resolve(true);
  await resume;
  assert.equal(f.enables().length, 1);
  assert.equal(f.controller.snapshot().session, 0);
  assert.equal(f.controller.snapshot().busy, false);
});

test('diagnostic session survives denial/stop but never authorizes a same-name restart', async () => {
  const f = fixture();
  f.controller.setForeground(true);
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().status, 'denied');
  assert.equal(f.controller.snapshot().targetSession, 1);
  assert.equal(f.controller.snapshot().session, 0);
  f.controller.vmStopped('vm');
  f.data.session = 2;
  f.data.granted = true;
  f.controller.setForeground(true);
  await f.controller.resume();
  await f.controller.synchronize();
  assert.equal(f.controller.snapshot().targetSession, 1);
  assert.equal(f.enables().length, 0);
  await f.controller.enable('vm');
  assert.equal(f.controller.snapshot().targetSession, 2);
  assert.equal(f.controller.snapshot().session, 2);
  f.data.session = 0;
  await f.controller.enable('other');
  assert.equal(f.controller.snapshot().vmName, 'other');
  assert.equal(f.controller.snapshot().targetSession, 0);
  assert.equal(f.controller.snapshot().session, 0);
});
