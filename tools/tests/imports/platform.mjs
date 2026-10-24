import native from 'node:fs/promises';
import assert from 'node:assert/strict';

export const faults = {
  mkdir: '', copy: '', gate: null, opened: [], copied: [], closed: 0, uris: new Map(),
};
const handles = new Map();
export const hilog = { info() {}, warn() {}, error() {} };
export const fs = {
  OpenMode: { READ_ONLY: 0 },
  async mkdir(path, recursive = false) {
    if (path === faults.mkdir) throw Object.assign(new Error('Permission denied'), { code: 13900012 });
    await native.mkdir(path, { recursive });
  },
  async stat(path) { return typeof path === 'number' ? handles.get(path).stat() : native.stat(path); },
  async open(uri) {
    faults.opened.push(uri);
    const file = await native.open(faults.uris.get(uri) || uri, 'r');
    handles.set(file.fd, file);
    return { fd: file.fd };
  },
  async close(file) { await handles.get(file.fd).close(); handles.delete(file.fd); faults.closed++; },
  async copyFile(fd, target) {
    assert.equal(typeof fd, 'number', 'picker URI must be opened before copying');
    faults.copied.push(target);
    if (faults.gate) await faults.gate;
    const data = await handles.get(fd).readFile();
    await native.writeFile(target, faults.copy ? data.subarray(0, 3) : data);
    if (faults.copy === 'reject') throw new Error('copy failed: no space');
  },
  async unlink(path) { await native.unlink(path); },
  async access(path) { try { await native.access(path); return true; } catch { return false; } },
};

export function resetFaults() {
  faults.mkdir = ''; faults.copy = ''; faults.gate = null;
  faults.opened = []; faults.copied = []; faults.closed = 0; faults.uris.clear();
}
