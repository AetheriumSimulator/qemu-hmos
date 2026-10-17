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

`tools/release_evidence.py verify` always verifies delivery hashes and archive
members, required native/firmware HAP entries and source inputs, source scope and
expected checkout commit. CI explicitly selects `--policy test-disclosure-v1`:
missing human reviews are disclosed, rather than a hard block. This is a project
policy choice, not a platform rule or a legal approval. The default CLI policy
remains `strict-review`, requiring three hash-bound review documents.

The test policy additionally requires the exact public `testDistribution`
disclosure (reviews **not approved**, source completeness **not certified**),
and the audited SDK runtime/notice provenance. Changed/missing disclosures,
SDK/runtime identities or notices block it; no `ready` flag bypasses these checks.
Both policies preserve HAP/source hashes, source origins, event isolation and
Release reverification. The legacy source-only gate still emits `allowed=false`
for unrelated binary jobs; that output does not control this HAP delivery path.

PRs (including forks), manual runs and non-main refs **never upload or release**.
A main push with a successful build and passing test-distribution integrity/disclosure checks uploads
the three files together for seven days. A separate main-only job downloads that
exact artifact ID emitted by the build (also on release-only retries), verifies it again, and creates a test prerelease
`test-<full commit SHA>`. The read-only `build-validation.yml` is reused by the main pipeline and legacy entry points; it contains no write-permission job. Only the main pipeline Release job receives `contents: write`; the token is
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

For the optional strict-review policy, after these are established add reviewed documents under
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
self-reference. Scope changes invalidate strict-policy approvals. The test policy
creates no approval records: every delivery retains the explicit unresolved
items even when its integrity checks pass. Hash checks cannot judge the truth of
legal or source-completeness assertions.

### SDK notice delivery

The collector extracts four original UTF-8 text files from the hash-pinned CLI
SDK ZIP: its LICENSE.txt, OpenHarmony native NOTICE.txt, LLVM NOTICE, and native
package metadata. They accompany the HAP inside the source archive under
`project/compliance/sdk-runtime/command-line-tools/`. `sdkRuntimeEvidence` maps
each original ZIP member to the delivered member and hash, and binds the packaged
libc++ runtime to its exact SDK member. No SDK executable is added to the source
archive. NOTICE files are now included in the license-file index.

This directly repairs the missing bundled-notice delivery. It does not resolve
the SDK runtime's downstream source/patch mapping, inaccessible Exhibit C terms,
or combined-component assessment. A changed SDK/runtime must update provenance
and notices before passing this test policy. No account access or new agreement
acceptance is performed. The Release notes disclose the outstanding issues
before users download the three assets.

Local commands after the complete build:

```sh
python tools/release_evidence.py collect \
  --hap entry/build/default/outputs/default/entry-default-unsigned.hap --out delivery
python tools/release_evidence.py verify --policy test-disclosure-v1 --out delivery \
  --expected-commit "$(git rev-parse HEAD)"
```

Collection refuses to overwrite an existing output directory. CI's `--report-only`
reports failed integrity/disclosure checks as `allowed=false`; it cannot authorize
upload. Collection errors fail validation. Release reverification never uses
`--report-only`. Under the test policy, missing human reviews alone do not block
main-push uploads or prereleases. They remain explicitly unapproved, with the
source candidate's limits and known license/SDK uncertainties publicly disclosed.
PRs never upload or release even if `allowed=true`; test-policy validation on a
PR is not proof of an actual main upload/Release or device run.

### Credential lifecycle

The same-repository build uses read-only `GITHUB_TOKEN` permissions. Only the
prerelease job receives `contents: write`; its `GH_TOKEN` is `${{ github.token }}`,
the automatically issued job token. Checkout uses `persist-credentials: false`.
This pipeline does not require a user-maintained PAT, repeated interactive login,
or changes to account authorization/token expiration settings. An Actions token
or repository policy failure must be reported, not bypassed with a personal token.

The current [automated engineering audit](audits/2026-10-17-hap-evidence.md)
records resolved evidence and remaining review gaps. Its existence does not
satisfy strict-policy approvals; the disclosed-test policy does not claim it does.

### Reconstructing repaired archive inputs

Run `python3 tools/prepare_hap_sources.py` before the native/UEFI recipes when
using extracted sources. It verifies the pinned QEMU pc-bios recipe, applies the
HAP packaging adaptation idempotently, and generates the exact EDK2 BTI note from
readable ELF fields. The native recipe uses `--disable-install-blobs`; HAP firmware
continues to come from the separate ArmVirt/OVMF builds, not QEMU's old compressed
prebuilt ROM set. No VFIO/OpenSSL runtime functionality is disabled by this change.

After collection, CI runs `tools/replay_source_inputs.py` on the actual archive.
The summary reports this targeted source-input replay separately; success is not
a full archive-to-HAP rebuild, distribution approval or real-device validation.
