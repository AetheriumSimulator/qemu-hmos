# Open-source distribution status

This review concerns **Aetherium's root application and the components it actually
packages**. Commercial Aether code, licenses and release status are outside its
scope. Supplementary phone-port exports do not certify the root application;
phone-core/API 20 migration is separate work. This is an engineering evidence
assessment, not a determination of legal compliance or infringement. GPL software
can be used commercially; repository visibility alone does not establish complete
corresponding source for a particular binary.

## Current verified delivery (checked 2026-10-18, Asia/Shanghai)

Main is `220702399b91f90dbfaa39335914b8159fe87c84` (merged PR #42).
[Run 39027202185](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39027202185)
succeeded: native SO, ArmVirt/OVMF, unsigned HAP/payload checks, source/notice
collection, extracted-input replay, upload and independent Release reverification.
Both post-build and Release verifiers reported `allowed=true` under
`test-disclosure-v1`, while explicitly retaining **human reviews not approved**.

The [public test prerelease](https://github.com/AetheriumSimulator/qemu-hmos/releases/tag/test-220702399b91f90dbfaa39335914b8159fe87c84)
is not a draft and contains exactly these delivery assets:

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| aetherium-unsigned.hap | 55998657 | `0f16e219c3c007e80a607de3060ad5c11cc442af17b184f8c2bcbde733ff7405` |
| aetherium-source.tar.gz | 294827677 | `24d3b5a67362e27e62c819c479b1d5adb9e64faf6aff17510390127a9326cda8` |
| release-evidence.json | 25987442 | `b29431a65ebea837ce26c24b1971d2c72dbc5225d0acc080a1492ae8a8dea79a` |

All three browser URLs were downloaded without authentication and hash-verified
on 2026-10-17; release metadata was rechecked on 2026-10-18. The downloaded bundle
also passed the full verifier, including four original SDK notice/metadata files.
The candidate has 102,054 source members, 45 source records and 137 exclusions.
Use the named `aetherium-source.tar.gz`, not GitHub's automatic source ZIP/tarball.
This is build-matched candidate source, not certification of source completeness.

Actions Artifact `12099471932` uploaded and was downloaded by the Release job;
its seven-day retention ends 2026-10-24 11:20:38 UTC. An independent local download
from Actions' Azure storage returned HTTP 403; the public Release downloads above
succeeded. No signing, device installation, guest boot or runtime acceptance was
performed. Current root API 18/fullcore and separate QEMU 11.1 phone-core/API 20
goals must not be conflated; see the [implementation matrix](../README.MD).
RDP and RemoteApp are explicitly not planned, not pending validation targets.

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

The [2026-10-17 engineering audit](audits/2026-10-17-hap-evidence.md) adds
build-matched source/SDK identities, component notices, exact packaged C++ runtime
provenance, a fixed-tree offline curl reconstruction repair, and targeted
archive-input repairs for text files, BTI note reconstruction and prebuilt ROMs. It is automated
engineering evidence, not legal or rights-holder approval. The initial inventory
below is not a replacement for that build-specific evidence.

| Input or stage | Evidence and limits |
| --- | --- |
| QEMU | `third_party/qemu` pins `9c23f2a7b0b45277693a14074b1aaa827eecdb92` (10.1.93). CI's `validate-so/action.yml` configures it directly, enables curl/slirp/VNC/pixman and relinks the Meson object graph as `libqemu_full.so`. It does **not** invoke the inventoried `build_qemu_full_linux.sh` patch recipe. A recorded recipe is not proof it built this HAP. |
| GLib, PCRE2, Pixman | `tools/build_ohos_deps.sh` builds static vendored sources; GLib may obtain Meson wraps and the recipe creates missing test scaffolding. The inventory retains source-tree hashes and notices but leaves upstream identities incomplete. PCRE2's COPYING refers to LICENCE, while the full tracked text is LICENCE.md; that text is now hash-recorded rather than treated as missing. |
| OpenSSL and curl | CI invokes both build recipes. Curl is pinned to `01346829096c61b372692f6dc43ffa778c6caccd` and built statically with OpenSSL. Curl is absent from the initial component inventory; QEMU fallback dependencies and SDK-provided link inputs also need an actual link/payload inventory. |
| Native wrapper / LibVNC | CMake builds `libqemu_hmos.so`, compiles cJSON, and loads QEMU in-process. LibVNC archives are linked with `--whole-archive` **if present**. This CI does not call `tools/build_libvnc_ohos.sh`; do not infer that its HAP contains those archives merely from the optional CMake branch or separate phone-port evidence. The root LibVNC recipe itself clones an unpinned default branch. |
| Firmware | CI builds ArmVirtQemu and OVMF from QEMU's recursive EDK2 checkout, then copies the generated `.fd` files into HAP raw resources. The delivery collector now records firmware payload hashes, EDK2 revisions, source members and build recipes. Its structural verifier requires both firmware members; neither it nor `validate_hap.py` proves functional boot or complete license/source correspondence. |
| Toolchain and packaging | The native SDK downloader has version fallbacks without digest verification; HAP tooling uses the 5.1.0.840 bundle/API 18. Host tooling, wraps, SDK runtime inputs and package dependencies need to be recorded according to what actually enters or is required to build the artifact. SDK origin alone is not an exemption. |

`compliance/source-inventory.json` is deliberately an **initial** inventory, not
a complete SBOM or version-bound source archive. The published source and license
notices are useful evidence; they do not yet cover every actual packaged object
and required build input. A candidate archive is now matched to the built HAP,
but its completeness is not established. The separate QEMU 11.1 and LibVNC
exports are not substituted for it.

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
| Source/evidence | Collect actual working-tree sources, resolved Git wraps, firmware sources, license file index, source omissions, SDK hashes and HAP member identities. Test policy publicly records missing human reviews; integrity/disclosure failures yield `allowed=false`, and collection errors fail validation. Includes exact SDK runtime notices and provenance. |
| Archive input replay | Extract the collected inputs, regenerate the BTI note, and exercise actual pc-bios Meson behavior without prebuilt ROMs. Targeted replay is not a complete HAP rebuild. |
| Public Artifact | Only a main push with successful build and `allowed=true` uploads the HAP plus source archive and evidence. Seven-day retention; no separate SO/UEFI binary delivery. PRs/manual runs do not publish. |
| Test prerelease | Main-only job reverifies downloaded evidence before creating an unsigned test prerelease. Write permission is confined to this job. Signing is not a GPL prerequisite. |
| Device / guest boot | Not executed. Build, payload checks, source replay, artifact or Release success cannot replace device acceptance. |

No hash-bound component-license, source-completeness or SDK-runtime approval is
present. CI now explicitly selects the project's `test-disclosure-v1` policy:
missing human reviews are public unresolved items rather than publication
blockers. The actual GPLv2-only VFIO/static OpenSSL combination, SDK downstream
runtime source mapping/inaccessible Exhibit C terms, and complete clean
archive-to-HAP rebuild remain unresolved. This is not a legal compatibility or
infringement determination. The source candidate is not certified complete
corresponding source. Original SDK runtime notices/metadata now accompany it.

Hash/manifest/source identity, notice provenance, required inputs and main-only
publication controls remain mandatory. The default verifier's `strict-review`
mode remains available. Existing public artifacts/releases are untouched. The verified main run above has already published unsigned test assets;
future eligible main pushes use the same policy; a passing PR run itself does not upload or release anything.

`check_source_inventory.py --require-binary-release` rejects source-only approval
and directs callers to the built-delivery verifier. Changing an inventory status
flag cannot approve a delivery. For later changes, read the exact head/run and its actual upload/Release outcomes;
the verified delivery above does not certify later packages.

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

### OHAudio build evidence

The fullcore/API18 path now requires the OHAudio patch in both local and CI builds.
Missing/drifted patches fail explicitly. CI selects `aether-soundkit-hmos` and
checks compiled ELF registration, renderer/capturer symbols and the `libohaudio.so`
dependency before HAP packaging. The source candidate includes the added backend
C file, patch, recipe and `ohaudio-build-evidence.json`. This adds a platform audio
dependency; existing SDK terms/source-mapping disclosures remain unresolved.

The backend uses API10 renderer/capturer callback interfaces available in API18,
and accepts s16 little-endian PCM (NAPI: 48 kHz, stereo output, mono input). Builder,
configuration, generation and start failures return initialization failure with
the native result code, rather than reporting successful silent capture.
Compilation/registration is not device acceptance: playback, microphone permission
granted/denied, capture, routing, lifecycle and latency still require device tests.
The publication policy, event boundaries and release disclosures are unchanged.

API interface reference: OpenHarmony `interface_sdk_c` 5.1 release commit
[`7de238a336d4e00c6611b269dfc29c44f3e5f211`](https://github.com/openharmony/interface_sdk_c/blob/7de238a336d4e00c6611b269dfc29c44f3e5f211/multimedia/audio_framework/common/native_audiostreambuilder.h)
declares `SetRendererCallback` and `SetCapturerCallback` since API10. This is an
interface compatibility reference, not an exact source mapping for the installed
platform library. The app declares `MICROPHONE` but its current dynamic permission
request path covers storage only; microphone consent UX remains an explicit gap.
Do not treat capture initialization failure as permission granted or successful
recording, and do not bypass device permission controls during testing.
