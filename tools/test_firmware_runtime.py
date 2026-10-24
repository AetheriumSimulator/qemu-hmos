"""Execute production firmware installation and native NVRAM preservation on host."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FirmwareRuntimeTests(unittest.TestCase):
    def test_bundled_firmware_installation(self):
        source = (ROOT / 'entry/src/main/ets/utils/FirmwareManager.ets').read_text()
        source = '\n'.join(line for line in source.splitlines() if not line.startswith('import '))
        source = source.replace('common.UIAbilityContext', 'Context')
        fixture = r'''
import assert from 'node:assert/strict';
import * as real from 'node:fs/promises';
import { constants } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
interface Context { filesDir: string; resourceManager: { getRawFileContent(name: string): Promise<Uint8Array> } }
const size = 64 * 1024 * 1024;
const codeName = 'edk2-aarch64-code.fd';
const handles = new Map();
let failWrite = false, failRename = false, limitWrite = false;
let pendingWrite: Promise<void> | null = null;
let writes = 0;
const fs = {
  OpenMode: { CREATE: constants.O_CREAT, READ_WRITE: constants.O_RDWR },
  access: async (path: string) => { try { await real.access(path); return true; } catch (e) {
    if (e.code === 'ENOENT') return false; throw e;
  } },
  stat: real.stat,
  mkdtemp: (prefix: string) => real.mkdtemp(prefix.replace(/XXXXXX$/, '')),
  open: async (path: string, flags: number) => { const file = await real.open(path, flags); handles.set(file.fd, file); return file; },
  write: async (fd: number, chunk: ArrayBuffer) => {
    writes++;
    if (pendingWrite) await pendingWrite;
    if (failWrite) throw new Error('injected ENOSPC');
    const bytes = Buffer.from(chunk);
    return (await handles.get(fd).write(limitWrite ? bytes.subarray(0, 600000) : bytes)).bytesWritten;
  },
  fsync: async (fd: number) => handles.get(fd).sync(),
  close: async (file) => { handles.delete(file.fd); await file.close(); },
  rename: async (source: string, target: string) => { if (failRename) throw new Error('injected rename failure'); await real.rename(source, target); },
  unlink: real.unlink,
  rmdir: real.rmdir,
};
const hilog = { info: (..._: unknown[]) => {}, error: (..._: unknown[]) => {} };
const backing = new Uint8Array(size + 4);
backing[0] = 0xaa; backing[2] = 0x51; backing[3] = 0x46; backing[size + 2] = 0xbb;
const code = backing.subarray(2, size + 2); // Exercises a non-zero byteOffset.
function context(filesDir: string, image: Uint8Array = code, version?: string): Context {
  const digest = version ?? createHash('sha256').update(image).digest('hex');
  return { filesDir, resourceManager: { getRawFileContent: async (name) => {
    if (name === codeName) return image;
    if (name === codeName + '.sha256') return new TextEncoder().encode(digest + '\n');
    throw new Error('resource absent');
  } } };
}
async function fixture(t) {
  failWrite = false; failRename = false; limitWrite = false; pendingWrite = null; writes = 0;
  const directory = await real.mkdtemp(join(tmpdir(), 'aether-uefi-'));
  t.after(async () => { assert.equal(handles.size, 0, 'all file handles closed'); await real.rm(directory, { recursive: true }); });
  return directory;
}
async function assertNoStaging(directory: string) {
  assert.equal((await real.readdir(directory)).some(name => name.startsWith('.aetherium-uefi-')), false);
}
'''
        fixture += source + r'''

test('clean install completes 64MiB image and is idempotent', async (t) => {
  const directory = await fixture(t), ctx = context(directory);
  const target = await FirmwareManager.ensureUefi(ctx);
  assert.ok(target);
  assert.equal((await real.stat(target)).size, size);
  assert.deepEqual(await real.readFile(target), Buffer.from(code));
  const firstWrites = writes;
  assert.equal(await FirmwareManager.ensureUefi(ctx), target);
  assert.equal(writes, firstWrites, 'valid immutable cache is reused');
  await assertNoStaging(directory);
});

test('upgrade bypasses stale 2MiB legacy image and preserves custom files', async (t) => {
  const directory = await fixture(t);
  const legacy = join(directory, codeName), custom = join(directory, 'custom.fd');
  const oldBytes = Buffer.alloc(2 * 1024 * 1024, 0x37);
  await real.writeFile(legacy, oldBytes); await real.writeFile(custom, 'custom firmware');
  const first = await FirmwareManager.ensureUefi(context(directory));
  assert.notEqual(first, legacy);
  const updated = new Uint8Array(code); updated[0] ^= 0xff;
  const second = await FirmwareManager.ensureUefi(context(directory, updated));
  assert.notEqual(first, second, 'new bundle identity gets independent prepared file');
  assert.deepEqual(await real.readFile(first!), Buffer.from(code));
  assert.deepEqual(await real.readFile(second!), Buffer.from(updated));
  assert.deepEqual(await real.readFile(legacy), oldBytes);
  assert.equal(await real.readFile(custom, 'utf8'), 'custom firmware');
});

test('write rejection publishes no target and retry succeeds', async (t) => {
  const directory = await fixture(t), ctx = context(directory);
  failWrite = true;
  assert.equal(await FirmwareManager.ensureUefi(ctx), null);
  assert.deepEqual(await real.readdir(directory), []);
  assert.equal(handles.size, 0);
  failWrite = false;
  assert.ok(await FirmwareManager.ensureUefi(ctx));
  await assertNoStaging(directory);
});

test('short writes retain every byte before publication', async (t) => {
  const directory = await fixture(t); limitWrite = true;
  const target = await FirmwareManager.ensureUefi(context(directory));
  assert.ok(target); assert.ok(writes > 64);
  assert.deepEqual(await real.readFile(target!), Buffer.from(code));
});

test('asynchronous write is awaited before returning usable path', async (t) => {
  const directory = await fixture(t);
  let release!: () => void;
  pendingWrite = new Promise(resolve => { release = resolve; });
  let finished = false;
  const result = FirmwareManager.ensureUefi(context(directory)).then(value => { finished = true; return value; });
  while (writes === 0) await new Promise(resolve => setImmediate(resolve));
  assert.equal(finished, false);
  assert.equal((await real.readdir(directory)).filter(name => !name.startsWith('.')).length, 0);
  release(); pendingWrite = null;
  assert.ok(await result); await assertNoStaging(directory);
});

test('publish failure is cleaned up and recoverable', async (t) => {
  const directory = await fixture(t), ctx = context(directory); failRename = true;
  assert.equal(await FirmwareManager.ensureUefi(ctx), null);
  assert.deepEqual(await real.readdir(directory), []);
  failRename = false;
  assert.ok(await FirmwareManager.ensureUefi(ctx));
});

test('invalid package or existing unexpected cache is rejected without overwrite', async (t) => {
  const directory = await fixture(t);
  assert.equal(await FirmwareManager.ensureUefi(context(directory, new Uint8Array(2 * 1024 * 1024))), null);
  assert.equal(await FirmwareManager.ensureUefi(context(directory, code, '../not-an-identity')), null);
  const ctx = context(directory);
  const digest = createHash('sha256').update(code).digest('hex');
  const managed = join(directory, 'aetherium-uefi-' + digest);
  await real.mkdir(managed);
  const target = join(managed, codeName); await real.writeFile(target, 'do not overwrite');
  assert.equal(await FirmwareManager.ensureUefi(ctx), null);
  assert.equal(await real.readFile(target, 'utf8'), 'do not overwrite');
  await assertNoStaging(directory);
});
'''
        with tempfile.TemporaryDirectory(prefix='aether-firmware-test-') as directory:
            test = Path(directory) / 'firmware.test.mts'
            test.write_text(fixture)
            result = subprocess.run(['node', '--experimental-strip-types', '--test', str(test)],
                                    text=True, capture_output=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout)

    def test_native_vars_copy_and_preservation(self):
        fixture = r'''
#include "pflash_firmware.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <dirent.h>
using namespace aetherium;
static void sparse(const std::string &path, off_t size, const char marker) {
    int fd = open(path.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0600);
    assert(fd >= 0); assert(write(fd, &marker, 1) == 1); assert(ftruncate(fd, size) == 0); close(fd);
}
static char first(const std::string &path) { std::ifstream file(path); char out; file.get(out); return out; }
int main(int argc, char **argv) {
    const std::string root = argv[1], source = root + "/template.fd", target = root + "/vars.fd";
    std::string error;
    sparse(source, kArmVirtPflashBytes, 'T');
    assert(ValidatePflashFile(source, false, error));
    assert(EnsureVmPflashVars(source, target, error));
    assert(first(target) == 'T');
    sparse(target, kArmVirtPflashBytes, 'U');
    assert(EnsureVmPflashVars(source, target, error));
    assert(first(target) == 'U'); // Existing user NVRAM survives even a different template.
    assert(first(source) == 'T');
    sparse(target, 2 * 1024 * 1024, 'C');
    assert(!EnsureVmPflashVars(source, target, error));
    assert(first(target) == 'C');
    struct stat status {}; assert(stat(target.c_str(), &status) == 0 && status.st_size == 2 * 1024 * 1024);
    assert(!ValidatePflashFile(target, false, error));
    assert(!ValidatePflashFile(root, false, error));
    const std::string missing = root + "/missing/vars.fd";
    assert(!EnsureVmPflashVars(source, missing, error));
    assert(access(missing.c_str(), F_OK) != 0);
    assert(mkdir((root + "/missing").c_str(), 0700) == 0);
    assert(EnsureVmPflashVars(source, missing, error)); // Retry after recoverable staging failure.
    assert(first(missing) == 'T');
    assert(unlink(target.c_str()) == 0);
    sparse(source, 2 * 1024 * 1024, 'B');
    assert(!EnsureVmPflashVars(source, target, error));
    assert(access(target.c_str(), F_OK) != 0);
    std::cout << "PASS valid copy, existing NVRAM, malformed preservation, missing parent/retry, invalid template\n";
}
'''
        with tempfile.TemporaryDirectory(prefix='aether-pflash-test-') as directory:
            path = Path(directory)
            source = path / 'fixture.cpp'
            source.write_text(fixture)
            binary = path / 'fixture'
            result = subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-I',
                                     str(ROOT / 'entry/src/main/cpp'), str(source), '-o', str(binary)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary), directory], text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout)


if __name__ == '__main__':
    unittest.main()
