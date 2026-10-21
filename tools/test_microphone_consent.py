"""Execute the production consent state machine with mocked system/native APIs.

Node 24 strips TypeScript annotations after copying the pure ArkTS controller to
an isolated .ts file. This is behavioral coverage, not an ArkTS SDK build.
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
            shutil.copyfile(
                ROOT / "entry/src/main/ets/managers/MicrophoneConsent.ets",
                root / "MicrophoneConsent.ts")
            shutil.copyfile(ROOT / "tools/tests/microphone/consent.test.mjs",
                            root / "consent.test.mjs")
            subprocess.run([node, "--test", str(root / "consent.test.mjs")],
                           check=True)


if __name__ == "__main__":
    unittest.main()
