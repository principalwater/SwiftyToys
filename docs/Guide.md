# SwiftyToys user and developer guide

Native **Swift 6.4** Windows tools with familiar Mac keyboard habits and a coherent
settings window. MIT licensed. Inspired by and complementary to
[Microsoft PowerToys](https://github.com/microsoft/PowerToys), especially for Mac,
Boot Camp and former macOS users. Independent project, not affiliated with Microsoft
or Apple.

**Think Different. On Windows.** By [principalwater](https://github.com/principalwater).

## Features

- **Search:** Cmd+Space opens the native panel with the Mac preset. Apps, files,
  indexed content, calculator, units, dated reference rates, supported world clocks,
  actions and previews work without a model. Semantic search is an explicit
  download, persistent local-drive indexing and optional audio/video encoders.
  Choose scope, exclusions and compatible models in settings.
  [Controls, sources, licenses and scope](Search.md).

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
  previous method. Software methods may leave native cursors brighter.
  Native WDDM gamma and AMD gain preserve the original calibration without copying
  the desktop or running a frame timer. The Magnification renderer is removed after
  freeze reports; saved `compositor` preferences migrate to Automatic while retaining
  the DDC switch and brightness level. Windows retains native cursor rendering.
  Legacy composition/cursor-owning leases remain recoverable.
  Selecting a replacement display preserves a disconnected monitor's calibration
  separately, so it cannot block the new output. Reconnecting the original monitor
  restores its own calibration; connected-display failures still retain recovery.
  Apple Thunderbolt Display (A1407) over direct Thunderbolt was checked with hardware
  brightness enabled: the native Windows monitor API controls its 16-bit backlight,
  with matching USB HID readback. The tested connection needs no additional Apple
  display driver. This does not establish support for other Apple display models.
  **Ambient-light sensor (monitor setting)** in Brightness and the tray controls the
  Thunderbolt Display's ambient-light enable setting while hardware brightness is on.
  Windows VCP 0x66 verifies only the enabled/disabled state. Actual automatic
  adjustment is not working on the tested Windows connection; this switch does not
  establish a functioning sensor loop. SwiftyToys adds no guessed sensor commands or
  polling loop. The current sensor mode is preserved until explicitly changed;
  a saved choice applies only to that display. Quit/recovery restores its original
  backlight and sensor mode. Unsupported outputs and software mode disable the switch.
  **Color profile** reads the effective SDR profile directly from Windows. Import an
  original ICC/ICM monitor RGB profile, select it and choose **Apply profile**. Import
  requires administrator approval; the original bytes are validated and copied under
  a content-addressed name without replacing another profile. The association applies
  to this display and current user. It overrides system defaults until **Use Windows
  system default** is applied. Windows initializes the user association list from the
  system list when that override is first enabled. Refresh, returning to the window
  and native registry notifications read Windows again; no second profile preference
  is stored by SwiftyToys. The registry wait exists only while the Brightness page is
  visible and has no polling timer. Profile changes release an old software
  brightness/calibration lease before capturing a new baseline; hardware brightness
  stays unchanged. No calibration LUT is loaded by this feature.
  ICC profiles affect color-managed apps; they do not make every Windows game use
  color management. Unit-specific profiles and diagnostics are never bundled.
  Ctrl+Alt+Shift+F10 requests 100% for emergency restoration. F1/F2 hold repetition
  follows Windows keyboard delay/speed; release, focus, device, session and power
  changes cancel repetition. No mouse-wheel interception is added.
- **Keyboard:** editable Mac preset, key/shortcut/action remapping, per-application
  rules/exclusions and pause. Ctrl+Space switches configured layouts; Command/Win+Tab
  cycles windows; Command editing/search/screenshot shortcuts and Option word navigation.
  Command/Win+H minimizes the active application window with the native Windows API.
  Command+Ctrl+Q locks the session; Command+Ctrl+S requests Sleep through Windows.
  Both actions are editable in the keyboard page. Sleep uses the account's existing
  shutdown permission, preserves wake events and does not change the power plan.
  If Windows exposes neither S1/S2/S3 nor Modern Standby, Sleep shows recovery
  instructions instead of requesting an unsupported transition. `powercfg /a`
  explains system availability; firmware, drivers and boot configuration determine
  the states Windows can use. Hibernate is not silently used as a substitute.
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

Windows 10 22H2 / Windows 11 x64. Open the release's `win-x64-Setup.exe` and choose
**Install**. The native Swift installer installs for the current Windows account,
sets the shortcut's fixed icon and application identity before launch, and enables
automatic startup. Reinstallation preserves settings. No Swift compiler or
PowerShell installer is required. Windows may show a reputation warning for an
unsigned release; obtain the EXE from this project's Releases and verify its checksum.
If the Microsoft Visual C++ Runtime is missing or older than 14.44.35211, setup offers
the pinned, signed official Microsoft installer. This separate prerequisite needs
internet access and Windows administrator consent; ordinary installation does not.
WSL and driver installation separately request administrator consent and may
need a restart. No restart is automatic.
The official Swift runtime is linked into one executable; additional dependencies
are added only for required functionality or measured improvements.

For the optional portable ZIP, extract the complete archive outside the installed
application folder and run `SwiftyToys.exe --installer`. This route requires the
Microsoft Visual C++ x64 Redistributable to be installed already. Keep documentation,
licenses, language packs and resources together with the executable.
For automated installation, pass `--install` to the setup EXE. It shows native
progress, closes after success and retains the same prerequisite, rollback and
recovery checks; it does not silently approve administrator prompts.

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
