# SwiftyToys user and developer guide

Native **Swift 6.4** Windows tools with familiar Mac keyboard habits and a coherent
settings window. MIT licensed. Inspired by and complementary to
[Microsoft PowerToys](https://github.com/microsoft/PowerToys), especially for Mac,
Boot Camp and former macOS users. Independent project, not affiliated with Microsoft
or Apple.

**Think Different. On Windows.** By [principalwater](https://github.com/principalwater).

## Features

- **Brightness:** BrightnessCtl 0.5.3 Swift code is integrated directly: native WDDM
  scanout brightness, AMD fallback, monitor selection, slider, calibrated recovery,
  watchdog, function keys/HID, custom/system OSD, configurable shortcuts and explicit
  DDC/CI hardware control. One independent physical SDR output; HDR/clones/virtual
  outputs are excluded. Fullscreen/color-calibration tools can compete for the output.
  Optional native DDC/CI hardware mode dims the entire physical monitor, including
  hardware/app-defined cursors, without changing cursor themes or animation. It
  requires a compatible monitor, verifies readback and retains watchdog recovery.
  Hardware brightness (DDC/CI) is an explicit switch. Off uses only software dimming;
  leaving DDC restores the original backlight once. The old maximum-backlight worker
  is removed. Conflicting legacy maximum=on + hardware preferences migrate to software.
  Failed disables stay off and preserve pending recovery; failed enables keep the
  previous method. Software dimming may leave hardware cursors brighter.
- **Keyboard:** editable Mac preset, key/shortcut/action remapping, per-application
  rules/exclusions and pause. Ctrl+Space switches configured layouts; Command/Win+Tab
  cycles windows; Command editing/search/screenshot shortcuts and Option word navigation.
  Command/Win+H minimizes the active application window with the native Windows API.
  Command+Ctrl+Q locks the session; Command+Ctrl+S requests Sleep through Windows.
  Both actions are editable in the keyboard page. Sleep uses the account's existing
  shutdown permission, preserves wake events and does not change the power plan.
  Command+Option+Left/Right maps to Ctrl+PageUp/PageDown for browser tabs. A shared
  Ctrl menu-mask pulse keeps mapped Command chords from opening Start; bare Command
  retains the Windows Start action.
  Apple layouts use Windows/Boot Camp installation; Apple DLLs are not redistributed.
- **Apple layout selection:** Input languages → Use Apple RU + EN enables installed
  signed Boot Camp Russian and US/UK Apple layout DLLs through Windows
  InstallLayoutOrTip. Only the standard RU/US/UK profiles are replaced; other
  layouts/IMEs remain. The original profiles have a local recovery backup.
- **Input languages:** cycle, Latin/non-Latin or a selected pair. Optional Mac-style
  Caps Lock tap/hold, configurable tap action and 150–800 ms hold threshold. Shift+Caps
  and CJK IME pass through; when Caps is already on, a tap turns it off.
- **Mouse:** native physical wheel direction for connected Windows mouhid mice,
  vertical/horizontal independently. Swift calls SetupAPI and device registry APIs;
  the mouse wheel is never intercepted or recreated with SendInput. Applying requires
  Windows UAC and may briefly reconnect the mouse. Direction applies to all apps,
  games and modifier-wheel commands; keyboard app exclusions do not change it.
  Precision Touchpads retain their own Windows gesture/scroll settings. Native input
  delta magnitude/resolution are preserved; direction changes their sign. Application
  rendering and inertia remain application-owned. Settings persist for the physical
  device and all Windows users after SwiftyToys exits; apply again for a new mouse.
  Virtual/injected wheels and vendor-specific drivers retain their own behavior.
- **Desktop:** Command+H minimizes, Command+Ctrl+T pins the active window; temporary keep-awake with optional
  display-on. Saved power-plan settings are preserved.
- **Magic Trackpad 2:** detect USB/Bluetooth connections, install separately downloaded
  signed Precision Touchpad drivers, retain recovery backups, and open native Windows
  gesture / Bluetooth controls. Apple Boot Camp is the default on Apple computers;
  the optional open-source package has experimental Bluetooth support. See
  [supported hardware, limitations and licenses](Trackpad.md).
- **Homebrew:** detect WSL distributions, install WSL + Ubuntu, open the official
  interactive installer inside a selected WSL 2 distribution and configure Bash shellenv.
  Homebrew runs in Linux; sudo/account setup remain in the user's terminal.
- **Native UI:** feature tiles, Overview / Esc back navigation, standard accessible controls, Tab navigation,
  per-monitor DPI and embedded Common Controls v6 manifest. No web renderer.
- **Languages:** English by default, runtime selection in About, external UTF-8 JSON
  language packs with English fallback. Russian is included as an example translation.
  [Add a translation](Localization.md) without rebuilding the application.
- **Boot Camp:** native read-only model/driver inventory with hardware IDs, installed
  versions/INF and Windows device problems, plus Windows Update / Device Manager.
  Installed metadata is not proof of signatures or the latest compatible package.

## Installation

Windows 10 22H2 / Windows 11 x64, Microsoft Visual C++ 2015-2022 x64 Redistributable.
Extract the ZIP and run install.ps1 with PowerShell. Installation is per user;
WSL and driver installation separately request Windows administrator consent and may
need a restart. No Swift compiler required.
The official Swift runtime is linked into one executable; additional dependencies
are added only for required functionality or measured improvements.

Click the tray icon to open settings. Closing settings leaves the utility active.
Quit in the tray menu restores the output and stops the tools. Keep only one remapper
for the same shortcuts. Normal-user injection cannot control elevated applications or
secure desktop. AltGr and foreign injected events are preserved. Unlisted shortcuts
pass through. The Mac preset replaces the listed Windows meanings (including Win+arrow
Snap and Win+Space); edit/delete any rule to restore them. Applications can reject a
native layout request.

Existing BrightnessCtl configuration/brightness are copied after its resident and
watchdog finish restoration. Its startup is disabled only after SwiftyToys starts.
The old installation is retained for rollback. Both apps share a display ownership
mutex to prevent capturing an already dimmed baseline.

## CLI

```text
SwiftyToys.exe settings
SwiftyToys.exe 75
SwiftyToys.exe +5
SwiftyToys.exe get
SwiftyToys.exe info
SwiftyToys.exe --trackpad-info
SwiftyToys.exe --driver-info
SwiftyToys.exe --mouse-info
SwiftyToys.exe --hardware-info
SwiftyToys.exe --wsl-info
SwiftyToys.exe --apple-layouts uk
SwiftyToys.exe --restore-apple-layouts
SwiftyToys.exe backend hardware
SwiftyToys.exe backend auto
SwiftyToys.exe list
SwiftyToys.exe select <output-id>
SwiftyToys.exe osd custom
SwiftyToys.exe osd system
SwiftyToys.exe rescan
SwiftyToys.exe exit
SwiftyToys.exe --preview
```

Settings: %LOCALAPPDATA%\SwiftyToys. The preview disables application actions and
never captures a display or attaches input hooks. Keyboard rules are source,
destination, optional executable name. Destinations also accept Switch language,
Pin window, Minimize window, Lock screen, Sleep and Disable key. Up to 64 rules and 32 application exclusions. No script
or arbitrary process commands execute from keyboard rules.

## Homebrew

The setup page distinguishes installed Windows packages from registered Linux.
Choose **Install WSL components** for the elevated Windows setup and restart if
requested. Then choose **Install Ubuntu** to install Linux for the current Windows
user. Choose **Open Linux setup**, create your Linux user/password in Ubuntu's
terminal, then choose **Refresh list**.
Installation output remains visible until a key is pressed; launching an installer
does not imply that WSL or a Linux account is ready. Linux first launch runs as the
current Windows user, separately from the elevated Windows component installation.
The WSL 1/2 indicator reads the VM-mode flag, not the Lxss filesystem-format Version.
If Hyper-V reports that VMX is disabled/unavailable during the current boot, the
page explains the firmware/boot configuration requirement. A background worker reads
Windows Event Log once per settings session; Refresh reads packages and registration.
Unavailable boot diagnostics do not hide installed packages or prevent setup.
Diagnostics do not start Linux or change firmware. WSL 2 still needs
working hardware virtualization; having Windows packages installed is insufficient.

Use initialized WSL 2 distributions. Ubuntu/Debian prerequisites can be installed
with apt; other distributions need their package-manager prerequisites first.
The standard prefix is /home/linuxbrew/.linuxbrew. Bash shellenv is added once;
other shells need their own shellenv setup. Windows applications remain managed by
Windows tools such as winget. See [official installation](https://docs.brew.sh/Installation)
and [Homebrew on Linux/WSL](https://docs.brew.sh/Homebrew-on-Linux).

## Build and checks

```powershell
./scripts/build.ps1
./scripts/test.ps1
./artifacts/SwiftyToys.exe --abi-check
./artifacts/SwiftyToys.exe --test-storage
./artifacts/SwiftyToys.exe --test-ui
./artifacts/SwiftyToys.exe --test-brightness-policy
./artifacts/SwiftyToys.exe --test-display-queue
./scripts/package.ps1
```

Official Swift 6.4 Windows toolchain, MSVC and Windows SDK. Hardware-independent
BrightnessCore/KeyboardCore tests use Swift Testing. Native interop is header-only,
without a custom C/C++ application runtime. Build checks runtime DLL dependencies
and System32-only static DLL import resolution
and embeds the UI manifest. See [packaging](Packaging.md) and
[interop](WindowsInterop.md). No performance advantage over PowerToys is claimed
without a reproducible benchmark. Driver and keyboard work use dedicated threads;
the settings window shares the tray UI thread. Driver updates and device reports
run asynchronously; brightness requests coalesce to the latest level. The fixed
header and clipped viewport preserve drafts, focus and scrolling between pages.
High-contrast colours and per-monitor DPI are supported; no animation timer is used.
See [requirements and remaining acceptance checks](Requirements.md) and
[measurement protocol](Performance.md).

## Credits

[BrightnessCtl](https://github.com/principalwater/BrightnessCtl) supplies the display
control/recovery source; its Git history and MIT copyright are retained.
[PowerToys](https://github.com/microsoft/PowerToys) inspired the settings/tool model.
See [third-party notices](../THIRD_PARTY_NOTICES.md).
