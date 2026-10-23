#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Fail-closed HarmonyOS SDK20 arm64 compile/link gate (never runs target code)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

RUNTIME_EXPORTS = {
    "aether_runtime_abi", "aether_runtime_load", "aether_runtime_run",
    "aether_runtime_get_state", "aether_runtime_last_error",
}
NAPI_RUNTIME_IMPORTS = RUNTIME_EXPORTS - {"aether_runtime_abi"}
TARGET = "aarch64-linux-ohos"


class GateError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_metadata(native):
    path = native / "oh-uni-package.json"
    require(path.is_file(), f"missing native SDK metadata: {path}")
    metadata = json.loads(path.read_text())
    require(isinstance(metadata, dict), "native SDK metadata must be a JSON object")
    require(str(metadata.get("apiVersion")) == "20", "native SDK apiVersion must be exactly 20")
    require(metadata.get("path") == "native", "SDK metadata must describe the native component")
    require(bool(re.fullmatch(r"\d+(?:\.\d+){2,3}", str(metadata.get("version", "")))),
            "native SDK version is missing or malformed")
    return metadata


def check_elf(header, label):
    for pattern, description in (
        (r"Class:\s+ELF64\b", "ELF64"),
        (r"Data:\s+2's complement, little endian", "little endian"),
        (r"Type:\s+DYN\b", "shared object"),
        (r"Machine:\s+AArch64\b", "AArch64"),
    ):
        require(re.search(pattern, header), f"{label}: expected {description}")


def symbols(text):
    """Read wide readelf --dyn-syms output; UND is never an export."""
    exports, imports = set(), set()
    for line in text.splitlines():
        columns = line.split()
        if len(columns) < 8 or not re.fullmatch(r"\d+:", columns[0]):
            continue
        _, _, _, kind, binding, visibility, section, name = columns[:8]
        name = name.split("@")[0]
        if section == "UND":
            imports.add(name)
        elif binding in {"GLOBAL", "WEAK"} and visibility in {"DEFAULT", "PROTECTED"} and kind == "FUNC":
            exports.add(name)
    return exports, imports


def check_exports(symbol_table, required, label):
    exports, imports = symbols(symbol_table)
    require(required <= exports, f"{label}: missing defined exports: {sorted(required - exports)}")
    return exports, imports


def needed(dynamic):
    return set(re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dynamic))


def check_dependencies(dynamic, required, label):
    actual = needed(dynamic)
    require(required <= actual, f"{label}: missing DT_NEEDED: {sorted(required - actual)}")
    require(not any(re.search(r"(?:libc|libm|libdl|libpthread)\.so\.\d|ld-linux", name) for name in actual),
            f"{label}: host GNU/Linux dependency found")
    return actual


def artifacts(build):
    paths = {"runtime": build / "libaether_runtime.so", "napi": build / "libaether_runtime_napi.so"}
    for label, path in paths.items():
        require(path.is_file() and path.stat().st_size > 0, f"missing or empty {label} artifact: {path}")
    return paths


def check_napi_headers(dependencies, native):
    paths = {Path(line.strip()).resolve() for line in dependencies.splitlines() if line.startswith("    ")}
    for name in ("native_api.h", "native_node_api.h"):
        expected = (native / "sysroot/usr/include/napi" / name).resolve()
        actual = {path for path in paths if path.name == name and path.parent.name == "napi"}
        require(actual == {expected}, f"N-API header must come from selected SDK: {name}")


def check_link_commands(build_log):
    for library in ("libaether_runtime.so", "libaether_runtime_napi.so"):
        require(any(f"-o {library}" in line and "-Wl,--no-undefined" in line
                    for line in build_log.splitlines()),
                f"{library}: link command must reject unresolved symbols")


def read_cache(path):
    cache = {}
    for line in path.read_text().splitlines():
        match = re.match(r"([^:#/][^:]*):[^=]+=(.*)$", line)
        if match:
            cache[match[1]] = match[2]
    return cache


def check_configuration(build, native):
    cache = read_cache(build / "CMakeCache.txt")
    for key, expected in {
        "AETHER_RUNTIME_NAPI": "ON", "AETHER_RUNTIME_TESTS": "OFF",
        "OHOS_ARCH": "arm64-v8a", "OHOS_PLATFORM_LEVEL": "20",
    }.items():
        require(cache.get(key) == expected, f"CMake must configure {key}={expected}")
    for key, expected in {
        "CMAKE_TOOLCHAIN_FILE": native / "build/cmake/ohos.toolchain.cmake",
        "CMAKE_C_COMPILER": native / "llvm/bin/clang",
        "CMAKE_CXX_COMPILER": native / "llvm/bin/clang++",
    }.items():
        require(Path(cache.get(key, "")).resolve() == expected.resolve(),
                f"{key} does not point to the selected SDK")
    systems = list((build / "CMakeFiles").glob("*/CMakeSystem.cmake"))
    require(len(systems) == 1, "missing or ambiguous CMake system evidence")
    system = systems[0].read_text()
    require(re.search(r'set\(CMAKE_SYSTEM_NAME "OHOS"\)', system), "CMake target system must be OHOS")
    require(re.search(r'set\(CMAKE_CROSSCOMPILING "TRUE"\)', system), "CMake must cross compile")
    commands = json.loads((build / "compile_commands.json").read_text())
    for source in ("aether_runtime.cpp", "napi_runtime.cpp"):
        entries = [entry for entry in commands if Path(entry["file"]).name == source]
        require(len(entries) == 1, f"expected a compile command for {source}")
        args = entries[0].get("arguments") or shlex.split(entries[0]["command"])
        require(Path(args[0]).resolve() == (native / "llvm/bin/clang++").resolve(),
                f"{source}: compiler is outside selected SDK")
        joined = " ".join(args)
        require(re.search(r"(?:--target=|-target\s+)aarch64(?:-unknown)?-linux-ohos\b", joined),
                f"{source}: missing OHOS arm64 target")
        require(f"--sysroot={native / 'sysroot'}" in args or
                any(args[i:i+2] == ["--sysroot", str(native / 'sysroot')] for i in range(len(args))),
                f"{source}: sysroot is outside selected SDK")
    require(not any(Path(entry["file"]).name in {"mock_core.cpp", "runtime_test.cpp", "c_header_test.c"}
                    for entry in commands), "host test targets must not be compiled by SDK gate")
    return {key: cache[key] for key in (
        "AETHER_RUNTIME_NAPI", "AETHER_RUNTIME_TESTS", "OHOS_ARCH", "OHOS_PLATFORM_LEVEL",
        "CMAKE_TOOLCHAIN_FILE", "CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER")}


def run(command, log, env):
    command = [str(part) for part in command]
    print("+ " + shlex.join(command), flush=True)
    with log.open("w") as stream:
        stream.write("$ " + shlex.join(command) + "\n")
        stream.flush()
        process = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, env=env, check=False)
    output = log.read_text(errors="replace")
    print(output, end="", flush=True)
    require(process.returncode == 0, f"command exited {process.returncode}; see {log.name}")
    return output


def validate(native, output, result):
    require(native is not None, "SDK20 unverified: supply --native-sdk or AETHER_SDK20_NATIVE")
    native = native.resolve()
    result["native_sdk"] = str(native)
    result["sdk_metadata"] = read_metadata(native)
    required_files = [
        "build/cmake/ohos.toolchain.cmake", "llvm/bin/clang", "llvm/bin/clang++",
        "llvm/bin/llvm-readelf", "sysroot/usr/include/napi/native_api.h",
        "sysroot/usr/include/napi/native_node_api.h",
    ]
    for relative in required_files:
        path = native / relative
        require(path.is_file(), f"missing SDK file: {relative}")
        if relative.startswith("llvm/bin/"):
            require(os.access(path, os.X_OK), f"SDK tool is not executable: {relative}")
    # No ambient CC/CXX, SDK aliases, include or library search paths may supply host inputs.
    env = os.environ.copy()
    for name in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CPATH",
                 "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH",
                 "CMAKE_PREFIX_PATH", "CMAKE_TOOLCHAIN_FILE", "OHOS_NDK_HOME", "OHOS_SDK_HOME"):
        env.pop(name, None)
    env["LC_ALL"] = "C"
    cmake = shutil.which("cmake")
    require(cmake, "cmake is required")
    ninja = shutil.which("ninja")
    require(ninja, "ninja is required")
    compiler = native / "llvm/bin/clang++"
    version = run([compiler, "--version"], output / "compiler-version.log", env)
    require(re.search(r"clang version\s+\d+", version), "selected SDK compiler is not Clang")
    result["compiler_version"] = version.splitlines()[1:]
    triple = run([compiler, f"--target={TARGET}", "-dumpmachine"], output / "compiler-target.log", env)
    require(re.search(r"^aarch64(?:-unknown)?-linux-ohos$", triple, re.M), "compiler target is not OHOS arm64")
    # Ask the selected compiler where the actual SDK linker input lives.
    resolved = run([compiler, f"--target={TARGET}", f"--sysroot={native / 'sysroot'}",
                    "-print-file-name=libace_napi.z.so"], output / "ace-path.log", env).splitlines()[-1]
    ace = Path(resolved).resolve()
    require(ace.is_file() and ace.is_relative_to(native / "sysroot"),
            "libace_napi.z.so must resolve inside the selected SDK sysroot")
    result["sdk_input_sha256"] = {
        relative: sha256(native / relative) for relative in required_files + ["oh-uni-package.json"]
    }
    result["sdk_ace"] = {"path": str(ace), "sha256": sha256(ace)}
    build = output / "build"
    source = Path(__file__).resolve().parents[1]
    run([cmake, "-S", source, "-B", build, "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={native / 'build/cmake/ohos.toolchain.cmake'}",
         f"-DCMAKE_C_COMPILER={native / 'llvm/bin/clang'}",
         f"-DCMAKE_CXX_COMPILER={compiler}", "-DOHOS_ARCH=arm64-v8a", "-DOHOS_PLATFORM_LEVEL=20",
         "-DOHOS_STL=c++_shared", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
         "-DAETHER_RUNTIME_NAPI=ON", "-DAETHER_RUNTIME_TESTS=OFF",
         "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-undefined -Wl,--trace"], output / "configure.log", env)
    result["configuration"] = check_configuration(build, native)
    build_log = run([cmake, "--build", build, "--target", "aether_runtime", "aether_runtime_napi",
                     "--parallel", "2", "--verbose"], output / "build.log", env)
    built = artifacts(build)
    check_link_commands(build_log)
    dependencies = run([ninja, "-C", build, "-t", "deps"], output / "header-dependencies.log", env)
    check_napi_headers(dependencies, native)
    # --trace records the actual input chosen by ld, not merely a -l argument.
    linked_paths = {Path(line.strip()).resolve() for line in build_log.splitlines()
                    if line.strip().endswith("libace_napi.z.so")}
    require(ace in linked_paths, "linker trace does not contain the selected SDK libace_napi.z.so")
    readelf = native / "llvm/bin/llvm-readelf"
    tables = {}
    result["artifacts"] = {}
    for label, path in (("sdk-ace", ace), *built.items()):
        require(path.is_file() and path.stat().st_size > 0, f"missing or empty {label} artifact: {path}")
        header = run([readelf, "--file-header", path], output / f"{label}-header.log", env)
        check_elf(header, label)
        table = run([readelf, "--dyn-syms", "--wide", path], output / f"{label}-symbols.log", env)
        dynamic = run([readelf, "--dynamic", "--wide", path], output / f"{label}-dynamic.log", env)
        tables[label] = table
        if label == "sdk-ace":
            continue
        required = RUNTIME_EXPORTS if label == "runtime" else {"RegisterAetherRuntime"}
        exports, imports = check_exports(table, required, label)
        dependencies = check_dependencies(dynamic, {"libaether_runtime.so", "libace_napi.z.so"}
                                          if label == "napi" else set(), label)
        require(not re.search(r"@GLIBC_\d", table), f"{label}: host glibc symbol version found")
        result["artifacts"][label] = {"path": str(path), "sha256": sha256(path),
                                      "required_exports": sorted(required), "needed": sorted(dependencies)}
    sdk_exports, _ = symbols(tables["sdk-ace"])
    _, imports = symbols(tables["napi"])
    napi_imports = {name for name in imports if name.startswith("napi_")}
    require("napi_module_register" in napi_imports, "N-API registration import is missing")
    require(napi_imports <= sdk_exports, f"N-API imports missing from SDK: {sorted(napi_imports - sdk_exports)}")
    require(NAPI_RUNTIME_IMPORTS <= imports, "N-API module must import the shared runtime ABI")
    result["napi_imports"] = sorted(napi_imports)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-sdk", type=Path, default=os.environ.get("AETHER_SDK20_NATIVE"))
    parser.add_argument("--output-dir", required=True, type=Path, help="new directory for build and evidence")
    args = parser.parse_args(argv)
    output = args.output_dir.resolve()
    # Never reuse stale outputs, and never overwrite earlier evidence.
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        print(f"SDK20 gate failed: output directory must be new: {error}", file=sys.stderr)
        return 1
    result = {"schema": "aether-sdk20-compile-v1", "status": "failed",
              "scope": "compile-link-elf-only", "phone_core_integration": "not-tested",
              "device_execution": "not-tested", "repeat_start": "not-supported-reentrant-0"}
    try:
        source = Path(__file__).resolve().parents[1]
        result["source_sha256"] = {relative: sha256(source / relative) for relative in (
            "CMakeLists.txt", "src/aether_runtime.cpp", "include/aether_runtime.h",
            "harmonyos/napi_runtime.cpp", "tools/check_sdk20.py")}
        result["ci_commit"] = os.environ.get("GITHUB_SHA")
        result["sdk_archive_sha256"] = os.environ.get("AETHER_SDK20_SHA256")
        validate(args.native_sdk, output, result)
        result["status"] = "passed"
    except (GateError, OSError, ValueError) as error:
        result["error"] = str(error)
        print(f"SDK20 gate failed: {error}", file=sys.stderr)
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"SDK20 compile/link/ELF: {result['status']}; evidence: {output / 'result.json'}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
