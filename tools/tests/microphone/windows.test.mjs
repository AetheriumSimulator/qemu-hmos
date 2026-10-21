import assert from 'node:assert/strict';
import test from 'node:test';
import { MicrophoneWindows } from './MicrophoneWindows.ts';

function fixture() {
  const sessions = new Map([['alpha', 1], ['beta', 2]]);
  const showing = new Map();
  const brokenWindows = new Set();
  const data = { sessionFailure: false };
  const windows = new MicrophoneWindows(id => {
    if (brokenWindows.has(id)) throw Error('synthetic window failure');
    return showing.get(id) === true;
  }, vmName => {
    if (data.sessionFailure) throw Error('synthetic session failure');
    return sessions.get(vmName) ?? 0;
  });
  windows.applicationForeground(true);
  windows.guards(true);

  function show(id) {
    windows.attached(id);
    windows.ready(id);
    windows.pageVisibility(id, true);
    windows.foreground(id, true);
    windows.shown(id, true);
    windows.visibility(id, true);
    showing.set(id, true);
  }

  function register(kind = 'EntryAbility', vmName = 'alpha', session = 1, ticket = 0) {
    const id = windows.register(kind, vmName, session, ticket);
    show(id);
    return id;
  }

  return { windows, sessions, showing, brokenWindows, data, show, register };
}

test('each window needs attachment, content readiness, foreground, confirmed visibility and a showing snapshot', () => {
  const f = fixture();
  const id = f.windows.register('EntryAbility', 'alpha', 1);
  f.showing.set(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.attached(id);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.ready(id);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.foreground(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.shown(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.visibility(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), true);
  f.showing.set(id, false);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.showing.set(id, true);
  f.windows.ready(id, false);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
});

test('application and safety guards start closed before any enable is possible', () => {
  const windows = new MicrophoneWindows(() => true, () => 1);
  const id = windows.register('EntryAbility', 'alpha', 1);
  windows.attached(id);
  windows.ready(id);
  windows.foreground(id, true);
  windows.shown(id, true);
  windows.visibility(id, true);
  assert.equal(windows.anyVisible('alpha', 1), false);
  windows.applicationForeground(true);
  assert.equal(windows.anyVisible('alpha', 1), false);
  windows.guards(true);
  assert.equal(windows.anyVisible('alpha', 1), true);
});

test('unknown initial visibility cannot authorize a showing foreground window or handoff', () => {
  const f = fixture();
  const id = f.windows.register('EntryAbility', 'alpha', 1);
  f.windows.attached(id);
  f.windows.ready(id);
  f.windows.foreground(id, true);
  f.windows.shown(id, true);
  f.showing.set(id, true);
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  assert.equal(f.windows.beginHandoff(id, 'VNCWindowAbility', 'alpha', 1), 0);
  f.windows.visibility(id, false);
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  f.windows.visibility(id, true);
  assert.equal(f.windows.anyVisible('alpha', 1), true);
});

test('WINDOW_HIDDEN remains a veto after late ability foreground and positive visibility', () => {
  const f = fixture();
  const id = f.register();
  f.windows.shown(id, false);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.foreground(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.visibility(id, true);
  assert.equal(f.showing.get(id), true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  assert.equal(f.windows.beginHandoff(id, 'VNCWindowAbility', 'alpha', 1), 0);
  f.windows.shown(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), true);
});

test('ability background remains a veto after late WINDOW_SHOWN and positive visibility', () => {
  const f = fixture();
  const id = f.register();
  f.windows.foreground(id, false);
  f.windows.shown(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  f.windows.visibility(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), false);
  assert.equal(f.windows.beginHandoff(id, 'ConsoleWindowAbility', 'alpha', 1), 0);
  f.windows.foreground(id, true);
  assert.equal(f.windows.visible(id, 'alpha', 1), true);
});

test('page hide survives late content readiness and all positive window events', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  const target = f.register('VNCWindowAbility', 'alpha', 1, ticket);
  f.windows.pageVisibility(target, false);
  f.windows.ready(target, true);
  f.windows.foreground(target, true);
  f.windows.shown(target, true);
  f.windows.visibility(target, true);
  assert.equal(f.windows.visible(target, 'alpha', 1), false);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  f.windows.pageVisibility(target, true);
  f.windows.ready(target, false);
  assert.equal(f.windows.visible(target, 'alpha', 1), false);
  f.windows.ready(target, true);
  assert.equal(f.windows.completeHandoff('alpha', 1), true);
});

test('multiton instances keep independent visibility and removal identities', () => {
  const f = fixture();
  const first = f.register('VNCWindowAbility');
  const second = f.register('VNCWindowAbility');
  assert.notEqual(first, second);
  f.windows.foreground(first, false);
  f.windows.visibility(first, false);
  assert.equal(f.windows.visible(first, 'alpha', 1), false);
  assert.equal(f.windows.visible(second, 'alpha', 1), true);
  f.windows.remove(first);
  assert.equal(f.windows.anyVisible('alpha', 1), true);
  assert.equal(f.windows.visible(second, 'alpha', 1), true);
});

test('visible windows cannot lend authorization to a different VM or session', () => {
  const f = fixture();
  const id = f.register('ConsoleWindowAbility');
  f.sessions.set('beta', 1);
  assert.equal(f.windows.visible(id, 'beta', 1), false);
  assert.equal(f.windows.anyVisible('beta', 1), false);
  assert.equal(f.windows.visible(id, 'alpha', 0), false);
  assert.equal(f.windows.visible(id, 'alpha', 2), false);
  assert.equal(f.windows.beginHandoff(id, 'VNCWindowAbility', 'beta', 1), 0);
});

test('only EntryAbility can change its selected VM binding', () => {
  const f = fixture();
  const entry = f.register();
  const viewer = f.register('VNCWindowAbility');
  f.windows.bindEntry(entry, 'beta', 2);
  f.windows.bindEntry(viewer, 'beta', 2);
  assert.equal(f.windows.visible(entry, 'alpha', 1), false);
  assert.equal(f.windows.visible(entry, 'beta', 2), true);
  assert.equal(f.windows.visible(viewer, 'alpha', 1), true);
  assert.equal(f.windows.visible(viewer, 'beta', 2), false);
});

for (const kind of ['VNCWindowAbility', 'ConsoleWindowAbility']) {
  test(`${kind}: a visible destination may arrive before source background`, () => {
    const f = fixture();
    const source = f.register();
    const ticket = f.windows.beginHandoff(source, kind, 'alpha', 1);
    assert.ok(ticket > 0);
    const target = f.register(kind, 'alpha', 1, ticket);
    f.windows.foreground(source, false);
    f.windows.visibility(source, false);
    assert.equal(f.windows.visible(target, 'alpha', 1), true);
    assert.equal(f.windows.anyVisible('alpha', 1), true);
    assert.equal(f.windows.completeHandoff('alpha', 1), true);
    assert.equal(f.windows.hasHandoff('alpha', 1), false);
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
  });

  test(`${kind}: source-hidden-first retains a ticket but no visible capture permit`, () => {
    const f = fixture();
    const source = f.register();
    const ticket = f.windows.beginHandoff(source, kind, 'alpha', 1);
    f.windows.foreground(source, false);
    f.windows.visibility(source, false);
    // Showing snapshots may lag lifecycle/visibility callbacks.
    assert.equal(f.showing.get(source), true);
    assert.equal(f.windows.anyVisible('alpha', 1), false);
    assert.equal(f.windows.hasHandoff('alpha', 1), true);
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
    const target = f.windows.register(kind, 'alpha', 1, ticket);
    f.showing.set(target, true);
    f.windows.attached(target);
    f.windows.foreground(target, true);
    f.windows.shown(target, true);
    f.windows.visibility(target, true);
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
    f.windows.ready(target);
    assert.equal(f.windows.anyVisible('alpha', 1), true);
    assert.equal(f.windows.completeHandoff('alpha', 1), true);
  });
}

test('wrong ticket, destination kind, VM and session cannot claim a pending handoff', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  for (const [kind, vmName, session, supplied] of [
    ['VNCWindowAbility', 'alpha', 1, ticket + 100],
    ['ConsoleWindowAbility', 'alpha', 1, ticket],
    ['VNCWindowAbility', 'beta', 2, ticket],
    ['VNCWindowAbility', 'alpha', 2, ticket]
  ]) {
    f.register(kind, vmName, session, supplied);
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
    assert.equal(f.windows.hasHandoff('alpha', 1), true);
  }
  f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.completeHandoff('beta', 2), false);
  assert.equal(f.windows.completeHandoff('alpha', 2), false);
  assert.equal(f.windows.completeHandoff('alpha', 1), true);
});

test('a duplicate ticket cannot replace the first destination or be reused after completion', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  const original = f.windows.register('VNCWindowAbility', 'alpha', 1, ticket);
  f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  f.show(original);
  assert.equal(f.windows.completeHandoff('alpha', 1), true);
  f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
});

test('a late failed launch cannot cancel the newer handoff', () => {
  const f = fixture();
  const source = f.register();
  const old = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  const current = f.windows.beginHandoff(source, 'ConsoleWindowAbility', 'alpha', 1);
  assert.notEqual(old, current);
  assert.equal(f.windows.failHandoff(old), false);
  f.register('VNCWindowAbility', 'alpha', 1, old);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  assert.equal(f.windows.hasHandoff('alpha', 1), true);
  assert.equal(f.windows.failHandoff(current), true);
  assert.equal(f.windows.failHandoff(current), false);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
});

test('an invisible or unknown source and unsupported destination cannot create a handoff', () => {
  const f = fixture();
  const source = f.register();
  assert.equal(f.windows.beginHandoff(999, 'VNCWindowAbility', 'alpha', 1), 0);
  assert.equal(f.windows.beginHandoff(source, 'EntryAbility', 'alpha', 1), 0);
  f.windows.visibility(source, false);
  assert.equal(f.windows.beginHandoff(source, 'ConsoleWindowAbility', 'alpha', 1), 0);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
});

test('all-window background and explicit invisibility veto positive showing snapshots', () => {
  const f = fixture();
  const ids = [f.register(), f.register('VNCWindowAbility'), f.register('ConsoleWindowAbility')];
  for (const id of ids) f.windows.foreground(id, false);
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  for (const id of ids) {
    f.windows.foreground(id, true);
    f.windows.visibility(id, false);
    assert.equal(f.showing.get(id), true);
    assert.equal(f.windows.visible(id, 'alpha', 1), false);
  }
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  f.windows.visibility(ids[2], true);
  assert.equal(f.windows.anyVisible('alpha', 1), true);
});

for (const veto of ['applicationForeground', 'guards']) {
  test(`${veto}(false) cancels the ticket even when the target is already shown`, () => {
    const f = fixture();
    const source = f.register();
    const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
    f.register('VNCWindowAbility', 'alpha', 1, ticket);
    f.windows[veto](false);
    assert.equal(f.windows.anyVisible('alpha', 1), false);
    assert.equal(f.windows.hasHandoff('alpha', 1), false);
    f.windows[veto](true);
    // Registry eligibility can return, but the consumed consent handoff cannot.
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
    f.register('VNCWindowAbility', 'alpha', 1, ticket);
    assert.equal(f.windows.completeHandoff('alpha', 1), false);
  });
}

test('same-name VM restart invalidates old windows and handoff session', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'ConsoleWindowAbility', 'alpha', 1);
  f.sessions.set('alpha', 2);
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
  f.register('ConsoleWindowAbility', 'alpha', 2, ticket);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  assert.equal(f.windows.completeHandoff('alpha', 2), false);
  assert.equal(f.windows.visible(source, 'alpha', 2), false);
  f.windows.bindEntry(source, 'alpha', 2);
  const next = f.windows.beginHandoff(source, 'ConsoleWindowAbility', 'alpha', 2);
  assert.ok(next > ticket);
  f.register('ConsoleWindowAbility', 'alpha', 2, next);
  assert.equal(f.windows.completeHandoff('alpha', 2), true);
});

test('destroying a handoff destination cancels it and late callbacks cannot revive it', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  const target = f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.remove(target), true);
  f.show(target);
  assert.equal(f.windows.visible(target, 'alpha', 1), false);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
  f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
});

test('removing an old unrelated window cannot remove a new instance or cancel its handoff', () => {
  const f = fixture();
  const old = f.register('VNCWindowAbility');
  f.windows.remove(old);
  const source = f.register('VNCWindowAbility');
  const ticket = f.windows.beginHandoff(source, 'ConsoleWindowAbility', 'alpha', 1);
  f.register('ConsoleWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.remove(old), false);
  assert.equal(f.windows.visible(source, 'alpha', 1), true);
  assert.equal(f.windows.completeHandoff('alpha', 1), true);
});

test('destroying the source invalidates an unfinished handoff', () => {
  const f = fixture();
  const source = f.register();
  const ticket = f.windows.beginHandoff(source, 'VNCWindowAbility', 'alpha', 1);
  f.register('VNCWindowAbility', 'alpha', 1, ticket);
  assert.equal(f.windows.remove(source), true);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
});

test('callbacks for unknown identities cannot register or authorize a window', () => {
  const f = fixture();
  f.show(777);
  f.windows.bindEntry(777, 'alpha', 1);
  assert.equal(f.windows.remove(778), false);
  assert.equal(f.windows.visible(777, 'alpha', 1), false);
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  assert.equal(f.windows.beginHandoff(777, 'VNCWindowAbility', 'alpha', 1), 0);
});

test('window and session query exceptions fail closed without propagating', () => {
  const f = fixture();
  const first = f.register();
  const second = f.register('VNCWindowAbility');
  const ticket = f.windows.beginHandoff(first, 'ConsoleWindowAbility', 'alpha', 1);
  const target = f.register('ConsoleWindowAbility', 'alpha', 1, ticket);
  f.brokenWindows.add(first);
  f.brokenWindows.add(target);
  assert.equal(f.windows.visible(first, 'alpha', 1), false);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  assert.equal(f.windows.visible(second, 'alpha', 1), true);
  f.data.sessionFailure = true;
  assert.equal(f.windows.anyVisible('alpha', 1), false);
  assert.equal(f.windows.hasHandoff('alpha', 1), false);
  assert.equal(f.windows.completeHandoff('alpha', 1), false);
  assert.equal(f.windows.beginHandoff(second, 'VNCWindowAbility', 'alpha', 1), 0);
});
