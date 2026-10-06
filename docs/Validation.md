# Validation snapshot: 0.1.3

2026-10-06 update on the same MacPro6,1 / Windows 10 build 19045:

- 14 KeyboardCore and 15 BrightnessCore tests pass. Native ABI, storage/recovery,
  mouse registry scope, input-profile API resolution, Boot Camp ID matching,
  bounded sent-message worker waits and all 10 English/Russian settings pages pass.
- The current prepared executable is 6,411,264 bytes, SHA-256
  `65729E124718E38B309AF4EDD97AC04086A41F5351E7E8354C8BE18AA45342E8`.
  It links Swift statically and verifies System32-only static DLL import resolution.
  Its Apple-layout GUI integration is prepared; the resident's preceding build is
  retained while the native mouse UAC prompt is pending.
- Software wheel interception/injection is absent. The user previously confirmed
  LoL zoom returned after disabling it. Native direction is not yet applied:
  current mouhid device values are vertical=0/horizontal=0; the UAC prompt awaits
  user consent. No per-game exception or game process modification was added.
- Command+H minimizes with the native API; the user previously confirmed minimize.
  The shared Win-menu mask and Command+Option+arrow mapping pass portable checks;
  physical Start/menu/browser verification is pending.
- Native DDC/CI mode successfully reads back the current 70% on the selected
  physical iiyama output. The driver returns a zero opaque physical-monitor token;
  successful enumeration and valid native query establish usability. Original
  physical brightness 100 is stored in a hardware recovery lease. Normal software
  mode rollback was also observed when the initial nonzero-token guard rejected
  that token. Cursor appearance/slider feel, sleep/wake and hardware-watchdog
  recovery still need physical validation; no cursor bitmap/theme substitution occurs.
- Apple's RussianA.dll, BritishA.dll and USA.dll are installed in System32 and
  Authenticode reports valid signatures. Native InstallLayoutOrTip successfully
  enables `0419:A0000419` and `0809:A0000809`, confirmed through the Windows language
  profile API (Windows PowerShell 5.1). Preload keeps standard IDs and Substitutes
  maps them to Apple layouts; a Preload-only check does not establish actual layout.
  The scoped recorded standard profiles are backed up in apple-layouts-backup.json.
  Physical punctuation and Ctrl+Space with those profiles remain to be checked.
- Native Boot Camp inventory reports Apple Inc. MacPro6,1, physical AMD FirePro D700
  driver 27.20.14540.15002, Broadcom/Apple devices and Windows problem codes.
  Virtual display devices are excluded. No driver was updated from this inventory,
  and no "latest compatible" claim is made.
- Axiom 27.3.0 and Xcode Build Skills 1.0.1 are verified enabled through marketplaces
  in local Codex and Claude on Windows and Mac Studio. Newly copied Xcode skill
  duplicates were backed up and removed from loose skill discovery. Existing
  instructions/plugins are retained; shared/host optimization preferences are saved.
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
