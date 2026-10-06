# Product requirements and validation

Requirements review, 2026-10-06. This ledger distinguishes implementation from
physical validation. A source change is not an installed fix.

| Requirement or reported finding | Evidence and current status | Remaining acceptance check |
| --- | --- | --- |
| Open-source SwiftyToys, inspired by and complementary to PowerToys for Mac users | MIT repository, credits and third-party notices; independent branding | Keep credits and licenses in every package |
| Integrate all BrightnessCtl functionality directly | Swift display control, AMD fallback, calibration, selection, HID/function keys, OSD, recovery and watchdog integrated; migration retains rollback | Regression checks whenever display/recovery code changes |
| Apple Russian/English layouts, native installation | Installed signed Apple RU/US/UK DLLs verified; native API applied Apple RU/UK, confirmed in Windows profiles/Substitutes and physically by the user | Preserve scoped recovery and US/UK choice in GUI |
| Ctrl+Space input language switching | Physically confirmed by the user | Preserve configured pair/cycle, AltGr and IME behavior |
| Command/Win+Tab with held Command | Physically confirmed by the user | Preserve forward/reverse cycling after menu-mask changes |
| Editable remaps and switching settings in the GUI | Native rule editor, actions, application scope, pause/exclusions, smart Caps Lock and language mode | Keep settings responsive while saving/reloading |
| PowerToys-style feature tiles and attractive native UI | Tiles, sidebar, accessible common controls, DPI handling implemented | Screenshot capture failed; visual appearance is not independently verified |
| About: author GitHub, Apple inspiration, Think Different., ON WINDOWS | Implemented in About/sidebar and README | Preserve English branding and working links |
| English everywhere by default; extensible selectable language packs | English source/UI, external UTF-8 JSON with fallback; runtime selector and Russian example | Validate all pages/packs on each release |
| Convenient Homebrew installation | Official interactive installer in WSL 2; native package/registration discovery, visible installer diagnostics and current-user Linux setup entry point | End-to-end installation/account setup requires Windows restart when requested and the user's Linux account setup |
| WSL installation appears absent after Refresh / terminal closes | 0.1.4 distinguishes Windows packages, pending restart and Ubuntu first launch from registered distributions; installer output remains visible; WSL 1 selections cannot install Homebrew | Confirm registered WSL 2 and Linux user setup after the required Windows restart |
| More useful macOS habits | Pin window, temporary awake, Option navigation, editing/search/screenshot preset and smart Caps Lock implemented | Keep native behavior and editable shortcuts |
| Magic Trackpad research using popular projects and correct licenses | Trackpad.md records implementations, licenses and signing boundaries; no GPL driver code embedded into the MIT Swift application | Updated/all-model driver implementation remains an open requirement |
| Native Magic Trackpad USB gestures and smoothness | Signed Apple Precision 6.1.8000.6; user confirmed scroll, pinch, three-finger windows | Longer sleep/wake and four-finger checks |
| Equally functional Bluetooth trackpad, automatic reconnect | User confirmed all three gestures, USB-like smoothness, off/on reconnect without re-pairing | Longer sleep/wake, other radios and other models remain untested |
| Bluetooth pairing silently disappears / no input | Scoped verified BT-package recovery retained USB/radio; working pair restored, Precision driver subsequently installed | Never remove the working pair as routine maintenance |
| Original and USB-C Magic Trackpad support | Lightning PID 0265 validated; USB-C detected only; original unsupported | Separate compatible signed packages and physical tests for each model/transport |
| Inversion checkbox glitches / settings freezes | 0.1.2 fixes input-worker sent-message deadlock; user confirmed settings and automatic startup after restart | Retain bounded joins, singleton ownership and recovery lease |
| LoL wheel stops zooming; fix globally without game exceptions | Disabling software inversion restored zoom, physically confirmed. 0.1.3 removes all mouse hooks and mouse SendInput; native mouhid direction implementation built | Native vertical=1/horizontal=0 on both mice; user confirms natural Windows direction and working LoL zoom |
| Restore natural direction in Windows too | Native vertical inversion applied with approved Windows UAC; persisted device values and user test confirmed | Reapply only for newly enumerated mice |
| Preserve excellent trackpad/wheel smoothness | Precision pipeline left intact; native mouhid changes sign only, preserving delta magnitude/resolution | Compare physical feel; application inertia/rendering is still application-owned; virtual/injected wheels are outside mouhid |
| Cmd+H minimize | Native ShowWindowAsync implementation physically works | User confirms minimize without Start; bare Command opens Start |
| Cmd+H must not open Start; bare Cmd should open Start | Shared Win-key mask source updated; bare Win passes through | User physically confirms Cmd+H, bare Command and browser tab shortcuts |
| Cmd+Option+Left/Right switches browser tabs | Preset maps to Ctrl+PageUp/PageDown; legacy migration tested, installed | User physically confirms both tab directions |
| Cursor must dim with brightness | Optional native DDC/CI mode implemented/installed; hardware reads back 70%, original backlight persisted for watchdog recovery | User confirms cursor dimming, responsive slider/keys; normal update restoration verified. Sleep/wake and abrupt crash recovery checks remain |
| Native Swift and documented Windows APIs, small package | Swift runtime/core and Win32 UI, header-only ABI; no web renderer or mouse synthesis | Existing driver installer still uses a signed-package PowerShell orchestration script; strict Swift-only conversion is not complete |
| Old Mac Pro 6,1 Windows 10 Boot Camp optimization | -Osize, static runtime, dead stripping, no debug data/Swift DLLs, 6.5 MB executable budget | Measure CPU, memory, handles, startup and hook latency on MacPro6,1 before claiming an optimization; this 24-thread/64 GiB machine is not proof for the weakest hardware |
| Fresh compatible drivers for old Boot Camp Macs | Signed trackpad package and backups implemented | Native Boot Camp inventory and Windows Update / Device Manager entry points implemented/tested | Newest compatible package selection and model-specific physical validation remain open |

## Optimization acceptance

Record executable SHA-256/size, Windows build, hardware, driver versions and power
plan with every measurement. Measure the resident and watchdog separately; report
CPU time per wall-clock interval without hiding it behind 24-core normalization.
Record private bytes, working set, handles and thread counts. Compare identical
settings and workloads before/after; distinguish idle samples from startup, open
settings, physical input and game load. Never describe a short idle sample as a
latency, battery or low-end-machine benchmark.

The safe first optimizations are eliminating duplicate tray updates, checking the
DDC throttle before disk reads and avoiding unnecessary device writes/restarts.
Keep recovery, signature checks, calibration, input validation and accessibility.
No mouse filtering or input synthesis may be reintroduced to add smoothing.
Precision Touchpad scrolling remains owned by its native signed driver/Windows.

## Completion rule

Update this ledger and Validation.md with the tested executable hash and concrete
results. Pending physical checks and platform limitations must remain visible;
do not silently mark the broad all-model/macOS-equivalent request complete.
