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
      data.nativeStatus = enabled ? 'armed' : 'disabled';
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
