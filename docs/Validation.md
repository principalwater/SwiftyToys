# Validation snapshot: 0.1.11

## Swift Ember native branding

2026-10-12. The complete installed package passes all 18 native checks, including
the ten-page settings layout/navigation check and real WM_GETICON bindings.
The embedded ICO contains eight transparent resolutions; separate native resource
loading verified each size. The original SVG source is retained. Caption icons
reload on window DPI changes; the tray receives at least a 32-pixel icon so it does
not start with a bitmap that must be enlarged for 125–200% taskbars.

The final Command Ember EXE is 6,607,872 bytes, SHA-256
`C691870EF5C34463E03910A85EABF25A7E132320F89E7C3A5EA30BD04318456D`.
Installation preserves Automatic software control, DDC off and the current level.
No display/input pipeline change or new runtime library is introduced by branding.
Calculated normal-text contrast ranges from 4.94:1 to 15.20:1 for the selected
palette. High contrast uses system colors and native controls retain their names.

The operator confirms the feature tiles and Overview transition work normally.
The final Command-style mark was selected from concepts; its raster frames were inspected
at actual tray sizes and native loading was checked. Windows Graphics Capture
timed out twice while obtaining an automated screenshot; that tool supplied no
visual evidence. Physical mixed-DPI, high-contrast, Narrator and Windows 11 checks
remain acceptance limits.
See [design and material boundaries](Design.md).

## Desktop freeze regression and native runtime

2026-10-12, Windows 10 / MacPro6,1. The user reports a frozen visible interface
with audio/cursor still active and recovery requiring reboot followed by disabling
SwiftyToys. The copied-desktop Magnification renderer introduced in 0.1.6 is a
source-backed failure path: a stalled refresh/driver operation can leave an opaque
stale image visible. No hang dump established the exact native blocking call.

0.1.10 removes that renderer and its 16-ms timer entirely, migrates saved compositor
preferences durably to Automatic, and retains DDC off and the saved brightness.
Native WDDM/AMD controls preserve calibration. Process/layout work runs outside
the keyboard hook, Shell/HID events are bounded/coalesced, display lists load off
settings UI, and recovery requires exact lease/binding identity. Unchanged successful
brightness does not rewrite the driver; refresh/resume/rebind invalidates that cache.

35 portable tests and all 18 native checks pass on the complete installed package.
These include blocked foreground resolution/nonblocking consumption and stop,
shared command admission, exact lease fields, missing checkpoint vs confirmed
restoration, mapping changes, dual-source HID pulses, failed notifications,
overflow/release/repress and nested observer events. They do not inject real driver
failure or prove all scheduling paths. Binary import inspection finds no
MagSetWindowSource, MagSetColorEffect or MagSetWindowTransform. Legacy cursor
visibility recovery remains, without normal cursor mutation.

The installed static EXE is 6,576,128 bytes, SHA-256
`6ABCE9BAD6E28119A020E0C735E9637078A51923967026CB4B499E476334260C`.
Native status reports WDDM gamma, DDC off, physical backlight 100%, both mice with
vertical inversion and the Bluetooth Precision driver. The user confirms normal
window/video updates, smooth mouse/trackpad use, held F1/F2 and Cmd+H/Tab, with no
freeze during this check. User brightness changes are preserved.

A 120-second read-only observation sampled the resident at approximately 0.081%
of one CPU core, 4.40 MiB private memory, 15.03 MiB working set, 9 threads and
258 handles. Watchdog: 2.34 MiB private, 9.75 MiB working set, 1 thread and
151 handles, no visible CPU increment at counter resolution. This interactive
sample is not a controlled A/B, GPU, input-latency or weaker-hardware benchmark.
The unsafe renderer was not restarted to obtain a baseline. A separate ten-minute
interactive observation recorded about 0.016% of one core and 4.39 MiB resident
private bytes; watchdog ended at 2.34 MiB with no measured CPU increment.
This does not establish long-session stability. See [runtime boundaries](RuntimeArchitecture.md).

Native cursors remain potentially brighter with DDC off. Unknown applications may
receive the first chord natively while resolving; known live processes reuse cache.
HID overflow beyond 128 buffered transitions can discard completed taps while
preserving release/held state. Deferred Shell work can show a brief first-frame flash.
Sleep/resume, abrupt failure, additional DPI/accessibility/device cases and long
gaming sessions remain physical acceptance limits; no universal driver-failure
or weakest-hardware performance guarantee is claimed.

## Previously installed 0.1.9 first keyboard chord

The previous adapter passed through when the current PID differed from the cached
PID. Its asynchronous foreground callback or 60-second timer could refresh that
cache later. The user reports repeated Cmd+H misses followed by native Task View
on the first Cmd+Tab, then normal remapping. This is consistent with the source
race; silent hook removal and other integration failures are not ruled out solely
by that observation.

The candidate resolves current HWND/PID context before processing the event,
rechecks focus and retains that snapshot for actions. Successful lookups are
cached; unresolved contexts fail closed with one-second retry backoff. Regression
checks exercise first Cmd+H/Tab without a foreground notification, exclusions,
scoped overrides, failure/retry, window changes and release while Command is held.
34 portable tests and all 17 packaged native checks pass. The native lookup check
sends no keys or window actions and verifies one process lookup across 1,000
unchanged-context accesses. The static executable is 6,538,240 bytes (2,560 bytes
above 0.1.8), SHA-256
`09ED71A8354BE72D410B6AA9FB3E2C3EF5EBEC37AD1F0C0B3F1ED9B22DF0B595`.
The complete package is installed with that exact hash; DDC remains off and the
user's software level is preserved. The preceding candidate differs only in PE
timestamp/checksum fields, and also passed all 17 native checks.

A private metadata-only microbenchmark on Windows 10 / MacPro6,1 sampled 500
lookups per implementation and target. Previous array/current temporary-buffer
p95 values were 0.0788/0.0795 ms for the test process and 0.0822/0.0814 ms for the
sampled foreground process; all queries succeeded. This measures the resolver
alone, outside the hook. It proves neither an input-latency improvement nor a
worst-case timing guarantee; native calls and scheduling can still exceed hook
timeouts. Installed first-chord checks and release verification remain pending.

## Previously released 0.1.8 native cursor visibility

2026-10-11, Windows 10 / MacPro6,1. Full installed package EXE: 6,535,680 bytes,
SHA-256 `80635AA4D2F6FABDFAEF35E7DE6E9BC633FCFE0F24DFAC27187C3A223F52E941`.
31 portable tests and all 16 packaged native checks pass. Cursor policy checks
reject the magnified-cursor style; recovery checks distinguish legacy cursor-owning
leases from new image-only leases and reject unknown backends.

The live owned viewport has no magnified-cursor style and writes an image-only
`composition` lease. Windows reports a visible cursor in the sampled surface.
The user confirms cursor visibility in League of Legends and the audio-output
tray menu, but also confirms it remains brighter than the dimmed image. This fixes
disappearance, not native cursor luminance. Software remains 80%, DDC off;
physical backlight reads 100%. A notification burst preserves the same visible
viewport/session/level without restore, recreation or color reapply.

A separate guarded native Swift fullscreen-color probe at exactly 1x, with no
cursor calls, copy viewport, input transform or gamma writes, also leaves the
cursor brighter according to the user. Its independent guard restored original
color and the saved 80%; neither probe process remains active. No probe is shipped.
DXGI pointer-separation metadata alone does not establish physical cursor luminance.

Source comparison: MonitorControl uses macOS gamma tables or a shade window;
Windows tools LightBulb and Twinkle Tray use GDI gamma ramps. Their implementations
do not establish hardware-cursor dimming on this output. A separate two-minute
direct GDI probe retained the original LUT, used no cursor/overlay/DDC calls and
restored calibration with exact readback. The user reports a visible but still
brighter cursor. No GDI backend or probe is shipped. [MonitorControl](https://github.com/MonitorControl/MonitorControl/blob/84ac2d72bfb53b653536e484946f6ed027e4229c/MonitorControl/Model/Display.swift),
[LightBulb](https://github.com/Tyrrrz/LightBulb/blob/e4c1aefa26e78828c0af0f794e0e5a23c4d90d3d/LightBulb.PlatformInterop/DeviceContext.cs),
[Twinkle Tray](https://github.com/xanderfrangos/twinkle-tray/blob/fec2ef0e7a3ad94092f230faa4d6d7b87a0cf188/src/modules/tt-windows-utils/windows_display_brightness.cc).

Further read-only research found no documented baseline getter for the monitor
3x4 color-space setter; it was not called. Windows documents MHC ICC profiles as
the supported application interface to that calibration pipeline. The documented
MHC2 capability-query export is absent on this Windows 10 installation; this does
not prove all hardware/profile support is absent. Native cursor dimming without
DDC remains an open requirement. [Gamma cursor limitations](https://learn.microsoft.com/en-us/windows/desktop/direct3ddxgi/using-gamma-correction),
[hardware calibration contract](https://learn.microsoft.com/en-us/windows/win32/wcs/display-calibration-mhc).

Global hiding/copying, cursor-theme mutation, input hooks and undocumented driver
changes are absent. Legacy cursor restoration is retained for recovery only.
No dependencies or ISA requirements were added; the EXE size is unchanged from
0.1.7. No controlled CPU/GPU, latency or weakest-hardware improvement is claimed.

## Previously released 0.1.7 brightness notification stability

2026-10-07, Windows 10 / MacPro6,1. The full installed package's executable is
6,535,680 bytes, SHA-256
`B7FEE740130ED3E500B074B0C579F914388760C289E7DCC64867478D3F8984F8`.
31 portable tests and all 16 native checks pass on that packaged executable.

Generic device/settings/power-status broadcasts now mark one pending validation.
The display executor checks the actual physical SDR path, identity and bounds on
the next request or existing 3-second tick, preserving an unchanged viewport.
Display-mode/session/suspend/resume events still restore immediately. Failed queries
also restore; a newer hint received during validation remains pending. At 100%,
viewport buffers and their notifications are not allocated.

A payload-free runtime notification burst against this process's viewport preserves
the same visible HWND, session pointer and saved 80% level through deferred checks;
its lifecycle log records no restore, recreation or color reapply. Installed queries
confirm DDC off and physical brightness 100%. The user reports no further jumps
after checking ordinary use and mouse wake. This does not establish a vendor-specific
cause or cover every possible display/power transition.

An invalid private cross-process Magnification diagnostic crashed the resident;
the watchdog restored cursor visibility and cleared completed recovery. That probe
was removed. Safe runtime checks pass after restart; the diagnostic is absent from
the application and release. This is not a crash-recovery stress test.

Uncontrolled 15-second interactive samples before/after record 2.80%/4.36% of one
CPU core, 35.33/34.40 MiB private bytes and 27.05/25.33 MiB working set. Workloads
were not matched, so these samples establish neither a speedup nor a regression,
idle cost, input latency, GPU usage or weakest-hardware performance. The executable
grew by 1,024 bytes; static Swift and the 3 MB archive budget remain enforced.

## Previously released 0.1.6 cursor and held-key checks

The installed full package is 6,534,656 bytes, SHA-256
`1DEF251C33CB878F9F454A09140864FB7D8B9366B7D0A7DD84A3A2FBCB3C5F56`;
31 portable tests and all 16 native checks pass on the packaged binary.
The native cursor policy check creates no viewport and changes no cursor state.
The input check captures F2 in its own hook before, during and after a 2.4-second
blocked test UI. It constructs no display controller.

The private refreshed prototype was confirmed to show a dimmed, controllable cursor
and dim ordinary tooltips. Its fixed 60% coefficient above the old gamma caused
double dimming and did not follow the application slider; the production candidate
uses one coefficient and releases the viewport at 100%. The installed software mode
reads 80%, Windows compositor, DDC off and physical backlight 100%. The user
confirms adjacent changes without popup flashes, held F1/F2 repetition and normal
brightness at 100%. Version 0.1.6 was published as a prerelease.

The user narrowed the remaining flash to the application's percentage popup.
Source review identified its unconditional TOPMOST promotion above the compositor;
the installed follow-up inserts it behind the visible, process-owned viewport.
Non-erasing invalidation also avoids clearing the composition background. These
changes passed all 16 packaged native checks. The user confirms the popup flash is
gone and the held-key/100% checks work.

A 15.02-second interactive prototype sample used 2.7% of one CPU core, 33.65 MiB
private bytes and 21.95 MiB working set. This is not an idle, latency, GPU or
weakest-hardware benchmark; it does not establish production resource usage.

A separate 15.01-second installed interactive sample recorded 2.705% of one core,
34.96 MiB private bytes and 26.19 MiB working set. Foreground workload was not
controlled; this is not an idle, input-latency or comparable before/after benchmark.

## Previously installed tile-navigation candidate

2026-10-07, Windows 10 build 19045 / MacPro6,1. The installed packaged executable
is 6,510,592 bytes, SHA-256
`8891B654DB6AB4CEE0B126D44E3965687C90F43DB1A30CC890B7EB5DBB71BFAF`.

- 30 portable Swift tests and 15 native checks pass. Native tests cover DDC opt-in,
  legacy conflict migration, bounded request coalescing, Tab traversal through the
  clipped viewport, usable control sizes, back navigation, drafts/focus, English/Russian
  pages, ABI, storage, keyboard/worker ownership, driver trust and input-profile APIs.
- On the selected physical SDR monitor, software levels 50%, 40% and 45% all read
  back physical backlight 100%; 7 seconds of idle ticks retain 100%. Enabling DDC
  and setting 50% reads back physical 50%. Disabling DDC restores 100% once; saved
  software level 45% is restored. Tests finish with DDC off and software dimming.
- The actual installed GUI's DDC checkbox switches both ways with verified monitor
  readback. WM_NULL responds within the 500-ms probe limit during each request;
  this bounded check is not a latency benchmark. Overview return works afterwards.
- Real own-window previews verify the 3-column overview, 2-column compact overview
  and brightness details. Captures contain this app only; an overview preview is
  public. Header/viewport batches share their respective parents and Tab enters content.
- Cursor compatibility probes were separate from the application. On this output,
  AMD color gain and the documented disabled-trail setting did not dim the cursor.
  A windowed Magnification prototype hid the cursor in League of Legends; it was
  stopped and normal cursor visibility was confirmed by Windows and the user.
  A repeat test also showed a frozen viewport. The registered rescue shortcut
  successfully stopped it and restored the original pointer and brightness.
  The prototype is rejected and is not part of the source or release package.
  Software cursor dimming remains unresolved; DDC is still explicit opt-in.
- A follow-up candidate distinguishes a busy brightness worker from a failed
  driver operation and validates the complete reply range. All 15 native checks
  pass on that candidate; installation and release remain pending.
- Watchdog/recovery, target identity, HDR/clone/virtual exclusions and signed trackpad
  input are preserved. Failed enable/disable, cable removal, abrupt-crash recovery,
  sleep/resume, screen-reader and additional DPI/device combinations remain physical
  acceptance checks; the existing earlier user confirmations below remain evidence.
- GUI brightness/method requests and cold device reports are asynchronous. Legacy
  synchronous CLI IPC retains a bounded wait and can report busy during UI driver work;
  GUI completion is not claimed to eliminate every synchronous compatibility path.
- Static Swift runtime, System32 DLL imports and 3 MB ZIP budget are preserved.
  The EXE ceiling is now 6.6 MB for the added native UI/responsiveness work. Size
  growth does not establish CPU/RSS, battery or weakest-hardware improvements.

## Previously verified 0.1.5 behavior

2026-10-06 release checks on Windows 10 build 19045 / MacPro6,1:

15 KeyboardCore and 15 BrightnessCore checks pass. The checked executable is
6,451,712 bytes, SHA-256
`4F96FB2463A04AC839AFCC1A6EC6FCFD266A3D597D0C58A4651FAFF0C5F9DABF`.
This is the packaged executable; all 12 native checks were repeated on that file.

| Area | Current evidence | Limits |
| --- | --- | --- |
| Windows errors and WSL setup | Native Win32/HRESULT explanations, error domains, current-boot Event Log query and no-match path pass; settings preserve package/registration status if diagnostics fail | This boot reports Hyper-V VMX unavailable. Linux/Ubuntu first launch and Homebrew installation were deferred; no firmware or EFI changes were made |
| Keyboard lock / Sleep | Portable engine checks both modifier sides/order, repeat suppression and editable alternative; native shutdown privilege acquisition/restoration and saved-profile round-trip/deletions pass without a power transition | Actual lock, Sleep and resume remain manual checks, including held keys/sign-in policy; Windows reports S3 available on this host |
| Settings and shared runtime | All 10 English/Russian pages, WSL selection/blocking, storage/recovery, ABI, worker waits, mouse scope, device matching and layout API checks pass | Automated tests use the app's own controls and fixtures; they do not simulate physical device behavior |
| Brightness | Existing display/recovery tests pass; earlier physical DDC/CI and cursor-dimming checks below remain the hardware evidence | Only a virtual streaming output is active during this release check. The app correctly retains the disconnected physical target and does not retarget it |
| Mouse, keyboard and trackpad | Native mouhid direction remains vertical=1/horizontal=0; earlier user checks established Windows natural direction, LoL zoom, shortcuts and USB/Bluetooth gestures/reconnect | Those physical checks are not newly repeated by automation; original/USB-C trackpads and other Bluetooth radios remain unverified |
| Distribution | Static Swift 6.4, -Osize, no Swift DLLs, System32-only imports; 6.5 MB EXE / 3 MB ZIP budgets enforced | Size and successful tests do not establish a CPU/latency improvement or universal macOS-equivalent feel |

## Previously verified 0.1.3 behavior

2026-10-06 update on the same MacPro6,1 / Windows 10 build 19045:

- 14 KeyboardCore and 15 BrightnessCore tests pass. Native ABI, storage/recovery,
  mouse registry scope, input-profile API resolution, Boot Camp ID matching,
  bounded sent-message worker waits and all 10 English/Russian settings pages pass.
- The current prepared executable is 6,411,264 bytes, SHA-256
  `65729E124718E38B309AF4EDD97AC04086A41F5351E7E8354C8BE18AA45342E8`.
  It links Swift statically and verifies System32-only static DLL import resolution.
  The installed resident matches that hash and includes the Apple-layout GUI integration.
- Software wheel interception/injection is absent. The user previously confirmed
  LoL zoom returned after disabling it. After user-approved UAC, both mouhid mice read vertical=1/horizontal=0. The user confirms natural direction in Windows and working LoL camera zoom. No per-game exception or game process modification was added.
- Command+H minimizes with the native API; the user previously confirmed minimize.
  The shared Win-menu mask and Command+Option+arrow mapping pass portable checks;
  the user confirms minimize without Start, bare Command opening Start and browser tab switching.
- Native DDC/CI mode successfully reads back the current 70% on the selected
  physical iiyama output. The driver returns a zero opaque physical-monitor token;
  successful enumeration and valid native query establish usability. Original
  physical brightness 100 is stored in a hardware recovery lease. Normal software
  mode rollback was also observed when the initial nonzero-token guard rejected
  that token. The user confirms cursor dimming and responsive slider/function keys. Normal update restoration to original backlight and restart at the saved 55% also pass; sleep/wake and abrupt-crash watchdog checks remain. no cursor bitmap/theme substitution occurs.
- Apple's RussianA.dll, BritishA.dll and USA.dll are installed in System32 and
  Authenticode reports valid signatures. Native InstallLayoutOrTip successfully
  enables `0419:A0000419` and `0809:A0000809`, confirmed through the Windows language
  profile API (Windows PowerShell 5.1). Preload keeps standard IDs and Substitutes
  maps them to Apple layouts; a Preload-only check does not establish actual layout.
  The scoped recorded standard profiles are backed up in apple-layouts-backup.json.
  The user physically confirms expected punctuation and Ctrl+Space with those profiles.
- Native Boot Camp inventory reports Apple Inc. MacPro6,1, physical AMD FirePro D700
  driver 27.20.14540.15002, Broadcom/Apple devices and Windows problem codes.
  Virtual display devices are excluded. No driver was updated from this inventory,
  and no "latest compatible" claim is made.
- Short counter samples and their limits are recorded in Performance.md. CPU/RSS
  timing improvements, universal macOS feel and weakest-hardware support are not
  inferred from compilation or uncontrolled short samples.

The requirement-by-requirement audit and remaining work are in Requirements.md.

## Previously verified 0.1.2 behavior

Local validation on Windows 10 x64, Boot Camp MacPro6,1, 2026-10-06:

- 12 KeyboardCore and 14 BrightnessCore tests pass.
- Native ABI, bounded storage / argument escaping, language pack validation and
  all nine settings pages pass. English and Russian pages, native checkbox clicks,
  tile navigation and brightness slider synchronization are checked in the app.
- The user previously confirmed physical Ctrl+Space and Command/Win+Tab behavior.
- The signed Apple USB Precision Trackpad 6.1.8000.6 was installed on the connected
  Lightning PID 0265, replacing Apple Multi-Touch Pro 6.1.7800.2. Windows reports
  problem code 0. Both USB and Bluetooth packages are staged; the original USB
  driver was exported before rebinding. No restart was requested by the installer.
- The user confirmed two-finger scrolling, pinch-to-zoom and three-finger window
  switching on that USB connection after the driver installation.
- Two Bluetooth pairing attempts succeeded initially but delivered no input. The
  user confirmed the device disappeared without manual removal. System events
  show BTHUSB 8 (paired), HidBth 4 (initial HID connection failed) and BTHUSB 10
  (pairing key removed). SetupAPI selected Apple Bluetooth Precision 6.1.8000.6
  and DeviceAssociationService subsequently removed the device nodes. This
  identifies the failing connection phase, not the underlying driver/radio cause.
- The repair selector passes a read-only regression: exact pinned Bluetooth INF
  matching, exclusion of working USB and unrelated Apple radio packages, protection of another Apple
  trackpad using a Precision package, and rejection of missing verified packages.
  On this machine the selector chooses only oem2.inf. After the user approved
  Windows UAC, that package was exported and removed successfully. oem6.inf
  (working USB) and oem0.inf (radio) remain. The protected result is
  PairingRepairPrepared with RestartRequired true. After Windows Restart, the
  user paired it again and confirmed basic Bluetooth pointer / click input.
  Windows selected the original Apple Multi-Touch Pro 6.1.7800.2 for that test.
- The signed Precision Bluetooth package was then installed on the existing
  working pair, without removing the pair or attaching USB. Windows reports
  Apple Bluetooth Precision Trackpad 6.1.8000.6 and HID-compliant touch pad,
  both OK; the installer requested no restart. The user confirmed all three
  wireless gestures, smoothness matching USB and automatic off/on reconnect
  with pointer and gestures restored while keeping the Bluetooth pair.

Longer Bluetooth sleep/wake and the updated application's appearance
still require interactive validation. USB-C and
original Magic Trackpad are not tested. No macOS-equivalent feel or all-model
support is claimed from these checks.
The 0.1.1 preview exposes the dashboard and its feature buttons in UI Automation.
Windows.Graphics.Capture times out, so a visual screenshot review is not claimed.

The local 0.1.0 resident became unresponsive before its upgrade. Its normal exit
timed out; stopping the resident left one terminating Windows thread, while its
watchdog remained waiting for process exit. The upgrade correctly refused to
overwrite a running executable. The watchdog and recovery lease were retained.
This snapshot does not identify the cause of that system wait or claim that the
new UI changes fix it. The user tried Windows+Ctrl+Shift+B; the pending thread
remained. Windows Restart released the old processes. The prepared per-user update
then exposed an installer bug: Windows PowerShell 5.1 terminated when the optional
BrightnessCtl Run value was absent, despite Get-ItemPropertyValue's error preference.
The installer now reads that optional property from Get-ItemProperty. Replaying
the actual update succeeds: 0.1.1 runs with dedicated input active, original output
color recovery completes, normal startup is enabled, and the temporary update task
is removed. Saved brightness (75%) and configuration are retained. The settings
window opens through the normal installed executable's settings command.

The user then reported 0.1.1 freezing while changing settings. A local native stack
walk and an unmodified-build linker map locate the UI wait in reloadRemapper and
the input worker in scrollingCallback / SendInput. The worker stayed in a nested
SendInput callback while the UI was not servicing sent Windows messages. WCT alone
did not report a cycle because the join event has no thread owner.

0.1.2 defers wheel injection until the low-level callback returns, bypasses
reentrant injection and joins with MsgWaitForMultipleObjectsEx / QS_SENDMESSAGE,
without dispatching queued clicks or timers. A 5-second deadline does not permit
replacing a still-running worker; one-worker ownership and generation checks
preserve the shared callback-state lifetime.

The native regression reproduces the missing sent reply with the old blocking
wait, verifies sent replies with the new wait, preserves queued UI commands,
checks the deadline, rejects overlapping workers and repeats real worker shutdown.
ABI, storage and all nine English/Russian native pages also pass on 0.1.2.
The old 0.1.1 process did not answer normal exit, and after stopping it Windows
retained one thread inside the input system call. The watchdog and recovery lease
were preserved until Windows Restart. The prepared update then installed 0.1.2,
restored output color, enabled normal startup, opened settings and removed its
temporary update task. The installed executable matches the tested release hash.

After that restart the user confirmed automatic startup and that everything works,
in response to the request to toggle wheel inversion and save keyboard / language
settings without freezing. The resident responds to CLI queries, and its log also
records a normal shutdown with output restoration. There is one resident and its
watchdog. The user's current saved brightness is 55%; configuration remains intact.
This validates the reported settings freeze fix on this hardware; it does not
prove that every possible configuration or Windows system has been tested.
# 0.1.5 release verification

This snapshot separates automated checks, earlier physical confirmation and current
hardware availability. It does not claim every device/model or configuration works.

| Feature | Verified evidence | Limit |
| --- | --- | --- |
| Brightness, calibration and recovery | 15 portable brightness/storage tests; native storage/ABI checks; earlier user confirmed hardware-cursor dimming and responsive controls | Current session has only an active virtual streaming display; the saved physical output is disconnected and brightness is intentionally unavailable |
| Mac keyboard/input languages | 14 portable keyboard tests; native input/profile checks; earlier user confirmed Ctrl+Space, held Command+Tab, Command+H without Start, bare Command and browser tab shortcuts | Physical behavior was confirmed before this error-handling change; remapping behavior is unchanged |
| Natural mouse scrolling | Native registry/scope tests; current device flags remain vertical=1/horizontal=0; earlier Windows direction and game zoom confirmed | Vendor/injected wheels remain outside mouhid |
| Magic Trackpad | Native matching and scoped repair-selection tests; existing driver status reads successfully; earlier USB/Bluetooth gestures and reconnection confirmed | Lightning model validated; other models and long sleep/wake remain untested |
| Settings/localization | All 10 English/Russian pages, native controls, selector readiness and worker-wait regression pass | Tests use this app's own controls |
| Windows errors | Win32/HRESULT explanations and recovery hints pass native checks | Unknown/vendor-specific errors retain their diagnostic code |
| WSL/Homebrew | Native package/registry/VM-mode and boot-failure precedence checks; current Hyper-V VMX failure correctly reported | End-to-end Linux account/Homebrew installation is deferred on this firmware-blocked test host |
| Desktop utilities | Native implementation retained; existing control/action paths build and settings validate | Pin/awake duration behavior is not newly physically exercised in this snapshot |

The error-fix executable is below the 6.5 MB budget, links the official Swift
runtime statically and restricts static DLL imports to System32. No firmware,
EFI configuration or driver binding was changed during error diagnosis.
