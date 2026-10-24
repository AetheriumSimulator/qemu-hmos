import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import native from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { StoragePaths as S } from './StoragePaths.ts';
import { faults, resetFaults } from './platform.mjs';
import { IndexHarness, WizardHarness, ui } from './ui-harness.ts';

let root, uri;
beforeEach(async () => {
  resetFaults(); ui.starts = []; ui.toasts = [];
  root = await native.mkdtemp(path.join(os.tmpdir(), 'aether-import-ui-'));
  S.INTERNAL_BASE = root;
  for (const [key, leaf] of Object.entries({ VMS_DIR: 'vms', ISOS_DIR: 'isos', FIRMWARE_DIR: 'firmware', LOGS_DIR: 'logs',
    SHARED_BASE: 'shared', SHARED_VM_DISKS: 'shared/disks', SHARED_ONEDRIVE: 'shared/drive' })) S[key] = path.join(root, leaf);
  const file = path.join(root, '中文镜像'); await native.writeFile(file, Buffer.alloc(2 * 1024 * 1024, 7));
  uri = 'file://docs/storage/Download/%E4%B8%AD%E6%96%87.iso'; faults.uris.set(uri, file);
  ui.pick = [uri];
});
afterEach(async () => { await native.rm(root, { recursive: true, force: true }); });
function result(extra = {}) {
  return { name: '测试机', archType: 'aarch64', osType: 'Linux', memoryMB: 4096, diskSizeGB: 64,
    isoPath: '', importedDiskPath: '', noDisk: false, machine: 'virt', displayDevice: 'virtio-gpu-pci',
    networkDevice: 'virtio-net-pci', audioDevice: 'none', ...extra };
}
function gate() { let release; faults.gate = new Promise(resolve => { release = resolve; }); return release; }
async function copying() { while (!faults.copied.length) await new Promise(resolve => setImmediate(resolve)); }

test('wizard awaits successful copy, blocks navigation/create, and preserves ISO on failure/retry', async () => {
  const wizard = new WizardHarness(); const release = gate();
  const pending = wizard.selectISO(); await copying();
  wizard.goNext(); wizard.complete();
  assert.equal(wizard.currentStep, 'image'); assert.equal(wizard.completed.length, 0); assert.equal(wizard.isoPath, '');
  release(); await pending; const first = wizard.isoPath;
  assert.ok((await native.stat(first)).size > 0); wizard.complete(); assert.equal(wizard.completed[0].isoPath, first);
  faults.copy = 'reject'; await wizard.selectISO();
  assert.equal(wizard.isoPath, first); assert.match(wizard.fileSelectionError, /ISO/);
  faults.copy = ''; await wizard.selectISO(); assert.notEqual(wizard.isoPath, first);
  await wizard.selectDisk(); assert.equal(wizard.importedDiskPath, uri);
});

test('wizard cancellation and disappearance discard late copy and picker callbacks', async () => {
  for (const end of ['cancelWizard', 'aboutToDisappear']) {
    faults.copied = []; const wizard = new WizardHarness(); const release = gate();
    const pending = wizard.selectISO(); await copying(); wizard[end](); release(); await pending;
    assert.equal(wizard.isoPath, ''); assert.equal(wizard.filePickerBusy, false);
  }
  faults.gate = null; const wizard = new WizardHarness(); let select;
  ui.pick = new Promise(resolve => { select = resolve; });
  const pending = wizard.selectISO(); wizard.cancelWizard(); select([uri]); await pending;
  assert.equal(wizard.isoPath, '');
});

test('creation waits for disk copy, ignores duplicate submit, and publishes nothing on failure', async () => {
  const page = new IndexHarness(); const release = gate(); faults.copy = 'reject';
  const pending = page.createVMFromWizardResult(result({ importedDiskPath: uri })); await copying();
  await page.createVMFromWizardResult(result()); assert.equal(page.vms.length, 0); assert.equal(page.saves, 0);
  release(); await pending; assert.equal(page.vms.length, 0); assert.equal(page.isLoading, false);
  assert.match(page.errorMessage, /copy failed/);
  faults.copy = ''; await page.createVMFromWizardResult(result({ importedDiskPath: uri }));
  assert.equal(page.vms.length, 1); assert.ok((await native.stat(S.getVmDiskPath(page.vms[0].name))).size > 0);
});

test('different Chinese and duplicate names preserve separate ISO and disk content', async () => {
  const page = new IndexHarness();
  for (const name of ['测试机', '另一台', '测试机']) {
    const wizard = new WizardHarness(); await wizard.selectISO();
    await page.createVMFromWizardResult(result({ name, isoPath: wizard.isoPath, importedDiskPath: uri }));
  }
  assert.deepEqual(page.vms.map(vm => vm.name), ['测试机', '另一台', '测试机 (2)']);
  assert.equal(new Set(page.vms.map(vm => vm.config.isoPath)).size, 3);
  for (const vm of page.vms) assert.equal((await native.stat(S.getVmDiskPath(vm.name))).size, 2 * 1024 * 1024);
});

test('settings ISO failure, eject and sheet close preserve old or shared media', async () => {
  const page = new IndexHarness(); const old = await S.importIso(uri);
  const vm = { name: '测试机', config: { isoPath: old } };
  faults.copy = 'reject'; await page.pickIsoForVm(vm); assert.equal(vm.config.isoPath, old);
  faults.copy = ''; faults.copied = []; const release = gate();
  const pending = page.pickIsoForVm(vm); await copying(); page.closeSheet(); release(); await pending;
  assert.equal(vm.config.isoPath, old);
  await page.ejectIso(vm); assert.equal(vm.config.isoPath, ''); assert.ok((await native.stat(old)).size > 0);
});

test('startup migration failure does not call native or replace path; retry keeps explicit install GPU', async () => {
  const page = new IndexHarness();
  const vm = { name: '测试机', status: 'stopped', config: result({ isoPath: uri }) }; page.vms = [vm];
  faults.copy = 'reject'; await page.startVM(vm, 'install');
  assert.equal(ui.starts.length, 0); assert.equal(vm.config.isoPath, uri); assert.equal(vm.status, 'failed');
  faults.copy = ''; await page.startVM(vm, 'install');
  assert.equal(ui.starts.length, 1); assert.equal(ui.starts[0].displayDevice, 'virtio-gpu-pci');
  const sandbox = vm.config.isoPath; assert.ok(sandbox.startsWith(S.ISOS_DIR + '/'));
  await page.startVM(vm, 'standard'); assert.equal(vm.config.isoPath, sandbox);
  assert.equal(ui.starts[1].displayDevice, 'virtio-gpu-pci');
});
