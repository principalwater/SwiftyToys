# Validation snapshot: 0.1.1

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
  both OK; the installer requested no restart. Wireless gesture / smoothness
  and reconnect testing remain pending.

Bluetooth recovery / reconnect / smoothness and the updated application's appearance
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
