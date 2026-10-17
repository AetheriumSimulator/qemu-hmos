# Open-source distribution status

This review concerns **Aetherium's root application and the components it actually
packages**. Commercial Aether code, licenses and release status are outside its
scope. Supplementary phone-port exports do not certify the root application;
phone-core/API 20 migration is separate work. This is an engineering evidence
assessment, not a determination of legal compliance or infringement. GPL software
can be used commercially; repository visibility alone does not establish complete
corresponding source for a particular binary.

## Verified public distribution history

On 2026-10-17, remote `main` was
`54a18f7738b37766ece848d1ed62dec26bca4aa5` (PR #40, after #39).
[Run 38504885879](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/38504885879)
reported successful source review, native build, UEFI build, unsigned HAP assembly,
payload validation and upload, with the Release job **skipped**. The review returned
`allowed=false` despite that upload.

The run's [artifact metadata](https://api.github.com/repos/AetheriumSimulator/qemu-hmos/actions/artifacts/11867583991)
identified `aetherium-hap-validation-54a18f7738b37766ece848d1ed62dec26bca4aa5`,
13,422,128 archive bytes, not expired at inspection, created at
2026-10-14 03:22:08 UTC and expiring at **2026-10-21 03:22:07 UTC**.
Its archive digest was
`sha256:506c8e89b55720033975402a10b5707802cb4dea6ab5d864c3e81a7d8d259a2b`.
This is the artifact archive digest, not the inner HAP digest. The review
environment's artifact download received storage HTTP 403, so these observations
are API/job evidence, not an independent inspection of the archived bytes.

There is also a historical [prebuilt-libs prerelease](https://github.com/AetheriumSimulator/qemu-hmos/releases/tag/prebuilt-libs),
published 2025-09-04, containing `libqemu_full.so`. “No Release created by this
pipeline” does not mean no historical releases exist. This change neither deletes
existing artifacts/releases nor changes their retention or repository visibility.

PR #39's runner-local-only description ceased to describe reality after #40.
An unsigned seven-day artifact is still a public distribution surface. GitHub's
[web download procedure](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)
requires login and repository read access; that does not restrict a public
repository's artifacts to maintainers. Public metadata and authenticated archive
downloads are distinct. Retention is not access control, and workflow
[`permissions`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)
controls `GITHUB_TOKEN`, not artifact audience.

## Actual root build and remaining evidence gaps

| Input or stage | Evidence and limits |
| --- | --- |
| QEMU | `third_party/qemu` pins `9c23f2a7b0b45277693a14074b1aaa827eecdb92` (10.1.93). CI's `validate-so/action.yml` configures it directly, enables curl/slirp/VNC/pixman and relinks the Meson object graph as `libqemu_full.so`. It does **not** invoke the inventoried `build_qemu_full_linux.sh` patch recipe. A recorded recipe is not proof it built this HAP. |
| GLib, PCRE2, Pixman | `tools/build_ohos_deps.sh` builds static vendored sources; GLib may obtain Meson wraps and the recipe creates missing test scaffolding. The inventory retains source-tree hashes and notices but leaves upstream identities incomplete. PCRE2's COPYING refers to LICENCE, while the full tracked text is LICENCE.md; that text is now hash-recorded rather than treated as missing. |
| OpenSSL and curl | CI invokes both build recipes. Curl is pinned to `01346829096c61b372692f6dc43ffa778c6caccd` and built statically with OpenSSL. Curl is absent from the initial component inventory; QEMU fallback dependencies and SDK-provided link inputs also need an actual link/payload inventory. |
| Native wrapper / LibVNC | CMake builds `libqemu_hmos.so`, compiles cJSON, and loads QEMU in-process. LibVNC archives are linked with `--whole-archive` **if present**. This CI does not call `tools/build_libvnc_ohos.sh`; do not infer that its HAP contains those archives merely from the optional CMake branch or separate phone-port evidence. The root LibVNC recipe itself clones an unpinned default branch. |
| Firmware | CI builds ArmVirtQemu and OVMF from QEMU's recursive EDK2 checkout, then copies the generated `.fd` files into HAP raw resources. This is stronger evidence than an arbitrary firmware download, but there is no artifact-matched firmware source/license/build manifest. `validate_hap.py` checks the module, bytecode and two native libraries; it does not verify firmware contents or correspondence. |
| Toolchain and packaging | The native SDK downloader has version fallbacks without digest verification; HAP tooling uses the 5.1.0.840 bundle/API 18. Host tooling, wraps, SDK runtime inputs and package dependencies need to be recorded according to what actually enters or is required to build the artifact. SDK origin alone is not an exemption. |

`compliance/source-inventory.json` is deliberately an **initial** inventory, not
a complete SBOM or version-bound source archive. The published source and license
notices are useful evidence; they do not yet cover every actual packaged object
and required build input. No complete archive matched to this Aetherium HAP was
established. The separate QEMU 11.1 and LibVNC exports are not substituted for it.

Review applicable terms per actual component and integration. The root Apache
text does not replace third-party notices, and optional integration must be
distinguished from actual inclusion. Independent aggregation should not simply
be assumed to be a single GPL work. Under
[GPLv2 section 3](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html#section3),
corresponding source includes applicable modules, interfaces and build/install
scripts; equivalent source access can accompany binary access without forcing
recipients to download both. A
[byte-identical rebuild](https://www.gnu.org/licenses/gpl-faq.en.html#MustSourceBuildToMatchExactHashOfBinary)
is not the required standard. Artifact hashes aid identity and traceability;
they are not a legal test of source completeness.

## Current pipeline policy

The subsequent delivery implementation is described in [HAP delivery and evidence
review](RELEASE_DELIVERY.md). It preserves a single native → UEFI → unsigned HAP
build, collects a source candidate with a payload/member manifest, and evaluates
an actual post-build distribution verifier. Source-only checks do not authorize
publication. The legacy reusable gate still holds unrelated binary jobs.

| Stage | Policy / meaning |
| --- | --- |
| Source checks | Indexed source hygiene, recorded identities and supplementary source replay. Success is not distribution approval. |
| Native, UEFI, HAP | PRs, main pushes and non-tag manual runs build once on an ephemeral hosted runner. Tags are review-only. |
| Source/evidence | Collect actual working-tree sources, resolved Git wraps, firmware sources, license file index, source omissions, SDK hashes and HAP member identities. Missing reviews yield `allowed=false`; collection errors fail validation. |
| Public Artifact | Only a main push with successful build and `allowed=true` uploads the HAP plus source archive and evidence. Seven-day retention; no separate SO/UEFI binary delivery. PRs/manual runs do not publish. |
| Test prerelease | Main-only job reverifies downloaded evidence before creating an unsigned test prerelease. Write permission is confined to this job. Signing is not a GPL prerequisite. |
| Device / guest boot | Not executed. Build, payload checks, source replay, artifact or Release success cannot replace device acceptance. |

No hash-bound component-license, source-completeness or SDK-runtime review is
present yet. The new gate can pass complete reviewed evidence (tested with
fixtures), but the repository's real delivery remains blocked until those
specific gaps are resolved. Its candidate archive is not presented as certified
complete corresponding source. Existing public artifacts/releases remain
untouched. A scope change invalidates the review; there is no manual override.

`check_source_inventory.py --require-binary-release` rejects source-only approval
and directs callers to the built-delivery verifier. Changing an inventory status
flag cannot approve a delivery. Current CI outcomes must be read from the PR's
latest head, not the historical successful run above.

## Verification

```sh
python -m pip install 'PyYAML==6.0.2'
python -m unittest discover -s tools -p 'test_workflow_guards.py' -v
python -m unittest discover -s tools -p 'test_release_evidence.py' -v
python -m unittest discover -s tools -p 'test_public_source.py' -v
python -m unittest discover -s tools -p 'test_source_inventory.py' -v
python -m unittest discover -s tools -p 'test_port_sources.py' -v
python tools/check_public_source.py
python tools/check_source_inventory.py
python tools/verify_port_sources.py
```

Workflow regressions evaluate the actual YAML conditions across PR, fork-style
PR refs, main/other pushes, tags, manual and reusable calls, gate decisions and
failed/cancelled/skipped reviews/builds. Summary tests execute the shell with
success, failure, cancellation, skip and missing outputs. Source evidence checks
read the Git index: reviewed dependency/recipe/license edits must update their
recorded hashes, calculated over Git blob bytes, not platform line endings.
