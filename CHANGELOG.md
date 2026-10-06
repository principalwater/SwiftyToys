# Changelog

## SwiftyToys 0.1.4 — 2026-10-06

- Distinguish installed WSL/Ubuntu packages, a pending Windows restart and Ubuntu's
  first launch from registered Linux distributions. Refresh reads native metadata.
- Keep WSL installation diagnostics visible until a key is pressed. Separate the
  elevated Windows component setup from current-user Ubuntu installation/first launch.
- Read the WSL VM-mode flag rather than the Lxss filesystem-format Version; keep
  missing/invalid mode metadata unavailable rather than assuming WSL 2.
- Enable Homebrew only for a selected WSL 2 distribution; verify its actual Linux
  user before installing prerequisites or Homebrew, respecting wsl.conf defaults.
  Render disabled native buttons with the system disabled-text color.
- Resolve WSL and driver-installer command executables from System32. Preserve
  keyboard focus after refreshing native setup/device pages.

## SwiftyToys 0.1.3 — 2026-10-06

- Replace synthetic mouse-wheel inversion with native Windows physical HID direction.
  Remove WH_MOUSE_LL, mouse SendInput and the wheel injection queue entirely.
- Apply through Swift SetupAPI / registry calls with native device restart, bounded
  DWORD validation, previous-value rollback and background UAC completion. No mouse
  configuration scripts, extra drivers or per-game compatibility exceptions.
- Add Apply native scrolling; the setting includes modifier-wheel commands and persists
  per device. New mice need another Apply; unsupported vendor drivers keep their settings.
- Preserve Magic Trackpad's verified Precision scrolling / gesture implementation.
- Add Command/Win+H → native minimize window, editable in the Mac keyboard profile;
  extend the unchanged previous Mac preset while preserving custom profiles.
- Mask the Windows menu for mapped Command chords while preserving bare Win; add
  Command+Option+Left/Right → Ctrl+PageUp/PageDown.
- Add optional native DDC/CI hardware brightness including the hardware cursor,
  readback, recovery lease/watchdog and transactional mode switching.
- Add native Boot Camp model/driver inventory, Windows Update and Device Manager.
- Show actual device direction values; skip unchanged writes/restarts, retain an
  in-progress native operation after timeout, and report ambiguous failure honestly.
- Restrict static DLL imports to System32; remove duplicate/unchanged tray updates,
  gate DDC reads and avoid eager keyboard-rule match allocations.
- Record the full conversation requirement ledger and reproducible process counters.
- Enable already installed Apple RU and US/UK layout profiles with native Windows
  input APIs, scoped standard-profile replacement and a recovery backup.

## SwiftyToys 0.1.2 — 2026-10-06

- Fix settings reload blocking the UI while the input worker is inside SendInput.
  Join with a bounded sent-message wait; retain a worker that has not stopped.
- Queue reversed-wheel injection after the low-level mouse callback returns and
  bypass reentrant wheel callbacks during injection.
- Reserve one input worker per process, retain its lifetime until shutdown and
  ignore stale failure notifications from an earlier generation.
- Add a native regression with a blocking-wait control, cross-thread sent replies,
  queued UI commands, timeout, overlap rejection and repeated worker shutdown.
- Add optional build LinkMap diagnostics without including maps in release ZIPs.

## SwiftyToys 0.1.1 — 2026-10-06

- Use an English-first feature tile dashboard, with keyboard-accessible native buttons.
- Fix themed checkbox background painting, false success messages and repeated layout
  invalidation; apply wheel inversion directly when its checkbox changes.
- Keep the brightness slider synchronized with hotkeys and throttle continuous dragging.
- Add runtime language selection, bounded UTF-8 JSON packs and English fallback.
- Add Magic Trackpad 2 detection, signed upstream USB/Bluetooth driver installation,
  protected recovery backups, rollback, native gesture settings and Bluetooth pairing links.
- Add scoped Apple Bluetooth pairing recovery: export the exact pinned Bluetooth package,
  preserve other Apple devices, and guide restart / pairing before driver installation.
- Credit principalwater, Apple inspiration and Microsoft PowerToys in About.
- Fix migration when the retained BrightnessCtl executable has no startup registry value.

## SwiftyToys 0.1.0 — 2026-10-05

- Integrate BrightnessCtl 0.5.3 Swift display code directly, with its recovery/watchdog.
- Add a native settings window: brightness slider/output/settings, editable Mac keyboard
  mappings, per-application rules/exclusions, pause, desktop tools and Homebrew in WSL 2.
- Add direct Ctrl+Space layout requests and retained-modifier Command+Tab remapping.
- Add Mac editing/navigation/search/screenshot presets, with individual customization.
- Add configurable language cycles/pairs, optional Caps Lock tap/hold and natural wheel
  direction (vertical/horizontal, precise deltas, modifier and application exceptions).
- Preserve BrightnessCtl configuration during migration and share its ownership mutex.
- Embed Common Controls v6/DPI manifest; keep the official Swift runtime static.

## BrightnessCtl history (upstream baseline)

The following entries describe the inherited BrightnessCtl releases and their
measurements, not SwiftyToys benchmark results.

## 0.5.3 — 2026-10-05

- Prevent the Windows brightness flyout from slipping through while the tray UI
  is busy. Observe Shell triggers and show events on an independent Win32 thread,
  and hide recognized brightness windows without additional asynchronous queue hops.
- Pre-clip recognized, unshaped Shell hosts using native window regions so their
  first frame cannot flash. Process brightness HID input on the observer before
  queueing display work; restore the region for volume/media and system mode.
- Restore owned window regions on exit, watchdog recovery and the next start.
  Window properties identify the exact process lifetime; existing shapes and
  unrelated windows are preserved. Shaped hosts retain the scoped hide fallback.
- Add a native flyout regression check covering blocked UI, delayed shows, media
  cancellation and indicator mode changes. Preserve brightness and monitor settings.
- Keep the custom OSD at its final position during repeated updates. Move it for
  a monitor/DPI change only while hidden, preventing a top-left corner flash.

## 0.5.2

- Reduce the portable ZIP from 23.6 MB to approximately 2.3 MB. Link the official
  Swift runtime statically into one executable; remove Foundation and ICU dependencies.
- Use CRT-initialized native threads, kernel-event executor wakeups, CreateProcessW
  watchdog startup, ordinal Windows name comparisons and native file I/O.
- Preserve the existing JSON status/recovery schemas with exact integer decoding,
  bounded reads, strict UTF-8, duplicate-key checks and atomic file replacement.
- Add Foundation compatibility tests and native storage self-tests. Retain output
  selection, 5% steps, indicator settings, calibration recovery and capture behavior.
- Remove only previously installed runtime DLLs listed in the old installation manifest.


## 0.5.1 — 2026-10-05

- Add an immediately applied, persistent indicator choice in the tray menu and
  CLI (`osd custom|system`). The default remains SwiftyToys's custom indicator.
- System mode removes the duplicate SwiftyToys OSD when hardware keys already
  trigger a Windows/OEM indicator. Existing input, software brightness and DDC
  behavior are preserved. This mode does not synthesize or set a system indicator.
- Custom mode suppresses recognized Windows Shell brightness flyouts after a
  brightness event; volume/media events cancel suppression. Unknown hosts remain
  untouched. This is a compatibility path using optional internal Shell signatures.

## 0.5.0 — 2026-10-05

- Rewrite all application behavior in Swift 6.4: Win32 tray/OSD, dedicated keyboard
  thread, native HID parser, persistence and watchdog recovery.
- Discover GPU-independent Windows display paths; prefer native WDDM scanout gamma
  and retain AMD RGB gain as a fallback. Exclude virtual, cloned and HDR outputs.
- Preserve stable selection and pending calibration recovery. Restore through the
  existing owner before rescan/shutdown, and retry temporarily unavailable drivers.
- Use native Task Scheduler COM, executable validation and per-user startup tasks.
- Bundle required Swift runtimes and licenses; omit developer debug information.
- Preserve current brightness, 5% steps and selected-monitor DDC maximum.

## 0.1.1

- Run the F1/F2 keyboard hook on a dedicated message thread, keeping it responsive
  during slow display-driver calls, UI work and modal dialogs. Brightness work is
  posted to the resident window; modified F1/F2 shortcuts remain available.
- Rearm the hook on its own thread and log installation/message-loop failures.
- Start the installed resident through its matching interactive scheduled task
  from the installer and CLI, keeping it independent of the invoking shell.
- Keep existing brightness, 5% steps and physical-output dimming behavior.

## 0.1

First public release; numbering starts at 0.1 for the public project.

- Per-physical-output AMD RGB gain and 5% configurable brightness steps.
- Explicit connector selection, single-output discovery and disconnection handling.
- Selected-monitor DDC maximum, tray controls, OSD, CLI and local state recovery.
- Opt-in F1/F2 interception; no baked-in monitor model or Windows user paths.
- Modular source, repeatable build/package scripts, hardware-independent tests and CI.
- MIT license and provenance/third-party notices.
