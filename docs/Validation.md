# Validation snapshot: 0.1.6

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
