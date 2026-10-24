"""Execute production ArkTS storage/picker methods against controlled host I/O.

Only platform imports and ArkUI wrappers are replaced. This is behavioral host
coverage, not a HarmonyOS picker/device acceptance or SDK compilation result.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"


def method(source, name):
    found = re.search(r"^  (?:private )?(?:async )?" + name +
                      r"\([^\n]*\{\n.*?^  }$", source, re.MULTILINE | re.DOTALL)
    if not found:
        raise AssertionError("Production method missing: " + name)
    return found.group()


class VmImportTests(unittest.TestCase):
    def test_storage_and_creation_transactions(self):
        node = shutil.which("node")
        self.assertIsNotNone(node)
        version = subprocess.check_output([node, "--version"], text=True)
        self.assertGreaterEqual(int(version.lstrip("v").split(".")[0]), 24)
        with tempfile.TemporaryDirectory(prefix="aether-import-tests-") as tmp:
            out = Path(tmp)
            storage = (ETS / "utils/StoragePaths.ets").read_text()
            storage = re.sub(r"^import .*\n", "", storage, flags=re.MULTILINE)
            (out / "StoragePaths.ts").write_text(
                "import { fs, hilog } from './platform.mjs';\n" + storage)
            for name in ("platform.mjs", "storage.test.mjs", "ui.test.mjs"):
                shutil.copyfile(ROOT / "tools/tests/imports" / name, out / name)
            page = (ETS / "pages/Index.ets").read_text()
            component = (ETS / "components/VMCreateWizard.ets").read_text()
            generated = (ROOT / "tools/tests/imports/ui-harness.mjs").read_text()
            for name in ("QemuConfig", "VMMeta"):
                generated += re.search(r"^class " + name + r" \{.*?^}", page,
                                       re.MULTILINE | re.DOTALL).group() + "\n"
            generated += "export class IndexHarness extends PageState {\n"
            for name in ("closeSheet", "selectISO", "pickIsoForVm", "ejectIso",
                         "createVMFromWizardResult", "startVM"):
                generated += method(page, name) + "\n"
            generated += "}\nexport class WizardHarness extends WizardState {\n"
            for name in ("aboutToAppear", "aboutToDisappear", "cancelWizard", "selectISO",
                         "selectDisk", "goNext", "goBack", "complete"):
                generated += method(component, name) + "\n"
            generated += "}\n"
            (out / "ui-harness.ts").write_text(generated)
            subprocess.run([node, "--test", str(out / "storage.test.mjs"),
                            str(out / "ui.test.mjs")], check=True, timeout=90)
            # Actual drag/close dismissal must share the tested epoch invalidation.
            dismissal = page[page.index("onDisappear: (): void => {"):][:400]
            self.assertIn("this.closeSheet()", dismissal)


if __name__ == "__main__":
    unittest.main()
