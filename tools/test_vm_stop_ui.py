"""Execute Index's actual stop/status methods without ArkUI or a device.

Node strips TypeScript annotations; this is not an ArkTS SDK build.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("AETHER_INDEX_SOURCE",
                            ROOT / "entry/src/main/ets/pages/Index.ets"))


def method(source, name):
    # Index methods end at two-space indentation; nested bodies do not.
    match = re.search(r"^  private (?:async )?" + name + r"\([^\n]*\{\n.*?^  }$",
                      source, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("Production Index method missing: " + name)
    return match.group()


class VmStopUiTests(unittest.TestCase):
    def test_stop_acceptance_and_polled_terminal_state(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node 22.6+ is required for TypeScript stripping")
        version = subprocess.check_output([node, "--version"], text=True).strip()
        parts = tuple(int(value) for value in version.lstrip("v").split(".")[:2])
        self.assertGreaterEqual(parts, (22, 6))
        source = SOURCE.read_text(encoding="utf-8")
        fixture = r'''
import assert from 'node:assert/strict';
type VMStatus = string;
type VMMeta = { name: string, status: VMStatus };
let live = 'running';
let throwNative = false;
let tick: (() => void) | undefined;
let calls = 0;
const setInterval = (callback: () => void, ms: number): number => {
  assert.equal(ms, 2000); calls++; tick = callback; return 1;
};
const qemuModule = { getVmStatus: (_: string): string => {
  if (throwNative) throw new Error('native unavailable');
  return live;
}};
let resolveStop: (result: { success: boolean, message?: string }) => void;
let rejectStop: (reason: Error) => void;
const QemuVMManager = { getInstance: () => ({ stopVM: (_: string) =>
  new Promise((resolve, reject) => { resolveStop = resolve; rejectStop = reject; })
}) };
const promptAction = { showToast: (_: unknown) => {} };
const hilog = { warn: (..._: unknown[]) => {} };
class IndexHarness {
  vms: VMMeta[] = [{ name: 'world', status: 'running' }];
  isLoading = false;
  errorMessage = '';
  statusTimerId = -1;
  saves = 0;
  async saveAllVMs(): Promise<void> { this.saves++; }
'''
        for name in ("stopVM", "refreshVmStatusesOnce", "startStatusTimer"):
            fixture += method(source, name) + "\n"
        fixture += r'''
}
const page = new IndexHarness();
const vm = page.vms[0];
page.startStatusTimer(); page.startStatusTimer();
assert.equal(calls, 1, 'one existing status timer');
let pending = page.stopVM(vm);
assert.equal(vm.status, 'stopping');
live = 'stopping'; tick!();
resolveStop!({ success: true }); await pending;
assert.equal(vm.status, 'stopping', 'accepted must not claim runner completion');
live = 'stopped'; tick!();
assert.equal(vm.status, 'stopped', 'timer must continue polling a stopping VM');
console.log('PASS accepted -> stopping -> polled stopped');

vm.status = 'running'; live = 'stopping';
pending = page.stopVM(vm);
live = 'failed'; tick!();
throwNative = true;
resolveStop!({ success: true }); await pending;
assert.equal(vm.status, 'failed', 'acceptance cannot erase an observed failure');
console.log('PASS terminal failure survives delayed acceptance and unavailable status');

throwNative = false; vm.status = 'running'; live = 'stopping';
pending = page.stopVM(vm);
live = 'stopped'; tick!(); throwNative = true;
resolveStop!({ success: false, message: 'stop monitor unavailable' }); await pending;
assert.equal(vm.status, 'stopped', 'stop error cannot overwrite a polled terminal state');
console.log('PASS error reply preserves already observed completion');

throwNative = false; vm.status = 'running'; live = 'stopping';
pending = page.stopVM(vm);
resolveStop!({ success: true }); await pending;
live = 'failed'; tick!();
assert.equal(vm.status, 'failed', 'sticky native failure is terminal only after completion');
console.log('PASS accepted -> stopping -> polled failed');

vm.status = 'running'; live = 'stopping';
pending = page.stopVM(vm);
live = 'stopped'; tick!();
rejectStop!(new Error('manager rejected')); await pending;
assert.equal(vm.status, 'stopped');
assert.equal(page.isLoading, false);
assert.ok(page.saves > 0);
console.log('PASS rejected promise preserves polled terminal state');
'''
        with tempfile.TemporaryDirectory(prefix="aether-stop-ui-") as directory:
            path = Path(directory) / "stop.test.mts"
            path.write_text(fixture, encoding="utf-8")
            result = subprocess.run([node, "--experimental-strip-types", str(path)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout, end="")
        # Connect status rendering and the detail start action to that same state.
        self.assertIn("Text(getStatusDisplayName(this.getSelectedVM()!.status))", source)
        self.assertIn("Text(getStatusDisplayName(vm.status))", source)
        self.assertIn(".enabled(this.getSelectedVM()!.status === 'stopped' || "
                      "this.getSelectedVM()!.status === 'failed')", source)


if __name__ == "__main__":
    unittest.main()
