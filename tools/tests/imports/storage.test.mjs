import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import native from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { StoragePaths as S } from './StoragePaths.ts';
import { faults, resetFaults } from './platform.mjs';

let root;
beforeEach(async () => {
  resetFaults(); root = await native.mkdtemp(path.join(os.tmpdir(), 'aether-import-'));
  S.INTERNAL_BASE = root;
  for (const [key, leaf] of Object.entries({ VMS_DIR: 'vms', ISOS_DIR: 'isos', FIRMWARE_DIR: 'firmware', LOGS_DIR: 'logs',
    SHARED_BASE: 'shared', SHARED_VM_DISKS: 'shared/disks', SHARED_ONEDRIVE: 'shared/drive' })) S[key] = path.join(root, leaf);
  S.importSequence = 0;
});
afterEach(async () => { await native.rm(root, { recursive: true, force: true }); });
async function source(name = '安装.iso') {
  const file = path.join(root, name); await native.writeFile(file, 'image payload');
  const uri = `file://docs/storage/Download/${encodeURIComponent(name)}`;
  faults.uris.set(uri, file); return uri;
}

test('clean install creates parents and tolerates only optional shared failures', async () => {
  faults.mkdir = S.SHARED_BASE;
  await S.ensureVmDirectories('测试机');
  assert.ok((await native.stat(S.getVmDir('测试机'))).isDirectory());
  faults.mkdir = S.VMS_DIR;
  await assert.rejects(S.ensureVmDirectories('重试'), /Permission denied/);
  assert.equal(await native.stat(S.getVmDir('重试')).catch(() => null), null);
  faults.mkdir = '';
  await S.ensureVmDirectories('重试');
});

test('required directory occupied by a file fails without publishing a path', async () => {
  await native.writeFile(S.VMS_DIR, 'do not replace');
  await assert.rejects(S.ensureVmDirectories('测试机'));
  assert.equal(await native.readFile(S.VMS_DIR, 'utf8'), 'do not replace');
});

test('ISO import opens exact URI, awaits copy, validates, then closes descriptor', async () => {
  const uri = await source(); let release;
  faults.gate = new Promise(resolve => { release = resolve; });
  let returned = false;
  const pending = S.importIso(uri).then(value => { returned = true; return value; });
  while (!faults.copied.length) await new Promise(resolve => setImmediate(resolve));
  assert.equal(returned, false); assert.deepEqual(faults.opened, [uri]);
  release(); const target = await pending;
  assert.equal(await native.readFile(target, 'utf8'), 'image payload');
  assert.equal(faults.closed, 1);
});

for (const fault of ['reject', 'truncate']) {
  test(`ISO ${fault} failure removes only partial output and supports retry`, async () => {
    const uri = await source(); faults.copy = fault;
    await assert.rejects(S.importIso(uri));
    assert.equal(await native.stat(faults.copied[0]).catch(() => null), null);
    assert.equal(await native.readFile(faults.uris.get(uri), 'utf8'), 'image payload');
    faults.copy = ''; const target = await S.importIso(uri);
    assert.equal(await native.readFile(target, 'utf8'), 'image payload');
    assert.equal(faults.closed, 2);
  });
}

test('same-clock import collision reserves a different directory and preserves old ISO', async () => {
  const uri = await source(); const now = Date.now; Date.now = () => 123;
  try {
    const first = await S.importIso(uri); S.importSequence = 0;
    const second = await S.importIso(uri);
    assert.notEqual(first, second);
    assert.equal(await native.readFile(first, 'utf8'), 'image payload');
  } finally { Date.now = now; }
});

test('legacy sandbox ISO stays in place while external URI migrates; missing fails', async () => {
  const uri = await source(); await S.ensureDirectories();
  const old = path.join(S.ISOS_DIR, '___.iso'); await native.writeFile(old, 'legacy image');
  assert.equal(await S.prepareIso(old), old); assert.equal(faults.copied.length, 0);
  assert.notEqual(await S.prepareIso(uri), old);
  assert.equal(await native.readFile(old, 'utf8'), 'legacy image');
  await assert.rejects(S.prepareIso(path.join(S.ISOS_DIR, 'absent.iso')));
});

test('Chinese and same-name VM reservations protect metadata and orphan disks', async () => {
  const a = await S.reserveVmName('测试机', []);
  await native.writeFile(S.getVmDiskPath(a), 'existing disk');
  const b = await S.reserveVmName('测试机', []);
  const c = await S.reserveVmName('另一台', ['另一台']);
  assert.equal(a, '测试机'); assert.equal(b, '测试机 (2)'); assert.equal(c, '另一台 (2)');
  assert.equal(await native.readFile(S.getVmDiskPath(a), 'utf8'), 'existing disk');
  const pair = await Promise.all([S.reserveVmName('并发', []), S.reserveVmName('并发', [])]);
  assert.notEqual(pair[0], pair[1]);
  for (const invalid of ['../x', '.', '..', 'a/b', 'a\\b']) await assert.rejects(S.reserveVmName(invalid, []));
});

test('disk import initializes parents, rejects existing data, and safely retries failure', async () => {
  const uri = await source('盘.qcow2');
  const name = await S.reserveVmName('测试机', []);
  faults.copy = 'reject'; await assert.rejects(S.importVmDisk(uri, name));
  faults.copy = ''; assert.equal(await S.importVmDisk(uri, name), 13);
  await assert.rejects(S.importVmDisk(uri, name), /拒绝覆盖/);
  assert.equal(await native.readFile(S.getVmDiskPath(name), 'utf8'), 'image payload');
});
