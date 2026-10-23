# SPDX-License-Identifier: GPL-2.0-or-later
"""Checker-logic fixtures only: passing these tests is NOT an SDK build result.

No SDK headers, tool executables, compiled stubs or target libraries are created.
CLI tests exercise failure without an SDK; positive cases test evidence parsers.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "tools/check_sdk20.py"
SPEC = importlib.util.spec_from_file_location("sdk20_gate", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

ARM64_HEADER = """ELF Header:
  Class:                             ELF64
  Data:                              2's complement, little endian
  Type:                              DYN (Shared object file)
  Machine:                           AArch64
"""


def symbol(name, section="12", binding="GLOBAL", visibility="DEFAULT", kind="FUNC"):
    return f"  1: 0000000000001000 16 {kind} {binding} {visibility} {section} {name}\n"


def dynamic(*names):
    return "".join(f"0x0000000000000001 (NEEDED) Shared library: [{name}]\n" for name in names)


class EvidenceParserTests(unittest.TestCase):
    def test_arm64_shared_elf_fixture(self):
        gate.check_elf(ARM64_HEADER, "fixture")

    def test_rejects_wrong_elf_class_endian_type_and_architecture(self):
        for before, after in (("ELF64", "ELF32"), ("little endian", "big endian"),
                              ("DYN", "EXEC"), ("AArch64", "Advanced Micro Devices X86-64")):
            with self.subTest(field=before), self.assertRaises(gate.GateError):
                gate.check_elf(ARM64_HEADER.replace(before, after), "fixture")

    def test_accepts_all_defined_runtime_exports(self):
        table = "".join(symbol(name) for name in sorted(gate.RUNTIME_EXPORTS))
        exports, _ = gate.check_exports(table, gate.RUNTIME_EXPORTS, "fixture")
        self.assertEqual(exports, gate.RUNTIME_EXPORTS)

    def test_rejects_each_missing_runtime_export(self):
        for missing in gate.RUNTIME_EXPORTS:
            table = "".join(symbol(name) for name in gate.RUNTIME_EXPORTS - {missing})
            with self.subTest(export=missing), self.assertRaises(gate.GateError):
                gate.check_exports(table, gate.RUNTIME_EXPORTS, "fixture")

    def test_undefined_hidden_local_or_object_symbol_is_not_export(self):
        for kwargs in ({"section": "UND"}, {"visibility": "HIDDEN"},
                       {"binding": "LOCAL"}, {"kind": "OBJECT"}):
            with self.subTest(symbol=kwargs), self.assertRaises(gate.GateError):
                gate.check_exports(symbol("RegisterAetherRuntime", **kwargs),
                                   {"RegisterAetherRuntime"}, "fixture")

    def test_recognizes_versioned_napi_import_separately(self):
        exports, imports = gate.symbols(symbol("RegisterAetherRuntime") +
                                       symbol("napi_module_register@NAPI_1", section="UND"))
        self.assertEqual(exports, {"RegisterAetherRuntime"})
        self.assertEqual(imports, {"napi_module_register"})

    def test_napi_dependencies_fixture(self):
        required = {"libaether_runtime.so", "libace_napi.z.so"}
        self.assertEqual(gate.check_dependencies(dynamic(*required), required, "fixture"), required)

    def test_rejects_missing_runtime_or_ace_dependency(self):
        required = {"libaether_runtime.so", "libace_napi.z.so"}
        for missing in required:
            with self.subTest(dependency=missing), self.assertRaises(gate.GateError):
                gate.check_dependencies(dynamic(*(required - {missing})), required, "fixture")

    def test_rejects_host_libc_and_loader(self):
        for host in ("libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "ld-linux-aarch64.so.1"):
            with self.subTest(dependency=host), self.assertRaises(gate.GateError):
                gate.check_dependencies(dynamic(host), set(), "fixture")


class HeaderDependencyTests(unittest.TestCase):
    native = Path("/checker fixture/HarmonyOS SDK20/native")
    headers = ("native_api.h", "native_node_api.h")

    def dependencies(self, names):
        return "CMakeFiles/aether_runtime_napi.dir/harmonyos/napi_runtime.cpp.o: #deps 3, deps mtime 1 (VALID)\n" + "".join(
            f"    {self.native / 'sysroot/usr/include/napi' / name}\n" for name in names)

    def test_accepts_sdk_dependency_paths_containing_spaces(self):
        gate.check_napi_headers(self.dependencies(self.headers), self.native)

    def test_rejects_each_missing_napi_header(self):
        for missing in self.headers:
            with self.subTest(missing=missing), self.assertRaisesRegex(gate.GateError, missing):
                gate.check_napi_headers(self.dependencies(name for name in self.headers if name != missing),
                                        self.native)

    def test_rejects_shadow_header_even_when_sdk_header_is_also_present(self):
        for shadow in self.headers:
            dependencies = self.dependencies(self.headers) + f"    /host include/napi/{shadow}\n"
            with self.subTest(shadow=shadow), self.assertRaisesRegex(gate.GateError, shadow):
                gate.check_napi_headers(dependencies, self.native)


class LinkCommandTests(unittest.TestCase):
    def test_both_links_reject_undefined_symbols(self):
        log = "\n".join(f"[1/2] clang++ -shared -Wl,--no-undefined -o {library} object.o"
                        for library in ("libaether_runtime.so", "libaether_runtime_napi.so"))
        gate.check_link_commands(log)
        for library in ("libaether_runtime.so", "libaether_runtime_napi.so"):
            permissive = log.replace(f"-Wl,--no-undefined -o {library}", f"-o {library}")
            with self.subTest(library=library), self.assertRaisesRegex(gate.GateError, library):
                gate.check_link_commands(permissive)


class ArtifactPresenceTests(unittest.TestCase):
    # Only filesystem query results are mocked; no SDK files or binaries exist.
    def test_requires_both_nonempty_artifacts(self):
        build = Path("/checker-fixture/build")
        with patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "stat", return_value=SimpleNamespace(st_size=1)):
            self.assertEqual(set(gate.artifacts(build)), {"runtime", "napi"})

    def test_missing_or_empty_napi_module_cannot_pass(self):
        build = Path("/checker-fixture/build")
        for exists, size in ((False, 1), (True, 0)):
            with self.subTest(exists=exists, size=size), \
                    patch.object(Path, "is_file", autospec=True,
                                 side_effect=lambda path: exists if "napi" in path.name else True), \
                    patch.object(Path, "stat", autospec=True,
                                 side_effect=lambda path: SimpleNamespace(st_size=size if "napi" in path.name else 1)), \
                    self.assertRaisesRegex(gate.GateError, "missing or empty napi artifact"):
                gate.artifacts(build)

    def test_missing_runtime_cannot_pass(self):
        with patch.object(Path, "is_file", return_value=False), \
                self.assertRaisesRegex(gate.GateError, "missing or empty runtime artifact"):
            gate.artifacts(Path("/checker-fixture/build"))


class MetadataTests(unittest.TestCase):
    def test_native_api20_metadata_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory)
            metadata = {"path": "native", "apiVersion": "20", "version": "6.0.0.123"}
            (native / "oh-uni-package.json").write_text(json.dumps(metadata))
            self.assertEqual(gate.read_metadata(native), metadata)

    def test_rejects_non_object_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory)
            for metadata in ([], None, "20"):
                (native / "oh-uni-package.json").write_text(json.dumps(metadata))
                with self.subTest(metadata=metadata), self.assertRaisesRegex(gate.GateError, "JSON object"):
                    gate.read_metadata(native)

    def test_wrong_api_component_or_missing_version(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory)
            for field, value in (("apiVersion", "18"), ("apiVersion", "21"),
                                 ("apiVersion", "20.0"), ("path", "ets"), ("version", "")):
                metadata = {"path": "native", "apiVersion": "20", "version": "6.0.0.123", field: value}
                (native / "oh-uni-package.json").write_text(json.dumps(metadata))
                with self.subTest(field=field, value=value), self.assertRaises(gate.GateError):
                    gate.read_metadata(native)


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / "fixture native"
        self.build = self.root / "build"
        system_dir = self.build / "CMakeFiles/3.28.3"
        system_dir.mkdir(parents=True)
        self.system = system_dir / "CMakeSystem.cmake"
        self.system.write_text('set(CMAKE_SYSTEM_NAME "OHOS")\nset(CMAKE_CROSSCOMPILING "TRUE")\n')
        self.cache = {
            "AETHER_RUNTIME_NAPI": "ON", "AETHER_RUNTIME_TESTS": "OFF",
            "OHOS_ARCH": "arm64-v8a", "OHOS_PLATFORM_LEVEL": "20",
            "CMAKE_TOOLCHAIN_FILE": str(self.native / "build/cmake/ohos.toolchain.cmake"),
            "CMAKE_C_COMPILER": str(self.native / "llvm/bin/clang"),
            "CMAKE_CXX_COMPILER": str(self.native / "llvm/bin/clang++"),
        }
        self.commands = [{"file": str(self.root / source), "arguments": [
            str(self.native / "llvm/bin/clang++"), "--target=aarch64-linux-ohos",
            f"--sysroot={self.native / 'sysroot'}", "-c", str(self.root / source)]}
            for source in ("aether_runtime.cpp", "napi_runtime.cpp")]
        self.write_evidence()

    def write_evidence(self):
        (self.build / "CMakeCache.txt").write_text("// checker fixture, not a build\n" + "".join(
            f"{key}:STRING={value}\n" for key, value in self.cache.items()))
        (self.build / "compile_commands.json").write_text(json.dumps(self.commands))

    def test_cross_configuration_fixture(self):
        self.assertEqual(gate.check_configuration(self.build, self.native), self.cache)

    def test_rejects_default_off_napi_host_tests_wrong_arch_or_api(self):
        for key, value in (("AETHER_RUNTIME_NAPI", "OFF"), ("AETHER_RUNTIME_TESTS", "ON"),
                           ("OHOS_ARCH", "x86_64"), ("OHOS_PLATFORM_LEVEL", "18")):
            original = self.cache[key]
            self.cache[key] = value
            self.write_evidence()
            with self.subTest(flag=key), self.assertRaises(gate.GateError):
                gate.check_configuration(self.build, self.native)
            self.cache[key] = original

    def test_rejects_missing_napi_compile_command(self):
        self.commands.pop()
        self.write_evidence()
        with self.assertRaisesRegex(gate.GateError, "napi_runtime.cpp"):
            gate.check_configuration(self.build, self.native)

    def test_rejects_host_compiler_target_and_sysroot(self):
        for index, replacement in ((0, "/usr/bin/clang++"), (1, "--target=aarch64-linux-gnu"),
                                    (2, "--sysroot=/usr")):
            original = self.commands[1]["arguments"][index]
            self.commands[1]["arguments"][index] = replacement
            self.write_evidence()
            with self.subTest(argument=index), self.assertRaises(gate.GateError):
                gate.check_configuration(self.build, self.native)
            self.commands[1]["arguments"][index] = original

    def test_rejects_host_system_or_disabled_cross_compilation(self):
        for system in ('set(CMAKE_SYSTEM_NAME "Linux")\nset(CMAKE_CROSSCOMPILING "TRUE")',
                       'set(CMAKE_SYSTEM_NAME "OHOS")\nset(CMAKE_CROSSCOMPILING "FALSE")'):
            self.system.write_text(system)
            with self.subTest(system=system), self.assertRaises(gate.GateError):
                gate.check_configuration(self.build, self.native)

    def test_rejects_host_test_source_in_sdk_build(self):
        self.commands.append({"file": str(self.root / "mock_core.cpp"), "arguments": ["unused"]})
        self.write_evidence()
        with self.assertRaisesRegex(gate.GateError, "host test targets"):
            gate.check_configuration(self.build, self.native)


class GateFailureCliTests(unittest.TestCase):
    def invoke(self, output, *args):
        env = os.environ.copy()
        env.pop("AETHER_SDK20_NATIVE", None)
        return subprocess.run([sys.executable, str(SCRIPT), "--output-dir", str(output), *args],
                              text=True, capture_output=True, env=env, check=False)

    def test_missing_sdk_is_nonzero_and_records_unverified(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "missing-sdk"
            process = self.invoke(output)
            self.assertNotEqual(process.returncode, 0)
            result = json.loads((output / "result.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertIn("SDK20 unverified", result["error"])
            self.assertFalse((output / "build").exists())
            self.assertEqual(result["phone_core_integration"], "not-tested")
            self.assertEqual(result["device_execution"], "not-tested")

    def test_absent_native_tree_does_not_fall_back_to_host(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "missing-native"
            process = self.invoke(output, "--native-sdk", str(Path(directory) / "absent"))
            self.assertNotEqual(process.returncode, 0)
            result = json.loads((output / "result.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertIn("missing native SDK metadata", result["error"])
            self.assertFalse((output / "build").exists())

    def test_existing_output_is_refused_without_rewriting_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            evidence = output / "result.json"
            evidence.write_text('{"status": "fixture-must-not-be-reused"}\n')
            original = evidence.read_bytes()
            process = self.invoke(output)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("output directory must be new", process.stderr)
            self.assertEqual(evidence.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
