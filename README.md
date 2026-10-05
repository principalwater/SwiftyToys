# SwiftyToys

Native **Swift 6.4** Windows tools with familiar Mac keyboard habits and a coherent
settings window. MIT licensed. Inspired by and complementary to
[Microsoft PowerToys](https://github.com/microsoft/PowerToys), especially for Mac,
Boot Camp and former macOS users. Independent project, not affiliated with Microsoft
or Apple.

## Features

- **Brightness:** BrightnessCtl 0.5.3 Swift code is integrated directly: native WDDM
  scanout brightness, AMD fallback, monitor selection, slider, calibrated recovery,
  watchdog, function keys/HID, custom/system OSD, configurable shortcuts and optional
  DDC maximum backlight. One independent physical SDR output; HDR/clones/virtual
  outputs are excluded. Fullscreen/color-calibration tools can compete for the output.
- **Keyboard:** editable Mac preset, key/shortcut/action remapping, per-application
  rules/exclusions and pause. Ctrl+Space switches configured layouts; Command/Win+Tab
  cycles windows; Command editing/search/screenshot shortcuts and Option word navigation.
  Apple layouts use Windows/Boot Camp installation; Apple DLLs are not redistributed.
- **Input languages:** cycle, Latin/non-Latin or a selected pair. Optional Mac-style
  Caps Lock tap/hold, configurable tap action and 150–800 ms hold threshold. Shift+Caps
  and CJK IME pass through; when Caps is already on, a tap turns it off.
- **Mouse:** optional natural wheel direction, vertical/horizontal independently,
  preserving precise wheel deltas and modified-wheel commands. This is a global
  fallback for Windows 10; Windows 11 users can open native mouse settings first.
  Devices which emit wheel events, including some touchpads, share the setting.
- **Desktop:** Command+Ctrl+T pins the active window; temporary keep-awake with optional
  display-on. Saved power-plan settings are preserved.
- **Homebrew:** detect WSL distributions, install WSL + Ubuntu, open the official
  interactive installer inside a selected WSL 2 distribution and configure Bash shellenv.
  Homebrew runs in Linux; sudo/account setup remain in the user's terminal.
- **Native UI:** sidebar/cards, standard accessible controls, Tab navigation,
  per-monitor DPI and embedded Common Controls v6 manifest. No web renderer.

## Installation

Windows 10 22H2 / Windows 11 x64, Microsoft Visual C++ 2015-2022 x64 Redistributable.
Extract the ZIP and run install.ps1 with PowerShell. Installation is per user;
WSL separately requests elevation and may need reboot. No Swift compiler required.
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
Pin window and Disable key. Up to 64 rules and 32 application exclusions. No script
or arbitrary process commands execute from keyboard rules.

## Homebrew

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
./scripts/package.ps1
```

Official Swift 6.4 Windows toolchain, MSVC and Windows SDK. Hardware-independent
BrightnessCore/KeyboardCore tests use Swift Testing. Native interop is header-only,
without a custom C/C++ application runtime. Build checks runtime DLL dependencies
and embeds the UI manifest. See [packaging](docs/Packaging.md) and
[interop](docs/WindowsInterop.md). No performance advantage over PowerToys is claimed
without a reproducible benchmark. Driver and keyboard work use dedicated threads;
the settings window currently shares the tray UI thread.

## Credits

[BrightnessCtl](https://github.com/principalwater/BrightnessCtl) supplies the display
control/recovery source; its Git history and MIT copyright are retained.
[PowerToys](https://github.com/microsoft/PowerToys) inspired the settings/tool model.
See [third-party notices](THIRD_PARTY_NOTICES.md).
