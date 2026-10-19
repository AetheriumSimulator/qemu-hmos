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

Host-only synthetic-core contract tests:

```sh
cmake -S runtime -B /tmp/aether-runtime -DAETHER_RUNTIME_TESTS=ON
cmake --build /tmp/aether-runtime --parallel 2
ctest --test-dir /tmp/aether-runtime --output-on-failure
```

For an OHOS toolchain build, omit host tests and optionally enable
`AETHER_RUNTIME_NAPI`. Wire `libaether_runtime_napi.so`, the shared runtime and
its build-matched Phone Core/dependencies into the host HAP. `arkts/index.d.ts`
defines the promise result; promise completion means QEMU returned, not that a
guest booted. Never invoke the blocking C function on the ArkUI thread.
