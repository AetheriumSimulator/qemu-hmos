# HAP delivery and evidence review

The complete workflow builds the native libraries, firmware and unsigned HAP
**once**. It then creates three candidate delivery files on the same runner:

- `aetherium-unsigned.hap`: the only binary delivery asset.
- `aetherium-source.tar.gz`: source snapshots, notices, scripts and selected
  configuration/link evidence; no standalone SO/UEFI payloads.
- `release-evidence.json`: HAP/archive hashes, every HAP entry and source member,
  source repository revisions, vendored snapshot identities, license-file index,
  downloaded SDK URLs/archive hashes and tool versions, ELF dynamic dependencies and explicit omissions.

The collector includes root tracked working-tree sources (including changes made
by build recipes), QEMU and its EDK2 source/submodules, fetched QEMU/GLib Git wraps,
and the pinned curl source. Supplementary `ports/` exports are excluded from this root-HAP source delivery. It preserves the build-created GLib scaffolding,
EDK2 configuration and native link/configuration evidence. Other QEMU ROM
submodules are excluded because this workflow builds EDK2; compiled upstream
fixtures/ROMs are also excluded and listed. The candidate must be reviewed for
whether anything excluded or not discovered is required to rebuild the actual
payload. A source collection is not automatically complete corresponding source.

`nativeDynamicDependencies` comes from `readelf -d` on the actual HAP libraries.
It does not enumerate static linkage. Use the collected Meson dependency/target
metadata and NAPI link command, alongside the recipes, to resolve static inputs.
Downloaded wrap revisions describe what this build used, including moving wrap
branches; they do not prove their upstream provenance was reviewed. License-file
presence is an index, not an automatic license compatibility decision.

## Gate and events

`tools/release_evidence.py verify` verifies the delivery bytes and archive members,
required native and firmware HAP entries, source scope, expected checkout commit,
and three hash-bound review documents. It can return `allowed=true` for complete
reviewed evidence; positive and negative fixtures exercise this behavior. It
never infers approval from `unsigned`, a short retention period or a `ready` flag.
The source-only reusable gate still holds unrelated legacy binary jobs; it is not
the post-build HAP distribution decision.

PRs (including forks), manual runs and non-main refs **never upload or release**.
A main push with a successful build and approved distribution evidence uploads
the three files together for seven days. A separate main-only job downloads that
exact run/attempt's artifact, verifies it again, and creates a test prerelease
`test-<full commit SHA>`. Only that job receives `contents: write`; the token is
passed only to its publication step. The release is created as a draft with all
three files, then made public. An existing tag must match the commit; existing
assets are compared, never overwritten. A rerun whose new bytes differ stops
rather than replacing a previous delivery. A partial draft may require maintainer
inspection; this workflow does not delete or replace its assets.

Unsigned is an explicit product/installability limitation, not a GPL distribution
prohibition. No signing key is required for this test-prerelease path. Installing
on a particular device may require the owner to sign/provision the HAP separately.
No hosted CI result proves device installation, guest boot or runtime acceptance.

## Remaining decisions and evidence

No distribution approval is supplied by this PR. In particular:

1. **Actual combined component terms.** Review the root app, the selected QEMU
   object graph, GLib/PCRE2/Pixman, curl with OpenSSL, cJSON and any actual optional
   LibVNC input. QEMU's LICENSE distinguishes emulator and separate firmware and
   specifies GPLv2 overall; the vendored OpenSSL identifies 3.3.1 and Apache-2.0.
   Resolve the applicable versions/exceptions and actual linkage with evidence;
   do not infer compatibility or infringement from names alone. Identify required
   notices and source/installation materials. This is Aetherium only.
2. **Source closure.** Check collected link graphs, generated configuration,
   EDK2 submodules and omissions against every packaged native/firmware object.
   Supply any absent source, license, interface or build/install material. Include
   exact resolved dependencies and reproducible *instructions*; byte-identical
   rebuilding is not asserted or required as a blanket licensing rule.
3. **SDK/runtime redistribution terms.** Identify the downloaded SDK bundles by
   recorded SHA-256, the runtime objects actually linked/packaged and any applicable
   system-library treatment. Provide the specific public terms or authorization
   covering those inputs and distribution. The user may need to provide terms
   accessible only through their SDK account; this PR does not access or change
   that account. Merely downloading from an official URL is not an approval.

After these are established, add reviewed documents under
`compliance/distribution-review/`, then a `compliance/distribution-review.json`:

```json
{
  "scopeSha256": "<scope SHA-256 emitted by collection for reviewed inputs>",
  "reviews": {
    "component-licenses": {"path": "project/compliance/distribution-review/components.md", "sha256": "<document SHA-256>"},
    "source-completeness": {"path": "project/compliance/distribution-review/source.md", "sha256": "<document SHA-256>"},
    "sdk-runtime-terms": {"path": "project/compliance/distribution-review/sdk.md", "sha256": "<document SHA-256>"}
  }
}
```

The review documents and index are excluded from their own scope digest to avoid
self-reference. Other source/recipe/SDK changes invalidate the scope and require
review again. This conservative first implementation does **not** automatically
carry approval across arbitrary future code or SDK changes; per-push delivery
only proceeds for the reviewed scope. Hashes bind the recorded decision to inputs;
they cannot judge the truth of an authored legal/source review. The repository's
normal review process must assess those documents. No approvals are fabricated
here and no repository protection or credential settings are changed.

Local commands after the complete build:

```sh
python tools/release_evidence.py collect \
  --hap entry/build/default/outputs/default/entry-default-unsigned.hap --out delivery
python tools/release_evidence.py verify --out delivery \
  --expected-commit "$(git rev-parse HEAD)"
```

Collection refuses to overwrite an existing output directory. Missing review
records produce an explicit blocked result; CI's `--report-only` keeps build
validation successful while emitting `allowed=false`. Structural collection
failures still fail the evidence stage. Release reverification never uses
`--report-only`. While blocked, candidate bytes remain runner-local. The review
scope and reasons are printed in CI; reconstruct the candidate locally to review
its full content. This does not claim a downloadable HAP or a successful Release
until the actual main publication steps have run successfully.
