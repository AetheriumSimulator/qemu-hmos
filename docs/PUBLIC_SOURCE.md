# Public source tree

This repository contains source code and build recipes. Generated libraries,
firmware, package-manager caches, IDE state and machine-local signing settings
must not be tracked. Existing public history is not rewritten by this cleanup.

## Rebuilding after the cleanup

Initialize the pinned QEMU submodule and install dependencies using the checked-in
package manifests. The native module's maintained source is
`entry/src/main/cpp/types/libqemu_hmos`; `entry/oh_modules/qemu_hmos` was a byte-for-byte
generated copy. The existing `entry/oh-package.json5` and lockfile point to the
maintained source, which remains in Git.

Use the scripts under `tools/` to produce native libraries locally. The removed
firmware and native binaries did not have complete release-bound source evidence;
do not replace them with arbitrary downloads. Their exact source revisions,
patches, licenses and build recipes must be established before distributing new
binaries. A source-hygiene pass is not proof that a complete clean build succeeds.

The committed root build profile is unsigned. Configure signing in your own
development environment when installing on devices. Never stage generated
certificate paths, saved signing passwords, profiles or keys. The new checker
rejects saved signing passwords even when a later working-tree edit has hidden
them: it reads the Git index that would actually be committed.

## Before committing

```sh
python -m unittest discover -s tools -p 'test_public_source.py' -v
python tools/check_public_source.py
git diff --cached --check
```

The check does not read untracked/ignored developer files, print credential
values, or descend into uninitialized submodules. Vendored third-party source
text, including upstream cryptographic test fixtures, still requires its own
provenance and license review. This tool does not certify GPL separation or
complete corresponding source.

No claim is made that removing files from the current tree removes them from
older commits. Review the historical signing configuration before reusing that
signing identity; do not publish local signing material again.
