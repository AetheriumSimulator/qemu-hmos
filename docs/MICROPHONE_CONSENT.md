# Microphone consent and recording boundaries

This change adds consent and capture controls to the existing fullcore OHAudio
path. Build success does not establish that microphone authorization, guest
recording, or a particular device works. No microphone or device access is
required by the host tests.

## Request and lifecycle flow

- `Index.ets` starts a VM through `QemuVMManager.startVM`, which calls the native
  `startVm` entrypoint directly. QEMU guest input voice activation reaches the
  OHAudio backend; VM startup itself does not authorize microphone use.
- The user enables the selected, running VM's microphone explicitly.
  `MicrophoneManager` delegates permission checks and requests to
  `MicrophoneConsent`. No startup permission prompt or persisted consent is used.
- The native `getMicrophoneSession(vmName)` identifies the running session.
  `setMicrophoneEnabled(vmName, session, enabled)` binds consent to that session;
  an old dialog result cannot authorize a replacement VM with the same name.
  `getMicrophoneStatus(vmName)` reports the native input state to the UI.
- A denied request leaves input disabled and explains how to retry. The separate
  settings button calls `requestPermissionOnSetting` after an ordinary request.
  A successful dialog result is followed by a fresh permission/session check.
- `MicrophoneWindows` tracks each Ability/window instance, not just its class
  name. VNC/Console use per-window LocalStorage and a fixed native session passed
  at launch. An old viewer cannot authorize a same-name replacement VM. Their
  status and retry controls use both VM name and session, including denied states.
- A visible, successfully loaded window for the same session can keep an already
  approved microphone active when EntryAbility backgrounds. `isWindowShowing()`
  is rechecked at control boundaries, but cannot replace the initial positive
  visibility event or override an explicit invisible event. Ability foreground,
  window shown/hidden and actual visibility retain independent vetoes.
  Registration/load failures and stale destroyed-window callbacks do not
  count as visibility. Playback remains independent.
- Opening a viewer from the details page may issue a one-shot internal handoff
  tied to the source instance, target Ability, VM and session. It is issued only
  for already approved input, never for a pending permission request. If the
  source disappears before the target becomes visible, Native input stops
  immediately and clears buffered samples. Once the exact target is ready and
  visible, permission, screen state, session and Native health are rechecked
  before resuming that approved intent. There is no timed recording grace period.
- Application background, lock/screen-off, user cancellation, window launch
  failure/destruction during a handoff, permission loss, Native failure or VM
  stop cancels both input and pending handoffs. Foreground/show/unlock events
  never restore cancelled consent. A pending authorization is also cancelled
  when its requesting window disappears, even if another window is visible.
- The application background event is always a hard stop, including if a device
  emits it during an internal transition. API17/18 offer no global ordering
  guarantee between these event streams. Seamless recording on every device is
  therefore not claimed: unproven visibility pauses input, and an ambiguous
  application-background transition requires another explicit enable action.

## API compatibility

The app targets HarmonyOS API18 and retains minimum API17. The implementation
uses public APIs available below that minimum:

| Operation | API | Since |
| --- | --- | --- |
| Check current grant | `AtManager.checkAccessToken` | 9 |
| First authorization | `AtManager.requestPermissionsFromUser` | 9 |
| Explicit settings retry | `AtManager.requestPermissionOnSetting` | 12 |
| Native grant check | `OH_AT_CheckSelfPermission` | 12 |
| Foreground/background callbacks | `UIAbility.onForeground/onBackground` | 9 |
| Application foreground/background | `ApplicationContext.applicationStateChange` | 10 |
| Window shown/hidden and visibility | `windowEvent` / `windowVisibilityChange` | 10 / 11 |
| Window display snapshot | `Window.isWindowShowing` | 9 |
| Screen lock/unlock and screen-off events | `commonEventManager.Support` | 10 / 9 |
| Active screen snapshot | `power.isActive` | 9 |
| Auxiliary lock query | public `screenLock.isScreenLocked` | 7 (deprecated 9) |
| Per-window page storage | `WindowStage.loadContent` / `Entry.useSharedStorage` | 9 / 12 |
| OHAudio capture and interruption/error callbacks | OHAudio C APIs | 10 |

These declarations were checked in the actual API18 SDK (5.1.0.125) and the
official versioned SDK references; they do not require an API18-only fallback.
An API17 SDK build and API17 device run are separate evidence, not implied by
the app's `compatibleSdkVersion` or an API18 build. The system-only synchronous
`screenLock.isLocked()` is not used. The old public Promise query is still in
the public API18 SDK and is used only as an auxiliary signal.

The [window API][windows] documents availability/capability errors; unsupported
visibility subscription or an unobserved initial visibility keeps input closed.
A positive `isWindowShowing()` only
reports `STATE_SHOWN`, not occlusion or lock status. The [lock service client]
[lock-client] can return false on IPC/service failure, so a false lock query is
not treated as a standalone proof of safety. Live visibility vetoes,
[application background][application], [lock/screen-off events][screen-events],
active-screen checks and session checks are also required. These asynchronous
OS signals do not provide an atomic lock/visibility snapshot; event latency and
device-specific transitions remain part of real-device acceptance.

The `MICROPHONE` permission stays `when: inuse`, with EntryAbility,
VNCWindowAbility and ConsoleWindowAbility listed in `usedScene.abilities`.
No background-recording permission or `always` usage is added. Permission is
application-wide; the [scene declaration][declaration] describes its intended
use rather than granting independent permissions to each window.

The API18 [permission reference][permissions] marks `selfPermissionStateChange`
as API18, so it is not an API17 fallback. The older `permissionStateChange` is a
system API requiring `GET_SENSITIVE_PERMISSIONS`; this app does not request it.
Instead, foreground polling updates the UI and Native independently rechecks
authorization. Grant status must not be persisted: users can revoke it later.
The [authorization guide][authorization] documents rejection and recheck rules.

The [public Native header][native] is
`<accesstoken/ability_access_control.h>`, linked with
`libability_access_control.so`. The API12 declaration returns `bool`.
The [SDK build metadata][native-build] also records minimum API12.

## Native safety and playback

Input defaults to closed independently of ArkTS. Native validates the running
VM session and current platform permission before enabling capture, and gates
capturer startup and sample delivery. Closing input discards queued samples.
Permission loss, capture failure, or interruption closes the input path; retry
requires a new explicit enable action. Playback has its own renderer and does
not require microphone consent.

Disabling Native input now preserves its fault latch, including a final
callback during Stop/Release. A handoff can resume only from `disabled`, never
from `blocked` or `error`; a new explicit user attempt is needed to reset a
fault. This retains the existing ABI and avoids hiding an interruption by
temporarily closing input.

Input uses `in.mixing-engine=off,in.voices=1`, so the final guest `AUD_read`
passes through the backend gate instead of QEMU's generic capture queues.
The backend refuses input mixing mode. Input uses the guest's negotiated
signed-16-bit little-endian format, rate and channels; unsupported formats fail
input only. Output retains its existing 48 kHz stereo mixing path.
The embedded core owns process-wide audio state: starting a second concurrent
VM is rejected. A core missing either microphone control export is rejected
before startup; rebuild older cores rather than running an unguarded capturer.

Audio callbacks cannot safely drive capturer teardown: the official
[callback reference][callbacks] prohibits AudioCapturer calls from `OnReadData`.
Callbacks mark input blocked and discard data; control paths perform teardown.
A permission grant is not evidence of active guest recording or an open global
microphone switch. Those conditions still require device verification.

## Validation and device acceptance

Run host regressions with
`python -m unittest discover -s tools -p 'test_microphone_consent.py' -v` and
`python -m unittest discover -s tools -p 'test_ohaudio.py' -v`.
They exercise consent races, the production window policy and platform manager
with mocked lifecycle/window/permission events, and the actual backend compiled
against test mocks;
they do not run the HarmonyOS permission service or a physical capturer.
The PR's exact-commit CI must separately report ArkTS/HAP compilation, Native
compilation, the existing API18 OHAudio compile/link probe, source/dependency and
license evidence checks, and publication guards. Record failures, unrun checks,
and blocked checks separately; this document itself claims no passing run.

Real-device acceptance remains pending:

- API17 and API18: first grant, deny, settings retry, revoke, global microphone
  mute, and clear feedback without disabling guest playback.
- Guest starts/stops recording before and after enabling input; actual captured
  samples, latency, channels, routing, and microphone privacy indicator agree.
- Rapid enable/cancel/retry; dialog resolves after background, VM stop, or
  replacement session; no stale authorization or buffered sample delivery.
- Background/foreground, lock screen, VNC/console Ability transitions,
  interruption/error, guest exit, and VM stop release input without deadlock.
- Source-first and target-first window transitions; overlapping VNC/Console
  multitons; closing Entry while a matching viewer remains; failed viewer load;
  stale windows after same-name VM restart; shown-but-occluded windows; API17/18
  lock/unlock and screen-off event ordering. Internal gaps must produce no
  samples, and hard stops must never resume from late events or dialog results.

[permissions]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-ability-kit/js-apis-abilityAccessCtrl.md
[authorization]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/security/AccessToken/request-user-authorization.md
[native]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-ability-kit/ability__access__control_8h.md
[native-build]: https://github.com/openharmony/interface_sdk_c/blob/OpenHarmony-5.1.0-Release/security/access_token/BUILD.gn
[callbacks]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-audio-kit/_o_h___audio_capturer___callbacks___struct.md
[windows]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-arkui/js-apis-window.md
[application]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-ability-kit/js-apis-inner-application-applicationContext.md
[screen-events]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-basic-services-kit/common_event/commonEventManager-definitions.md
[lock-client]: https://github.com/openharmony/theme_screenlock_mgr/blob/OpenHarmony-5.1.0-Release/frameworks/native/src/screenlock_manager.cpp
[declaration]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/security/AccessToken/declare-permissions.md
