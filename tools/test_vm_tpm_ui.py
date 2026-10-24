"""Execute production TPM availability adapters with a controlled native API."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_vm_stop_lifecycle import function

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "entry/src/main/ets/utils"


class TpmUiTests(unittest.TestCase):
    def test_native_capability_is_required_and_errors_are_unavailable(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node 24 is required for TypeScript stripping")
        version = subprocess.check_output([node, "--version"], text=True).strip()
        self.assertGreaterEqual(int(version.lstrip("v").split(".")[0]), 24)
        manager = (UTILS / "Windows11Config.ets").read_text(encoding="utf-8")
        tester = (UTILS / "Windows11CompatibilityTester.ets").read_text(encoding="utf-8")
        fixture = r'''
import assert from 'node:assert/strict';
let nativeAvailable = false;
let nativeError = false;
const qemu = { isTpmAvailable: (_?: string): boolean => {
  if(nativeError) throw new Error('missing native capability');
  return nativeAvailable;
}};
class Windows11ConfigManager {
'''
        fixture += function(manager, r"  static isTPMAvailable\(vmName\?: string\): boolean")
        fixture += "\n}\nclass Tester {\n"
        fixture += function(tester, r"  private checkTpmSupport\(\): boolean")
        fixture += r'''
  available(): boolean { return this.checkTpmSupport(); }
}
const tester = new Tester();
assert.equal(tester.available(), false, 'absent backend must not be advertised');
assert.equal(Windows11ConfigManager.isTPMAvailable('vm'), false);
nativeAvailable = true;
assert.equal(tester.available(), true, 'delegate an actual native capability');
nativeError = true;
assert.equal(tester.available(), false, 'native failure must not manufacture capability');
assert.equal(Windows11ConfigManager.isTPMAvailable('vm'), false);
console.log('PASS TPM UI follows native capability and fails closed on errors');
'''
        with tempfile.TemporaryDirectory(prefix="aether-tpm-ui-") as tmp:
            path = Path(tmp) / "test.mts"
            path.write_text(fixture, encoding="utf-8")
            result = subprocess.run([node, "--experimental-strip-types", str(path)],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
