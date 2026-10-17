# Aetherium HAP engineering audit — 2026-10-17

This is an **automated engineering audit**, not a human/legal review, a
rights-holder permission, or a distribution approval. It concerns the root
Aetherium HAP only. Commercial Aether and supplementary phone exports are not
substitutes for this HAP's sources or licenses. No review approval JSON is
created by this document; the three distribution-review requirements stay open.

## Audited build and evidence boundaries

[Run 39014508946](https://github.com/AetheriumSimulator/qemu-hmos/actions/runs/39014508946)
built PR merge checkout `d85ee854c17e3c1a76b154f156317b226d4fe628`
(head `f618f98760487521b83647ff5a057c3e116b239c`). Native compilation, both
UEFI builds, unsigned HAP assembly, payload checks, source collection and
structural/hash verification succeeded. Distribution verification reported
`allowed=false` for missing reviews; upload and Release were skipped, zero
artifacts were created, and no device test ran.

The log recorded 102,056 source members, 45 source records and 119 exclusions.
The [machine-readable source/license observations](2026-10-17-component-evidence.json)
retain the observed revisions, asset hashes, SDK hashes, dynamic dependencies and
63 top-level license-document identities. This is a source-candidate inventory,
**not 45 proven linked runtime components**, a complete SBOM or a claim that every
file under a component has its top-level license. It includes firmware test
submodules and tools. Log identities are not a downloaded HAP inspection.

| Observed item | SHA-256 |
| --- | --- |
| HAP | `68a83d82ae83124589a9c9ab0a950d09d6823c4766bc85fa62390d861fc9fe8e` |
| Candidate source archive | `0be2d54c398ff5ce8e93f89f468a087441e8e7954fee92eacdd0d16de7f42259` |
| Packaged `libc++_shared.so` | `899545c5e6c43134f20d611dc5b72f329f8e143c75a7cb3ec69f66df77ddc6b6` |
| Review scope (this historical build only) | `162adbb40e98f040181fae67fdac1634b60bd2f7345ef8a484be5b0f46d5e5b3` |

## Component and notice findings

| Source / integration | Checked license evidence and inclusion limit |
| --- | --- |
| QEMU `9c23f2a…` | `LICENSE`, `COPYING`, `COPYING.LIB`: emulator GPLv2 overall, per-file licenses; firmware separate. The native log compiles `hw/vfio/pci.c`, whose header specifies GPL version 2 without an “or later” option. |
| GLib 2.85.4 / gvdb | GLib `COPYING` and `glib/gmain.c`, gvdb `COPYING` and `gvdb/gvdb-reader.c`: LGPL-2.1-or-later evidence. GLib static build succeeds; building gobject/girepository too does not prove those libraries enter QEMU. |
| PCRE2 / Pixman | Tracked `LICENCE.md`: BSD-3-Clause WITH PCRE2-exception, with separately licensed JIT; Pixman `COPYING`: MIT-style notices, with per-file details retained. The earlier “PCRE2 full license missing” claim was incorrect. |
| curl / OpenSSL | Pinned curl `COPYING`: curl permission notice; vendored OpenSSL 3.3.1 `LICENSE.txt`: Apache-2.0. CI builds static curl with OpenSSL and reports `libcurl` enabled in QEMU. Its static pkg-config flags include `-lcurl -lssl -lcrypto`. |
| QEMU fallback libraries | libslirp `COPYRIGHT`: BSD-3-Clause and additional per-file notices; dtc/libfdt headers: GPL-2.0-or-later OR BSD-2-Clause. Logs compile their static archives. keycodemapdb README permits generated output under GPL-2.0-or-later or BSD-3-Clause. |
| Other fetched source records | libffi `LICENSE`: MIT-style; proxy-libintl header: LGPL-2.0-or-later; Berkeley SoftFloat/TestFloat `COPYING.txt`: BSD-3-Clause; libblkio carries Apache/MIT and crosvm notices. Fetched/built records alone do not prove runtime inclusion. |
| Native bridge | Root license texts and per-file headers apply; vendored `entry/src/main/cpp/third_party/cjson/cJSON.c` retains its MIT notice. CMake reports LibVNC server/client archives absent, so this HAP must not be described as linking the optional LibVNC archives. |
| EDK2 `4dfdca6…` | `License.txt`: BSD-2-Clause-Patent; `License-History.txt` preserves earlier notices. Both ArmVirt and OVMF are built from this checkout. Firmware module logs select `OpensslLibCrypto.inf` (separate EDK2 OpenSSL revision `de90e54…`, Apache-2.0), BaseCryptLib/SecCryptLib and Fdt libraries. |
| EDK2 archive extras | Brotli MIT; ArmSoftFloat BSD-3-Clause; MbedTLS Apache-2.0; Oniguruma BSD-2-Clause; MIPI Sys-T BSD-3-Clause; pugixml/Jansson MIT; libspdm BSD-3-Clause; cmocka Apache-2.0; GoogleTest BSD-3-Clause; subhook BSD-2-Clause. OpenSSL test submodules have their own notices (including libprov CC0 and multi-license krb5/pyca). Their inclusion in the archive does not imply all are in the firmware. |

The QEMU shared-link recipe retains the Meson object graph (except the executable
entry point and executable-only flags). The actual response file is collected in
the source candidate but was not exposed in the audited run's log. The combination
of compiled GPLv2-only VFIO code and enabled static OpenSSL is a concrete
compatibility-review question, not resolved by the root Apache text, a broad
“GPLv2 or later” label, or disabling KVM. The
[Apache Software Foundation's compatibility explanation](https://www.apache.org/licenses/GPL-compatibility.html)
identifies the GPLv2/Apache-2.0 issue. Confirm selected link inputs/object retention
and any applicable exception before approval; this audit does not declare the
HAP unlawful or compliant. Separately built firmware is not automatically part
of the same linked work.

The filename-based `licenseFiles` index is not a notice-completeness checker:
it matches license/licence/copying/copyright, but not `NOTICE`, `BSD-2-Clause` or
license headers in arbitrary source files. Such source files may still be in the
archive. In particular the SDK LLVM notice is outside the current source snapshot
and is not automatically delivered merely because the SDK archive hash is logged.
A release needs a deliberate, artifact-matched notice set and source obligations,
not just a count of license filenames.

## Exact SDK runtime provenance

The two public SDK archives were independently downloaded and hashed for this
audit. Only archive metadata, license text and binary bytes were read; no SDK
installer/binary was run and no new terms were accepted.
The [runtime evidence JSON](2026-10-17-sdk-runtime.json) preserves the exact
archive member names, package metadata and hashes.

* Native compiler input: [6.0-Release SDK archive](https://repo.huaweicloud.com/harmonyos/os/6.0-Release/ohos-sdk-windows_linux-public.tar.gz),
  SHA-256 `a315834ac133625efc912bd078f3e2b2550868d04aef1b5aa4f9679c8b3c9d8e`.
  Despite its URL, the inner Linux native ZIP is named
  `native-linux-x64-6.0.0.47-Beta1.zip`.
* HAP tool input: [command-line tools 5.1.0.840](https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/commandline-tools-linux-x64-5.1.0.840.zip),
  SHA-256 `1dcefa4741dc289277560b2802040e0c45b433898d8db453d711d5376e0478f1`.
* Its `command-line-tools/sdk/default/openharmony/native/oh-uni-package.json`
  identifies **OpenHarmony native 5.1.0.125, API 18, Release**.
* `command-line-tools/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so`
  is 1,262,184 bytes and has the **same SHA-256 as the HAP runtime above**.
  The `aarch64-linux-ohos/c++/` duplicate matches too. The native 6.0 SDK runtime
  (`b0455e67…`) and the HAP tool bundle's HMS/BiSheng runtime (`cb1203bb…`) do not.
  Therefore the compiler SDK version is not the packaged C++ runtime version.

| Bundled document in command-line tools | SHA-256 / significance |
| --- | --- |
| `LICENSE.txt` | `ce19d08d8bbdad17a2866511e3f9b947915b96b0d57ef1acb7989859feb60669`; DevEco agreement with exhibits |
| `sdk/default/openharmony/native/llvm/NOTICE` | `0de99f6e07e1f7c2438ab21c20a5b05635ba7b206d843be32b75b2029c288f31`; direct LLVM component notice, including libc++, libc++abi and libunwind |
| `sdk/default/openharmony/native/NOTICE.txt` | `6179b3b8bd4017b4de8f486a0bdfc4c189a40a6850bb1efcc19fe707ed86c178`; broader native-tool notice, not itself a precise runtime BOM |

The direct LLVM notice contains Apache-2.0 WITH LLVM-exception and legacy
libc++/libc++abi notice blocks. This materially narrows the licensing question;
there is no basis to treat this runtime as unidentified proprietary Aether code.
[LLVM's official license](https://llvm.org/LICENSE.txt) also describes the
redistribution/attribution conditions and exceptions. The exception for portions
embedded by compilation must not be assumed to waive every notice requirement
for a separately shipped `libc++_shared.so`. The bundled version-specific notice,
not just today's upstream web page, must be retained and mapped to the bytes.

The bundled DevEco agreement §1.6 expressly distinguishes third-party licenses
and directs OpenHarmony SDK use to **Exhibit C**. Exhibit B §3.1 describes
HarmonyOS SDK app integration, while §4.1(d) restricts SDK redistribution. Do not
apply Exhibit B's proprietary-SDK restriction to this identified third-party
OpenHarmony LLVM runtime without resolving the applicable terms. Exhibit C only
provides [the OpenHarmony SDK agreement URL](https://downloads.openharmony.cn/sdk/license/OpenHarmony-SDK.txt),
which returned HTTP 403 in this environment and was inaccessible through the web
reader. No alternate authoritative copy was established. The exact upstream
LLVM/OpenHarmony runtime source revision and downstream patch/build mapping were
also not established from the inspected metadata. These are specific remaining
evidence gaps, not a finding of infringement and not a request to accept terms.

## Source closure and offline curl repair

The original archive strips `.git`, but `build_curl_ohos.sh` initialized Git and
checked out the pinned commit into the already populated archived curl directory.
A minimal checkout reproduction failed with untracked files that would be
overwritten. Thus the presence of source files and a matching archive digest did
not establish that the retained recipe could rebuild them.

The repaired recipe never fetches over an existing curl source directory.
`tools/verify_curl_source.py` reconstructs Git blob/tree identities offline and
requires the fixed upstream tree `6ae23d9333713707a02588b44ed238a50e8b3bde`
for commit `01346829096c61b372692f6dc43ffa778c6caccd`. Content, paths, executable
bits and symlink targets are bound. Only the four CRLF checkout paths explicitly
specified by the pinned curl attributes are normalized to their Git LF form.
Missing, changed or extra entries fail before CMake; a missing source directory
may be fetched at the fixed revision and is subject to the same tree check.
No source identity can be overridden by an environment variable or a “ready” flag.

Regression tests compare the offline tree calculation with Git, repeat without
`.git`, reject missing/extra/changed/mode/symlink inputs, cover the exact CRLF rule,
and prove an invalid existing snapshot cannot invoke Git or CMake. Independently,
the verifier matched both the real pinned curl checkout and a metadata-free
extraction of its Git archive. A shell replay of that extraction reached all
three mocked CMake stages with Git replaced by a failing stub (no real compiler
or device execution in that test). This fixes the curl-specific
failure; it does **not** claim a complete clean source-archive-to-HAP rebuild or
a successful installation of an unsigned HAP on a device.

The archive also retains the active workflow recipes, generated GLib scaffolding,
EDK2 Conf text, toolchain files and native link configuration. Host package/pip/npm
resolution and SDK acquisition are still external build prerequisites. `AGENTS.md`
contains an `hdc install` command, but a listed command is not a proven unsigned
installation/boot path. A clean extracted-archive replay with documented SDK
placement and installation prerequisites remains necessary engineering evidence.

## All 119 exclusions and retained compressed firmware

The [per-path exclusion assessment](2026-10-17-source-exclusions.json) classifies
every entry: 53 prebuilt QEMU ROMs, 15 linux-user vDSOs, 14 other QEMU submodules,
9 QEMU/dtc test fixtures, 17 EDK2 test data entries, 3 EDK2 prebuilt tool inputs,
2 Brotli dictionary files, 2 Windows host modules, one external X11 symlink,
one text Makefile, one text test expectation, and the supplementary ports tree.
These categories explain the observations; they do not approve all exclusions.

Concrete remaining problems:

* `BaseTools/Source/C/Makefiles/ms.app` is a text Makefile with a
  BSD-2-Clause-Patent header. Suffix-based rejection incorrectly calls it compiled
  payload. `ShellCTestApp/TestArgv.log` is documented expected test output.
* Brotli `dictionary.bin` is data, while selected `dictionary.c` embeds the bytes.
  `BaseTools/Bin/GnuNoteBti.bin` is referenced by EDK2 `tools_def.template`.
  Their applicability/derivation must be checked against the selected recipe;
  absence of an ELF header does not prove an input is unnecessary.
* QEMU's `pc-bios/meson.build` passes the excluded ROM names to `install_data`
  when `install_blobs` is enabled. The current CI configure command does not
  disable that option. A clean archive replay must resolve this missing-input
  path instead of re-downloading omitted prebuilt ROMs.
* Conversely, the collector retains **13 prebuilt `pc-bios/*.fd.bz2` files**.
  They bypass the suffix/magic filter as compressed data. Independent
  decompression found firmware volume signatures; their
  [compressed/decompressed identities](2026-10-17-compressed-firmware.json) are
  recorded. They must not be presented as the freshly built two HAP firmware
  images or as source text. Resolve their removal and the matching build recipe
  before asserting a source-only, closed delivery.

The last two findings concern the candidate source archive itself, even though
it has not been publicly uploaded. They reinforce why an automated structural
pass cannot substitute for the source-completeness review.

## Next bounded checks before any distribution approval

1. Resolve the classified exclusions and complete clean archive replay; preserve required
   build inputs and source text rather than classifying solely by filename suffix.
2. Inspect selected link inputs and per-file exceptions for the native
   GPLv2-only/OpenSSL combination, and provide the actual component notices with
   the delivery. This is separate from firmware's license assessment.
3. Retain the exact LLVM runtime notice and establish the applicable OpenHarmony
   SDK terms and runtime source/patch mapping. If an unresolved interpretation or
   rights-holder permission is required, stop that dependent publication rather
   than fabricating approval.

Any eventual machine-readable approval must identify itself as automated
engineering review, bind this evidence to the exact scope, and state its limits.
No human, lawyer or rights-holder approval is implied. The gate remains closed;
no actual upload, prerelease or merge is authorized by this audit.

## Follow-up: archive input repairs

The findings above describe the audited historical candidate. The follow-up
repairs the following engineering errors without changing VFIO, OpenSSL, device
models, the packaged native libraries, or the two HAP firmware build targets:

* The collector and verifier share one payload classification rule. The exact
  EDK2 `ms.app` Makefile and `TestArgv.log` expected output are retained only as
  valid text (the latter is BOM-marked UTF-16). ELF/PE/archive magic, invalid text
  and embedded control bytes remain rejected. This is not a blanket `.app` or
  `.log` exemption.
* Compound firmware suffixes such as `.fd.bz2`, `.bin.gz` and prebuilt `.dtb` are
  rejected consistently by collection and verification. The 13 old compressed
  EDK2 files are no longer carried as apparent source. QEMU's pinned
  `pc-bios/README` attributes those images to `edk2-stable202302`, with
  `OpenSSL_1_1_1s` and SoftFloat, and points to `edk2-licenses.txt`; those provenance
  documents remain in the archive. That attribution is not independently proven
  binary/source correspondence and is not substituted for this HAP's actual
  EDK2 revision. The old images are not inputs to the two separately built HAP
  firmware payloads.
* `tools/prepare_hap_sources.py` reconstructs the 32-byte AArch64 GNU BTI property
  note from named ELF fields and asserts SHA-256
  `4cd79611a5b20ea164d0bb517e3babbaa1915f1a5698a7b033b669d35cc4f5d0`, identical to
  the pinned EDK2 input. Both native-source preparation and the UEFI recipe invoke
  it. Missing notes are recreated; unexpected existing bytes fail rather than
  being silently replaced. The archive carries the readable recipe, and the
  omission record names it; it does not drop the required build input without a
  reconstruction path.
* The HAP shared-core configure command explicitly sets `--disable-install-blobs`.
  A hash-checked, idempotent source adaptation makes `pc-bios/meson.build` return
  before prebuilt ROM targets when that option is false. Merely setting the
  option was insufficient: upstream still unpacked EDK2 images when bzip2 was
  installed. The `install_blobs=true` path and upstream remainder are preserved.
  The native executable/data installation is not the HAP firmware-delivery path;
  `validate-uefi` still builds ArmVirt and OVMF and packages their fresh outputs.

`tools/replay_source_inputs.py` reads the actual collected archive, extracts the
relevant inputs into a fresh metadata-free directory, invokes the archived
preparation recipe, verifies the regenerated note, and runs the real archived
pc-bios Meson file. With bzip2 available, `install_blobs=false` configures without
prebuilt ROM files; `true` still requires the omitted ROM inputs and fails on the
expected firmware filename. This is a deliberate HAP-source configuration, not a
claim that the source archive rebuilds every upstream QEMU firmware platform.
The same replay passed locally against actual pinned sources; CI runs it against
the newly collected delivery archive before evaluating distribution eligibility.

The replay is **targeted build-input reconstruction**, not a complete clean
archive-to-HAP rebuild. Full source closure, native license compatibility, SDK
terms/notice delivery and device acceptance remain separate. No review approval,
public artifact upload, Release publication, or merge follows from these repairs.
