# QEMU 11.1 development port source

This directory supplies actual downstream QEMU code, including the embedded
phone entry, signal-free coroutine backend, main-loop cleanup and RR worker
shutdown changes. It supplements the older QEMU 10.1.93 application at the
repository root; it does not silently upgrade that application's submodule.

The public upstream `v11.1.0` commit is
`84f07211cc5b4fc6a371559bf8a5de4fb068e648`. Apply `base-port.patch` first, then
the files in `overlay/`. The manifest records the upstream tree, the original
downstream tree, every overlay file's SHA-256/mode and the final reconstructed
tree. The private downstream commit does **not** need to be fetchable: the patch
must reproduce its tree from the public upstream commit.

## Verify and reconstruct

From the public repository root, with a local upstream QEMU clone containing
the recorded commit and its objects:

```sh
python tools/verify_port_sources.py --qemu-repo /path/to/upstream-qemu \
  --output /path/to/new-qemu-phone-source.tar
```

The checker uses **indexed** public files and a temporary bare repository. It
checks the base patch's resulting tree before applying the overlay, then
checks the final tree. It never changes the supplied clone's working files,
index or references. `--output` refuses to replace an existing file. This is
a QEMU source tar, not a full Aether corresponding-source archive.

Unpack into a new directory on a Linux filesystem and make a local Git source
commit there before running the retained build scripts: those scripts archive
`HEAD` and record its source identity. Supply `OHOS_SDK_DIR`,
`OHOS_DEPS_PREFIX`, and the necessary cross-build dependencies explicitly.
`build_harmonyos_phone.sh` selects ARM64 TCI and builds `libqemu_phone.so`;
`build_harmonyos_full.sh` selects native TCG or TCI via `QEMU_CORE_FLAVOR`.
Neither a complete dependency bundle nor a clean SDK rebuild is supplied by
this export. Existing old-repository dependency recipes are not proof that the
new core has all its matching build inputs.

Two public recipe corrections are recorded separately in the manifest: require
an explicit SDK path and accept a clean committed tree with an empty local
patch. Other exported overlay files preserve the retained development source
after CRLF-to-LF normalization. The manifest lists excluded local symlink
materialization changes and unrelated RISC-V deletions; the immutable upstream
versions are retained. This is a reviewed development snapshot, **not** an
assertion that an already distributed HAP was built from this exact tree.

## Runtime and license boundaries

`qemu_hmos_phone_exports.c` still advertises **`reentrant=0`** and rejects a
second session. The main-loop tests exercise part of teardown; they do not
prove QEMU A-to-B-to-A lifecycle acceptance. No phone, guest or HAP behavior
was verified by source reconstruction.

Upstream `LICENSE`, `COPYING` and `COPYING.LIB` are retained. Individual files
keep their notices, including GPL and LGPL notices on new embedded sources.
This publication grants no new exception to QEMU's license and does not
relicense Aether's application/UI. A private C ABI, `dlopen`, separate `.so`
or separate source repository is not evidence of an independent program for
combined-distribution license review.
