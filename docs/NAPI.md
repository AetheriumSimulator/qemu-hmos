# N-API Integration Notes

This project uses OHOS N-API on device and a minimal host-only shim for local builds/tests.

## Build Modes

- Device (default):
  - Uses official `napi/native_api.h` via `napi_compat.h` when `__OHOS__` is defined.
  - Module registers with `napi_module` and constructor-based `napi_module_register`.
  - CMake sets `USE_FAKE_NAPI=OFF` and enforces host-only usage for the shim.

- Host (optional):
  - Enable `-DUSE_FAKE_NAPI=ON` to include `napi_impl.cpp` which provides a minimal N-API stub.
  - Useful for building on macOS without OHOS runtime. Not functional for real N-API calls; only compiles and links.

## Important Files

- `entry/src/main/cpp/napi_compat.h`: Selects OHOS headers on device, shim on host.
- `entry/src/main/cpp/napi_init.cpp`: Exposes N-API methods, registers module `qemu_hmos`.
- `entry/src/main/cpp/napi_simple.h` and `napi_impl.cpp`: Lightweight types and stubs for host builds only.
- `entry/src/main/cpp/CMakeLists.txt`: Controls `USE_FAKE_NAPI` and links system N-API when available.

## Common Pitfalls

- ABI mismatch/SIGBUS on device: Ensure `USE_FAKE_NAPI=OFF` for device builds. The CMake now enforces this.
- Header collisions: `NAPI_AUTO_LENGTH` is only defined if missing to avoid redefinition against OHOS headers.
- Linking: `libace_napi.z.so` is linked if found in the SDK; otherwise symbols resolve at load-time on device.

## Verify on Device

1) Build and install:
   - `hvigor clean && hvigor assembleDebug`
   - `hdc install -r ./entry/build/outputs/hap/*.hap`
2) Launch via DevEco or app icon.
3) Watch logs:
   - Continuous capture: `hdc shell hilog > issue34-hilog.txt`
   - Snapshot only: `hdc shell hilog -x | grep QEMU_TEST`
4) Exercise N-API from `Index.ets` (e.g., `enableJit`, `kvmSupported`, `startVm`).

`startVm` returns `false` for a short startup failure; call `getLastError()` to
read the stable numeric code, stage, and message. `CORE_LIB_MISSING` is code `1`.

If you see crashes around N-API symbol resolution, confirm the build is a device build (`USE_FAKE_NAPI=OFF`) and that the module name `qemu_hmos` matches ArkTS import.

