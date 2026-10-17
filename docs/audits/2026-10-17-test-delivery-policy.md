# Test-delivery policy change (2026-10-17)

Scope: Aetherium's root HAP only. Commercial Aether and phone-core/API20 are not
part of this decision. This is an explicit project policy change requested for
per-main-push test downloads, not a completed legal review or a platform waiver.

## Observed baseline

PR #41 merged as `ad4f03921179cf09c12caac82923cd01d3591604`.
[Main run 39022873861](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39022873861)
passed native, UEFI, unsigned HAP, source collection and extracted-input replay.
The post-build verifier reported exactly:

- Distribution review missing or stale for this exact source/SDK scope.
- Need component license, source completeness and SDK runtime reviews.

It returned `allowed=false`; upload/Release skipped, artifact count zero. These
were project-authored human-review requirements. No artifact identity or archive
validation error was reported. The legacy workflow's hardcoded false output is
separate and remains unchanged.

## Proposed change and limits

The explicit `test-disclosure-v1` policy permits incomplete human review only
with the exact public unresolved-issue disclosures. Default `strict-review`
verification still requires the existing hash-bound records. No approval files
are fabricated. Build and Release verification select the same test policy.

Safety/integrity controls remain mandatory: source prerequisites, hashes and
member manifests, scope identity, expected commit, required source/firmware/HAP
members, archive safety, SDK/runtime notice provenance, main-push event guards,
read-only builds and isolated Release permission, exact artifact ID, draft-first
publication and no replacement of existing assets. Permissions do not expand.

The collector now delivers four original SDK text records with checked hashes:
CLI LICENSE.txt, OpenHarmony native NOTICE.txt, LLVM NOTICE and native package
metadata. It verifies the original ZIP and runtime member, then the verifier
checks the actual HAP libc++ identity against that provenance. The notices are
inside the companion source archive and indexed, not inserted into the HAP.
No native feature or firmware build target changes.

## Still unresolved and disclosed to downloaders

- The selected native graph includes GPLv2-only VFIO code and static Apache-2.0
  OpenSSL. Applicable combined terms/exceptions remain unresolved. No definitive
  infringement or compatibility conclusion, nor a specific established lack of
  permission for a particular delivered file, is asserted by this audit.
- OpenHarmony native 5.1.0.125/API18 supplies the packaged libc++ runtime. The
  original bundled notices are delivered, but downstream source/patch/build
  mapping remains unresolved. The Exhibit C URL returned HTTP 403 during the
  previous audit. No access restriction is bypassed or new terms accepted.
- The current source candidate, omissions and recipes are delivered. Targeted
  archive-input replay has passed; complete clean archive-to-HAP reconstruction
  and a full corresponding-source assessment remain outstanding. Notice delivery
  and machine hash checks do not resolve those questions.
- No signing, device installation, guest boot or runtime acceptance is claimed.

The practical consequence, if this change is merged, is public unsigned HAP and
source/evidence upload plus test prerelease on successful eligible main pushes,
with the above unresolved matters. A PR run can validate `allowed=true` while
upload and Release remain skipped by event guards. This change must be reviewed
before merging; its implementation does not itself publish a new binary.
