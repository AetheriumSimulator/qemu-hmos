# Open-source distribution status

This is a source-maintenance update, not a binary release or a declaration that
GPL components have been isolated from every downstream application.

## Completed in this update

- Removed 474 generated, precompiled or local-only files from the Git source tree.
  Maintained sources and upstream license notices are retained. Existing public
  history is not rewritten.
- Removed saved machine-local signing configuration from the public build profile.
- Added checks against the actual Git index, including staged credentials,
  compiled binaries with misleading filenames, cache directories and native module
  source availability.
- Recorded QEMU's pinned revision, local patch/recipe hashes, and seven other
  component snapshots with license evidence. Unknown upstream revisions remain
  explicitly unknown; a local Git tree hash is not upstream provenance.
- Held binary-producing workflows and removed automatic GitHub Release creation.
  Source checks can pass while binary publication remains blocked.

## Unresolved distribution boundaries

The native build statically links LibVNCClient/LibVNCServer into the N-API library
when available, using `--whole-archive`. Their GPL notices are retained in the
headers and the root GPL text. QEMU is loaded in the application's process in
this version. These are linking/integration relationships, not merely folders
containing unrelated files.

The root Apache-2.0 text for original code does not override third-party licenses
or automatically authorize every combined distribution. QEMU patches inherit the
requirements of the upstream code they modify. No contributor's code is relicensed
by this update. The applicable licenses for the combined application, including
GPL version compatibility, still require review before binary distribution.

[QEMU license information](https://www.qemu.org/docs/master/about/license.html)
and the [GPL version 2 text](../LICENSE) describe the relevant upstream terms.

## Corresponding source is still incomplete

`compliance/source-inventory.json` records QEMU
`9c23f2a7b0b45277693a14074b1aaa827eecdb92` (VERSION 10.1.93) and the existing patch
queue. The separate [QEMU 11.1 port source](../ports/qemu-11.1/README.md) now
publishes the downstream base patch and phone development overlay, with exact
tree reconstruction from a public upstream commit. It does not replace the
root application's older QEMU submodule. The export includes reviewed source
and two portability fixes to the phone recipe; it is not a complete source
archive matched to an already distributed Aether HAP.

The separate [LibVNC evidence](../ports/libvnc/README.md) includes the pinned
upstream revision/tree, full license, retained lock and current build recipe.
The current recipe hash differs from the retained lock. That discrepancy is
explicit; the old archive hashes cannot certify this recipe's output.

Several vendored trees, the LibVNC build recipe, firmware and other downloaded
dependencies still lack complete version/patch/rebuild provenance. The initial
inventory is not a complete software bill of materials. Source snapshot hashes
detect changes; they do not establish the provenance of pre-existing snapshots.

Before distributing binaries, complete the applicable license review, exact
dependency and patch inventory, version-bound corresponding-source archive,
rebuild instructions and clean-build verification. The archive must cover the
actual distributed objects and their required build/interface material. Simply
pointing to upstream master is insufficient.

## Automated checks and publication hold

```sh
python -m unittest discover -s tools -p 'test_public_source.py' -v
python -m unittest discover -s tools -p 'test_source_inventory.py' -v
python tools/check_public_source.py
python tools/check_source_inventory.py
python -m unittest discover -s tools -p 'test_port_sources.py' -v
python tools/verify_port_sources.py
```

These commands validate source hygiene and recorded identities. No full HAP,
device or clean native rebuild was performed for this maintenance update.
The source workflow additionally obtains the immutable upstream QEMU and
LibVNC commits and replays the QEMU port into a disposable Git index. An exact
source-tree match is source evidence, not binary or device acceptance.

`python tools/check_source_inventory.py --require-binary-release` deliberately
fails with the remaining blockers. Changing a manifest flag to `ready` cannot
approve a release: the actual release-evidence verifier has not been implemented.
The reusable workflow returns `allowed=false`, so binary jobs are skipped before
using a self-hosted runner or downloading SDKs. Removing that hold requires a
reviewed implementation of the release verification, not a cosmetic flag change.

Updating an indexed dependency, patch, recipe or license also requires refreshing
its evidence in the inventory after review. SHA-256 values are calculated over
Git blob bytes (LF), not platform-dependent working-tree line endings.

## Runner-local build validation

The complete workflow now separates source/publication review from build
validation. PRs (including forks), main pushes and non-tag manual runs perform
SDK → dependencies/QEMU/NAPI → UEFI → unsigned API 18 HAP assembly and payload
validation sequentially on one ephemeral GitHub-hosted runner. The three legacy
build workflow entry points call this same pipeline. Tags only run review.

SO, firmware and HAP bytes stay in the runner workspace; there are no validation
artifact uploads/downloads, caches, inherited secrets, signing or Release steps.
Public Actions artifacts are a distribution surface even when called validation
or unsigned. Renaming an artifact or reducing retention does not make it private.
The source-only review returns `allowed=false`; its success does not certify a
binary release. The earlier statement that all binary-producing jobs are skipped
is superseded only for runner-local validation, not for publication.

Each build summary records the checkout/event SHA, individual stage outcomes and,
only after successful assembly and payload validation, the unsigned HAP size and
SHA-256. A skipped or failed build is not HAP evidence. Hosted runners have no
connected device: deploy and device smoke are explicitly not executed. This
refactor does not supply clean native/HAP build evidence until its actual CI run
succeeds, and does not supply any device acceptance evidence.

Formal distributable HAP signing and GitHub Release remain unavailable pending
combined-distribution license review, version-matched corresponding source and
rebuild evidence, exact dependency provenance and complete firmware evidence.
No flag or manual input enables publication. Phone-core/API 20 is separate work.

Workflow topology and publication regressions can be checked with:

```sh
python -m pip install 'PyYAML==6.0.2'
python -m unittest discover -s tools -p 'test_workflow_guards.py' -v
```
