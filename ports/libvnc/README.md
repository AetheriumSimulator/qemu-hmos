# Aether LibVNC source/build evidence

The source is pinned to LibVNCServer commit
`42494999e6492aaab9c1db785ecd293ef10b3aed`, tree
`5aa386a8154f82ca6e7028c28ad96a16b182b0ac`. The complete upstream `COPYING` is
retained here. `sources.lock.json` is the retained Aether provenance record;
the older application's vendored headers at the repository root have their
own, still incomplete provenance.

`tools/build_libvnc_ohos.sh` is the retained static-library recipe. Its root
resolves to this `ports/libvnc` directory, so its source/build/output locations
are relative to this kit. Supply an appropriate `OHOS_NDK_HOME` and an explicit
output prefix. The script can fetch the pinned source; the verification tool
does not perform network requests or builds.

**A discrepancy remains:** the retained lock's recipe SHA-256 is
`ef40f443ad425db958cb28090070a1e397b7605e7c737aab8bbd54bcb76f669a`, while the
exported current recipe hashes to
`e49421bc4216e2e9cd72e77f1d9e54467c06f2fbcb1634dc4c34c3dcfcd443eb`.
The manifest records this discrepancy instead of rewriting the old record to
make a check pass. Its archive hashes are historical evidence, not proof that
this recipe reproduces shipped libraries. A fresh rebuild and comparison is
required before closing that gap.

Verify indexed evidence, optionally against an independently obtained source
clone containing the pinned commit:

```sh
python tools/verify_port_sources.py --libvnc-repo /path/to/libvncserver
```

This addresses source availability and traceability. It does **not** remove
LibVNC's GPL requirements: Aether currently links the client/server archives
into its native library. Replacing an archive with a dynamic library alone
does not establish a different license boundary. The phone QEMU integration
also remains a separate combined-application review item.
