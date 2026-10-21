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
- Cancelling, disabling, VM stop, leaving the page, or backgrounding the owning
  `EntryAbility` invalidates pending requests and closes input. Returning to the
  foreground does not resume it automatically; the user must enable it again.
- This is deliberately an **EntryAbility foreground-only** policy. Opening the
  separate VNC or console Ability backgrounds EntryAbility and closes its
  microphone session, even though the application may still have visible UI.
  Supporting recording across those Ability transitions requires a separate
  lifecycle design and is not part of this change.

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
| OHAudio capture and interruption/error callbacks | OHAudio C APIs | 10 |

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
They exercise consent races and the actual backend compiled against test mocks;
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

[permissions]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-ability-kit/js-apis-abilityAccessCtrl.md
[authorization]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/security/AccessToken/request-user-authorization.md
[native]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-ability-kit/ability__access__control_8h.md
[native-build]: https://github.com/openharmony/interface_sdk_c/blob/OpenHarmony-5.1.0-Release/security/access_token/BUILD.gn
[callbacks]: https://github.com/openharmony/docs/blob/OpenHarmony-5.1.0-Release/en/application-dev/reference/apis-audio-kit/_o_h___audio_capturer___callbacks___struct.md
