# Native VNC: source implementation and packaged availability

Checked 2026-10-18 (Asia/Shanghai), against main `220702399b91f90dbfaa39335914b8159fe87c84` and [run 39027202185](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39027202185).

## Code that exists

[napi_init.cpp](../entry/src/main/cpp/napi_init.cpp) contains `VncSession`, asynchronous connection/lifecycle handling, framebuffer allocation/update callbacks, render workers, pointer and keyboard dispatch. The ArkTS [client wrapper](../entry/src/main/ets/managers/VNCNativeClient.ets) and [viewer page](../entry/src/main/ets/pages/VNCNativeViewer.ets) exist. It is no longer accurate to say all frame decoding/event-loop work is unwritten.

## Current public HAP limitation

[CMake](../entry/src/main/cpp/CMakeLists.txt) enables `LIBVNC_HAVE_CLIENT` only when the optional client archive is present. The verified build logged:

```text
VNC Client: Disabled (missing libvncclient.a)
VNC Server: Disabled (missing libvncserver.a)
```

These are wrapper-side optional libraries. The separate QEMU core **does** build with `--enable-vnc`; that does not provide the app's native client. Without `LIBVNC_HAVE_CLIENT`, `VncConnect`, `VncSendPointer` and `VncSendKey` return false. The current test HAP must not be advertised as having a working integrated VNC display/input path.

The recipe does not call `tools/build_libvnc_ohos.sh`. The [supplementary LibVNC export](../ports/libvnc/README.md) supplies source/provenance material, not proof that those objects were linked into this HAP. Do not solve the omission by inserting an arbitrary untraceable archive.

## Remaining integration and validation

Build the required client from identified sources with matching dependencies and notices, connect that recipe to the root HAP, then verify actual payload/link evidence. On a device, verify availability, connection failure handling, frame updates, surface lifecycle, keyboard/pointer/touch input and reconnect/VM teardown with the exact signed package and guest.

No such device acceptance is established by the current hosted build. Historical noVNC/WebView notes describe older paths and are not current validation evidence. RDP and RemoteApp are explicitly **not planned**; they are not a fallback integration roadmap for Aetherium.
