"""Compile the production launch builder and TPM API with host-only fixtures.

This checks the argv contract; it does not boot QEMU, a guest or HarmonyOS.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_vm_stop_lifecycle import function

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / "entry/src/main/cpp"
SOURCE = Path(os.environ.get("AETHER_NAPI_SOURCE", CPP / "napi_init.cpp"))
WRAPPER = Path(os.environ.get("AETHER_WRAPPER_SOURCE", CPP / "qemu_wrapper.cpp"))

PREFIX = r'''
#include "ohaudio_args.h"
#include "pflash_firmware.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
static std::atomic<uint32_t> g_id_suffix_counter {0};
static void HilogPrint(const std::string&) {}
static void WriteLog(const std::string&, const std::string&) {}
static bool FileExists(const std::string& path) { struct stat s; return stat(path.c_str(), &s) == 0; }
static bool IsQcow2FileQuick(const std::string&) { return false; }
static bool CopyFileTruncate(const std::string&, const std::string&) { assert(false); return false; }
static bool PreflightOpen(const std::string&, const std::string&, int) { return true; }
static bool PreflightQcow2Header(const std::string&) { return true; }
static bool PreflightQcow2RefcountTable(const std::string&) { return true; }
'''

HARNESS = r'''
static bool hasPair(const std::vector<std::string>& args, const std::string& key, const std::string& value) {
    for (size_t i=0; i+1<args.size(); ++i) if(args[i]==key && args[i+1]==value) return true;
    return false;
}
static VMConfig fixture() {
    VMConfig c{};
    c.name="test"; c.osType="Linux"; c.archType="aarch64"; c.machine="virt";
    c.memoryMB=2048; c.cpuCount=2; c.accel="tcg";
    c.display="vnc=127.0.0.1:1"; c.qemuDataDir="data";
    c.vmDir="vm"; c.efiFirmware="code.fd";
    return c;
}
static void noTpm(const std::vector<std::string>& args) {
    assert(!args.empty());
    for (const auto& arg:args) assert(arg.find("tpm")==std::string::npos);
}
int main(int argc, char** argv) {
    assert(argc==2); std::string scenario=argv[1];
    auto c=fixture();
    if(scenario=="no-tpm") {
        for(const auto& os:{"Linux", "Windows 11", "Windows", "Other", ""}) {
            c.osType=os;
            for(bool install:{false,true}) for(bool headless:{false,true}) {
                c.installMode=install; c.nographic=headless;
                noTpm(BuildQemuArgs(c));
            }
        }
    } else if(scenario=="pci") {
        for(const auto& device:{"virtio-gpu-pci", "virtio-gpu"}) for(bool install:{false,true}) {
            c.displayDevice=device; c.installMode=install;
            auto args=BuildQemuArgs(c);
            assert(hasPair(args,"-device","virtio-gpu-pci"));
            assert(!hasPair(args,"-device","virtio-gpu-device"));
            assert(!hasPair(args,"-device","ramfb"));
        }
    } else if(scenario=="defaults") {
        for(const auto& device:{"", "auto", "none"}) {
            c.displayDevice=device;
            c.installMode=false;
            assert(hasPair(BuildQemuArgs(c),"-device","virtio-gpu-pci"));
            c.installMode=true;
            assert(hasPair(BuildQemuArgs(c),"-device","ramfb"));
        }
        c.displayDevice="ramfb"; c.installMode=false;
        assert(hasPair(BuildQemuArgs(c),"-device","ramfb"));
    } else if(scenario=="mmio") {
        c.displayDevice="virtio-gpu-device";
        for(bool install:{false,true}) {
            c.installMode=install;
            auto args=BuildQemuArgs(c);
            assert(hasPair(args,"-device","virtio-gpu-device"));
            assert(hasPair(args,"-global","virtio-mmio.force-legacy=false"));
            assert(!hasPair(args,"-device","virtio-gpu-pci"));
        }
    } else if(scenario=="headless") {
        c.displayDevice="virtio-gpu-pci"; c.nographic=true;
        auto args=BuildQemuArgs(c);
        assert(std::find(args.begin(),args.end(),"-nographic")!=args.end());
        assert(!hasPair(args,"-device","virtio-gpu-pci"));
        c.nographic=false; c.display="none";
        assert(!hasPair(BuildQemuArgs(c),"-device","virtio-gpu-pci"));
        c.display="vnc=127.0.0.1:1"; c.qemuDataDir="missing-keymaps";
        assert(!hasPair(BuildQemuArgs(c),"-device","virtio-gpu-pci"));
        c.archType="x86_64";
        assert(BuildQemuArgs(c).empty());
    } else if(scenario=="preserve-vars") {
        c.vmDir="vars64";
        for(bool install:{false,true}) {
            c.installMode=install;
            auto args=BuildQemuArgs(c);
            assert(!args.empty());
            assert(hasPair(args,"-drive","file=vars64/edk2-vars.fd,if=pflash,format=raw,unit=1"));
        }
    } else if(scenario=="short-code") {
        c.efiFirmware="short-code.fd";
        assert(BuildQemuArgs(c).empty());
    } else if(scenario=="short-vars") {
        c.vmDir="vars-short";
        for(bool install:{false,true}) {
            c.installMode=install;
            assert(BuildQemuArgs(c).empty());
        }
    } else { assert(false); }
    std::cout << "PASS production launch argv " << scenario << '\n';
}
'''


class VmLaunchArgsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="aether-launch-")
        cls.root = Path(cls.temp.name)
        source = SOURCE.read_text(encoding="utf-8")
        config = source[source.index("struct VMConfig {"):source.index("\n};", source.index("struct VMConfig {")) + 3]
        body = PREFIX + config
        body += function(source, r"static bool IsSupportedQemuArch\(const std::string& archType\)")
        body += function(source, r"static std::vector<std::string> BuildQemuArgs\(const VMConfig& config(?:, std::string\* firmwareError = nullptr)?\)")
        (cls.root / "test.cpp").write_text(body + HARNESS, encoding="utf-8")
        subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-function",
                        "-I", str(CPP), str(cls.root / "test.cpp"), "-o", str(cls.root / "test")], check=True)
        (cls.root / "data/keymaps").mkdir(parents=True)
        (cls.root / "data/keymaps/en-us").write_bytes(b"x" * 2048)
        (cls.root / "vm").mkdir()
        for name, size in (("code.fd", 64 << 20), ("short-code.fd", 2 << 20),
                           ("vars64/edk2-vars.fd", 64 << 20), ("vars-short/edk2-vars.fd", 2 << 20)):
            path = cls.root / name
            path.parent.mkdir(exist_ok=True)
            with path.open("wb") as firmware:
                firmware.write(b"user firmware or saved NVRAM")
                firmware.truncate(size)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_case(self, scenario):
        result = subprocess.run([str(self.root / "test"), scenario], cwd=self.root,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout, end="")

    def test_ordinary_guests_never_request_unavailable_tpm(self):
        self.run_case("no-tpm")

    def test_explicit_pci_and_alias_survive_install_mode(self):
        self.run_case("pci")

    def test_display_defaults_and_ramfb_remain_available(self):
        self.run_case("defaults")

    def test_explicit_mmio_uses_modern_transport(self):
        self.run_case("mmio")

    def test_headless_missing_keymaps_and_unsupported_arch(self):
        self.run_case("headless")

    def assert_preserved(self, name, scenario):
        path = self.root / name
        def digest():
            with path.open("rb") as firmware:
                return hashlib.file_digest(firmware, "sha256").digest()
        original = digest()
        metadata = path.stat()
        self.run_case(scenario)
        self.assertEqual(path.stat().st_ino, metadata.st_ino)
        self.assertEqual(path.stat().st_size, metadata.st_size)
        self.assertEqual(digest(), original, "existing firmware or NVRAM must be unchanged")

    def test_install_mode_preserves_existing_nvram(self):
        self.assert_preserved("vars64/edk2-vars.fd", "preserve-vars")

    def test_invalid_custom_code_fails_without_modification(self):
        self.assert_preserved("short-code.fd", "short-code")

    def test_invalid_existing_nvram_fails_without_reset(self):
        self.assert_preserved("vars-short/edk2-vars.fd", "short-vars")

    def test_tpm_api_does_not_claim_or_create_an_unavailable_backend(self):
        source = WRAPPER.read_text(encoding="utf-8")
        header = (CPP / "qemu_wrapper.h").read_text(encoding="utf-8")
        begin = header.index("typedef struct {", header.index("// TPM 设置结果"))
        end = header.index("} tpm_setup_result_t;", begin) + len("} tpm_setup_result_t;")
        body = PREFIX + header[begin:end] + r'''
static std::string g_last_tpm_error, g_last_tpm_socket, g_last_tpm_state_dir;
static std::map<std::string,std::string> g_tpm_socket_paths, g_tpm_state_dirs;
// No directories, processes or TPM state may be created by an unavailable backend.
static int forbiddenSystem(const char*) { assert(false && "unavailable TPM must not create fake state"); return -1; }
#define system forbiddenSystem
'''
        body += function(source, r"int qemu_setup_tpm\(const char\* vm_name, tpm_setup_result_t\* result\)")
        body += function(source, r"int qemu_is_tpm_available\(const char\* vm_name\)")
        body += r'''
int main() {
    assert(qemu_is_tpm_available("test")==0);
    assert(qemu_is_tpm_available(nullptr)==0);
    tpm_setup_result_t result{};
    for(int retry=0; retry<2; ++retry) {
        assert(qemu_setup_tpm("test", &result)!=0);
        assert(!result.success && !result.socket_path && !result.state_dir);
        assert(result.error_message && std::strlen(result.error_message)>0);
        assert(g_tpm_socket_paths.empty() && g_tpm_state_dirs.empty());
    }
    assert(qemu_setup_tpm(nullptr, &result)!=0);
    assert(qemu_setup_tpm("test", nullptr)!=0);
}
'''
        (self.root / "tpm.cpp").write_text(body, encoding="utf-8")
        subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-function",
                        "-I", str(CPP), str(self.root / "tpm.cpp"), "-o", str(self.root / "tpm")], check=True)
        subprocess.run([str(self.root / "tpm")], cwd=self.root, check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
