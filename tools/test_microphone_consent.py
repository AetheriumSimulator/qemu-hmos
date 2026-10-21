"""Execute production microphone policies with mocked system/native APIs.

Node 24 strips TypeScript annotations after copying the pure ArkTS controllers to
isolated .ts files. This is behavioral coverage, not an ArkTS SDK build.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MicrophoneConsentTests(unittest.TestCase):
    def test_consent_lifecycle(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node 24 is required for microphone state tests")
        version = subprocess.check_output([node, "--version"], text=True).strip()
        self.assertGreaterEqual(int(version.lstrip("v").split(".")[0]), 24,
                                "Use Node 24 to execute the actual ArkTS controller")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for controller in ("MicrophoneConsent", "MicrophoneWindows"):
                shutil.copyfile(
                    ROOT / f"entry/src/main/ets/managers/{controller}.ets",
                    root / f"{controller}.ts")
            manager = (ROOT / "entry/src/main/ets/managers/MicrophoneManager.ets").read_text()
            imports = {
                "import abilityAccessCtrl from '@ohos.abilityAccessCtrl'":
                    "import { abilityAccessCtrl } from './platform.mjs'",
                "import bundleManager from '@ohos.bundle.bundleManager'":
                    "import { bundleManager } from './platform.mjs'",
                "import common from '@ohos.app.ability.common'": "",
                "import ApplicationStateChangeCallback from '@ohos.app.ability.ApplicationStateChangeCallback'": "",
                "import commonEventManager from '@ohos.commonEventManager'":
                    "import { commonEventManager } from './platform.mjs'",
                "import power from '@ohos.power'":
                    "import { power } from './platform.mjs'",
                "import screenLock from '@ohos.screenLock'":
                    "import { screenLock } from './platform.mjs'",
                "import window from '@ohos.window'":
                    "import { window } from './platform.mjs'",
                "import qemu from 'qemu_hmos'":
                    "import { qemu } from './platform.mjs'",
                "import { MicrophoneConsent, MicrophoneConsentPort, MicrophoneConsentState } from './MicrophoneConsent'":
                    "import { MicrophoneConsent } from './MicrophoneConsent.ts'",
                "import { MicrophoneWindows } from './MicrophoneWindows'":
                    "import { MicrophoneWindows } from './MicrophoneWindows.ts'",
            }
            # Only imports change: the tested Manager methods remain production code.
            for original, replacement in imports.items():
                self.assertIn(original, manager, f"Update the platform mock import: {original}")
                manager = manager.replace(original, replacement, 1)
            (root / "MicrophoneManager.ts").write_text(manager)
            shutil.copyfile(ROOT / "tools/tests/microphone/platform.mjs",
                            root / "platform.mjs")
            suites = []
            for name in ("consent.test.mjs", "windows.test.mjs", "manager.test.mjs"):
                shutil.copyfile(ROOT / "tools/tests/microphone" / name,
                                root / name)
                suites.append(str(root / name))
            subprocess.run([node, "--test", *suites], check=True)


if __name__ == "__main__":
    unittest.main()
