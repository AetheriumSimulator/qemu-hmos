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

For an OHOS toolchain build, omit host tests and optionally enable
`AETHER_RUNTIME_NAPI`. Wire `libaether_runtime_napi.so`, the shared runtime and
its build-matched Phone Core/dependencies into the host HAP. `arkts/index.d.ts`
defines the promise result; promise completion means QEMU returned, not that a
guest booted. Never invoke the blocking C function on the ArkUI thread.
