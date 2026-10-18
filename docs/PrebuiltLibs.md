# Prebuilt QEMU Core Library

> Historical integration notes, not the current delivery recipe (checked
> 2026-10-18, Asia/Shanghai). Use the [verified HAP/source/evidence assets](OPEN_SOURCE_STATUS.md)
> and [current CI recipes](CLOUD_BUILD_README.md). The old `prebuilt-libs` release
> is not the dependency bundle for that HAP. The root `StartVm` path now resolves
> `qemu_init` / `qemu_main_loop` (and optional cleanup) through
> `EnsureQemuCoreLoaded`; a missing core fails startup. The historical `qemu_main`
> / “running stub loop” wording below is not a current successful-runtime claim.

This app’s N-API module (`libqemu_hmos.so`) dynamically loads a separate QEMU core library at runtime and calls its `qemu_main`:

- Core library: `libqemu_full.so`
- Load mechanism: `dlopen("libqemu_full.so", RTLD_NOW)` + `dlsym("qemu_main")`

## Placement

Place the prebuilt `libqemu_full.so` for `arm64-v8a` so it is packed into the HAP:

- Preferred: `entry/src/main/libs/arm64-v8a/libqemu_full.so`
- Also supported: `entry/src/main/cpp/libs/arm64-v8a/libqemu_full.so`

Hvigor will package native libs from `src/main/libs/<abi>/` automatically. Using `cpp/libs` also works in some setups, but `src/main/libs` is the most compatible location.

## Verify at Runtime

- On start VM, the app will log whether the core library is loaded:
  - Success: `[QEMU] Core library loaded, entering qemu_main...`
  - Failure: `[QEMU] dlopen libqemu_full.so failed: <reason>`
  - Fallback: `[QEMU] Core library missing, running stub loop`

For an Issue #34 reproduction, start continuous capture before launching the VM:

```sh
hdc shell hilog > issue34-hilog.txt
```

Use `hdc shell hilog -x | grep QEMU` only for a one-time snapshot. Do not add
`-r` to the default capture command; it changes the hilog output mode and can
hide the startup window being diagnosed.

## Notes

- Keep large prebuilts out of Git; distribute via Releases or internal storage.
- Record the SHA256 and version of the core library alongside download instructions.
