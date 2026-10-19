# libffi source recovery evidence

The fullcore build previously used the moving `meson` branch from the official
`https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi.git` wrap. PR #44 CI
received repeated HTTP 504 from Git smart HTTP before compiling QEMU. No permission
or access-denial workaround is used.

The previously published Aetherium source delivery at
[test-266a6c530b81bdf9f15dd473830137185a29630b](https://github.com/AetheriumSimulator/qemu-hmos/releases/tag/test-266a6c530b81bdf9f15dd473830137185a29630b)
records revision `83d0cfd00d7d37af4b4349511d29f1f0512621b3` and contains 391 libffi
files with no libffi omissions. Its source archive SHA-256 is
`e6dbb7d12090a3db3577d5ed71030bbfc8d7855d0e29cf5eed5b846c420f5d2e`;
its evidence JSON SHA-256 is
`d1e6850505b07b3d00a63fee1c89c19e627b88f477b94a81682dfafd931e56e9`.
Both were downloaded and checked again on 2026-10-19.

The official fixed-commit archive became available at
[libffi-83d0cfd.tar.gz](https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/83d0cfd00d7d37af4b4349511d29f1f0512621b3/libffi-83d0cfd00d7d37af4b4349511d29f1f0512621b3.tar.gz),
SHA-256 `ab95eb62c77a0c7613458ed14972d9ba8448bb99de5e7901db7c98a49940c9fc`.
All 391 relative file names, contents and executable bits match the pre-existing
published cache. Both reconstruct Git tree
`c2e25557c3625c975bba5c7602877e17d3ca57c0`. This is a source-content/tree identity
check, not a signature or license approval. Original LICENSE and all source files
are retained.

`tools/libffi_source.py` locks both archive hashes and the complete tree. It uses
the official fixed-commit archive first; only transient HTTP/network failure can
trigger the SHA-locked published source cache. HTTP 401/403, archive hash mismatch,
unsafe archive entries and source-tree drift fail closed. The examined third-party
GitHub mirror lacked the recorded commit and is not used.

The source archive snapshot has no invented Git history. Its transport, original
revision and tree are recorded in `libffi-source-evidence.json`; the source collector
verifies and includes the entire tree and notices, and extracted-source replay
checks that tree again without downloading. Existing source-completeness and
license-review disclosures remain unchanged.
