# Shared Aether Phone Runtime (ABI v1)

GPL-2.0-or-later; see the root `LICENSE` for the GPLv2 text. This module grants
no proprietary linking exception and does not relicense historical app code.

See [integration, migration and license review](../docs/AETHER_RUNTIME_REUSE.md).
This is an additive, optional QEMU 11.1 Phone ABI adapter. It is **not** the
QEMU 10.1.93 fullcore backend currently shipped by the root HAP. The optional
HarmonyOS N-API module and device package have not been SDK/device verified.

Build exactly one shared runtime per process. Pin this repository commit and
consume the `runtime/` CMake target; do not copy the old monolithic N-API file.
Core load/run is one-shot, consumes the process even on init failure, and never
unloads or resets QEMU. Stop/pause, QMP readiness, VNC, input and guest boot
acceptance are not implemented here. The core can still terminate the process
on native fatal errors; this module does not claim crash isolation.

A DSO that opens but fails the marker/entry check stays pinned in `REJECTED`.
Every later load/run returns `AETHER_ABI_MISMATCH`; recovery requires a new host
process. A failed `dlopen` leaves `UNLOADED` and can be retried. The accepted
marker remains the public TCI contract; the newer MTTCG marker is deliberately
rejected until that backend receives a separate adapter and core review.

Host-only synthetic-core contract tests:

The nine tests include constructor/destructor observation without an extra DSO
reference, rejected-core retry/run blocking, and consumed state after a synthetic
exception. They do not load real QEMU or establish device shutdown/reentry safety.

```sh
cmake -S runtime -B /tmp/aether-runtime -DAETHER_RUNTIME_TESTS=ON
cmake --build /tmp/aether-runtime --parallel 2
ctest --test-dir /tmp/aether-runtime --output-on-failure
```

The independent `SDK20 N-API compile and link` CI job builds this optional module
with a real HarmonyOS API20 native SDK. Obtain the SDK from the official
[Huawei Download Center](https://developer.huawei.com/consumer/en/download/)
after reviewing and accepting its applicable terms outside this script. The
gate does not acquire a license or accept terms on your behalf. Locally, use
the extracted `native` directory and a new output directory:

```sh
python3 runtime/tools/check_sdk20.py \
  --native-sdk /path/to/sdk/default/openharmony/native \
  --output-dir /tmp/aether-sdk20-check
```

The gate explicitly enables `AETHER_RUNTIME_NAPI`, disables host tests, builds
both shared libraries and checks SDK metadata, the actual compiler, SDK
`ace_napi.z` linkage, AArch64 ELF output and required exports. Logs and
`result.json` are written to the output directory. Missing SDK inputs, an
unbuilt module or failed checks produce a nonzero exit; only a successful
compile/link and artifact inspection produce `status: passed`.

For CI, an administrator must manually configure repository variables
`AETHER_SDK20_URL` and `AETHER_SDK20_SHA256` for an authorized, reviewed official
SDK ZIP and its independently verified SHA-256. The HTTPS archive must contain
exactly one API20 `native` package with `oh-uni-package.json` and
`build/cmake/ohos.toolchain.cmake`. No API18 fallback is allowed. CI verifies
the hash before extraction and fails if variables or the native SDK are
missing; it does not create credentials, change permissions or upload SDKs or
binaries. The job runs on relevant pushes, PRs and manual dispatch, separately
from the existing fullcore/API18 build and publication workflows.

Use Python 3.9+, CMake 3.16+ and Ninja on a host supported by the SDK. The native
metadata (`apiVersion=20`) establishes the API level; `OHOS_PLATFORM_LEVEL=20`
alone does not. Native metadata does not authenticate the vendor distribution:
the provisioned HarmonyOS SDK or reviewed archive/hash remains a required
trusted input. Standalone OpenHarmony packages are not an automatic substitute.

Checker regression tests can run without an SDK:

```sh
python3 -m unittest discover -s runtime/tests -p 'test_sdk20_gate.py' -v
```

These fixtures validate checker logic only; they do not establish SDK
compilation. A successful SDK20 gate establishes compile/link and ELF checks
for that exact source and SDK. Phone Core integration, device execution and
repeated startup remain separate, unverified acceptance steps. The existing
`reentrant=0`, consumed and rejected-state protections are unchanged.

Wire `libaether_runtime_napi.so`, the shared runtime and
its build-matched Phone Core/dependencies into the host HAP. `arkts/index.d.ts`
defines the promise result; promise completion means QEMU returned, not that a
guest booted. Never invoke the blocking C function on the ArkUI thread.
