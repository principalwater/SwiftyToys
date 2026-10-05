# Apple Magic Trackpad

SwiftyToys coordinates Windows Precision Touchpad drivers and native settings.
It does not implement a kernel driver, simulate touch gestures as mouse movement,
or bundle another project's driver code. USB and Bluetooth are separate transports;
installing USB support does not prove wireless pairing or wireless input quality.

## Supported installer target

The current installer targets Lightning Magic Trackpad 2, Apple VID 05AC / PID 0265,
on Windows 10/11 x64. USB interface: `USB\VID_05AC&PID_0265&MI_01`. USB-C PID 0324 is
detected for status but is not installed by this version. Other architectures and
original Magic Trackpad are not supported by the installer.

On Apple computers, the default source is Apple's Boot Camp package from its HTTPS
CDN. The inspected package is Apple-signed and contains separate Microsoft-signed
USB / Bluetooth driver catalogs, version 6.1.8000.6 (2022-04-07), including PID 0265.
Only those driver folders are extracted; the full Boot Camp update never executes.
Apple licenses apply. Apple binaries are not redistributed in this MIT repository.
Apple's archive requires an already installed 7-Zip or WinRAR extractor.

The optional [imbushuo signed release 2105-3979](https://github.com/imbushuo/mac-precision-touchpad/releases/tag/2105-3979)
is downloaded separately from upstream. Its USB implementation uses UMDF; its
Bluetooth filter uses KMDF. Bluetooth support in that release is experimental and
upstream reports possible input lag or system crashes. The USB driver is GPLv2;
the SPI implementation's MIT license does not cover its USB code.

Every download is pinned by SHA-256, and catalogs must have valid Microsoft Hardware
Compatibility signatures. No INF/CAT modifications, test-signing, Secure Boot changes,
or trusted-root certificate imports are performed. Driver staging and backups are
admin-writable, user-readable under `%ProgramData%\SwiftyToys\Trackpad`.
Only the supported device hardware IDs are rebound. Existing drivers are exported
first; a binding failure triggers restoration. Restore previous driver uses the
earliest retained binding backup for each supported hardware ID, even after repeated
installation. Windows may request a restart; none is automatic. The installer writes
`last-result.json` in protected storage. `-PrepareOnly -NonInteractive` performs package
and signature checks without staging or rebinding drivers; it still requires elevation.

## Settings and Bluetooth

Use Magic Trackpad → Windows gestures and scrolling for taps, sensitivity, natural
scroll direction, pinch and configurable three/four-finger actions. Windows owns
gesture recognition and smooth manipulation; native settings avoid unsupported
registry broadcasts on Windows 10. These controls are opened from SwiftyToys.

Use Connect via Bluetooth to pair in Windows. Disconnect the cable to verify the
wireless transport; disconnect another computer using the trackpad if necessary.
Refresh enumerates present USB/Bluetooth device nodes, shows transport driver versions
and Windows problem codes; installed packages alone do not count as a detected device.
The presence of a Bluetooth node does not prove wireless report delivery. Use
`SwiftyToys.exe --trackpad-info` for the same read-only native SetupAPI diagnostics.
Keep wheel inversion for an ordinary mouse; configure touchpad direction in Windows.
The global wheel hook cannot distinguish devices that produce ordinary wheel events.

### Apple Bluetooth pairing recovery

Apple's Precision Bluetooth filter can fail initial HID connection and cause Windows
to forget the pair. The [upstream package discussion](https://github.com/lc700x/MagicTrackPad2_Windows_Precision_Drivers/issues/1#issuecomment-1888567442)
describes pairing before installing the Precision packages as a workaround. This is
a reported workaround, not a guaranteed fix or proof of a particular root cause.

If Windows pairs and then deletes the trackpad, use **Repair Bluetooth pairing**:

1. Disconnect its USB cable. The action requires confirmation and Windows UAC.
2. SwiftyToys verifies the pinned Apple archive and signed catalogs, finds installed
   OEM packages by exact Bluetooth INF hash, and exports them before removing them.
   Only the inspected Apple Precision Bluetooth package qualifies; USB support,
   other Apple drivers,
   the Bluetooth adapter and pairing keys are not manually removed. Another connected
   Apple device using this package blocks repair. Windows may refuse removal;
   SwiftyToys does not force it. On removal failure, it tries to stage the BT package
   again and reports any restoration failure.
3. Restart Windows yourself, then pair the trackpad over Bluetooth **without USB**.
   First check basic pointer movement; its failure indicates that pairing / basic
   HID input also needs diagnosis before Precision gesture tuning.
4. Install the Apple Precision driver from SwiftyToys while the pair is present.
   Test pointer movement and gestures. Avoid removing that working pair afterward.

The CLI equivalent is `install-trackpad.ps1 -RepairBluetooth` in elevated 64-bit
Windows PowerShell. The action downloads and checks the packages even when no
trackpad node is present; no restart or new pairing is automatic. Backups and
`pairing-repair.json` remain in protected driver storage. If pairing still fails,
inspect System / HidBth and SetupAPI logs before changing the radio driver.
The published workaround removes both Precision packages. SwiftyToys starts with
Bluetooth only to preserve the physically validated USB path; the effectiveness
of this narrower recovery remains to be tested on the connected hardware.

Windows gestures and application behavior differ from macOS. Force Click, three-finger
drag, rotation, lookup, Launchpad and identical application-independent momentum are
not promised. Driver binding / signature checks are not a physical gesture test.

## Implementations reviewed

Stars are a 2026-10-05 snapshot; popularity does not replace hardware validation.

| Project | Stars (approx.) | License / use in SwiftyToys |
| --- | ---: | --- |
| [imbushuo/mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad) | 10,486 | USB GPLv2, SPI MIT; optional separate signed upstream install |
| [vitoplantamura/MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows) | 812 | GPLv2; newer haptic/battery/settings implementation, Microsoft-signed Win11 package |
| [JoseExposito/touchegg](https://github.com/JoseExposito/touchegg) | 4,132 | GPLv3; Linux gesture UX reference, no copied code |
| [bulletmark/libinput-gestures](https://github.com/bulletmark/libinput-gestures) | 4,131 | Linux user-space gesture actions; research reference, no copied code |
| [mwyborski/Linux-Magic-Trackpad-2-Driver](https://github.com/mwyborski/Linux-Magic-Trackpad-2-Driver) | 508 | Historical kernel-driver work; no repository-level reuse permission inferred |
| [p2rkw/xf86-input-mtrack](https://github.com/p2rkw/xf86-input-mtrack) | 483 | GPLv2; Linux three-finger-drag / configuration reference, no copied code |
| [robbi5/magictrackpad2-dkms](https://github.com/robbi5/magictrackpad2-dkms) | 111 | GPLv2; historical Linux module packaging reference |

Also reviewed the Linux kernel's
[hid-magicmouse](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c)
and [libinput documentation](https://wayland.freedesktop.org/libinput/doc/latest/).
Their driver / gesture layers inform the separation of responsibilities; no kernel
or gesture-engine code is ported into SwiftyToys.

The newer vitoplantamura package has USB-C, battery, pointer tuning and haptic controls.
Its Windows 10 workaround requires importing a third-party trusted-root certificate;
SwiftyToys does not install that workaround. Licensing and signing are independent:
changing an open-source driver still requires a new trusted driver signature.

## A maintained driver implementation

The inspected imbushuo code is a useful starting point, not a universal signed package.
`AmtPtpDeviceUsbUm` converts Apple USB reports into PTP HID reports using UMDF 2.15;
`AmtPtpHidFilter` uses KMDF and its `Detour.c` patches HID stack internals. A Windows API
Swift companion can manage device discovery, settings, installation and diagnostics,
but cannot replace an INF-installed HID driver with `SendInput` and keep PTP semantics.
Rewriting that boundary in Swift offers no established WDK/signing path.

For an updated fork, keep the driver as a separate component with its upstream license,
source and notices, use a supported WDK toolchain and documented Windows interfaces,
and obtain a new Microsoft driver signature for every changed package. Evaluate newer
vitoplantamura fixes for report parsing, haptics and battery support before porting them;
its Windows 11 signing does not validate Windows 10 compatibility.

| Hardware | Transport | Current SwiftyToys status |
| --- | --- | --- |
| Original Magic Trackpad | Bluetooth | Unsupported; different reports, no tested hardware |
| Lightning Magic Trackpad 2, PID 0265 | USB | Installer supports signed Apple / imbushuo packages |
| Lightning Magic Trackpad 2, PID 0265 | Bluetooth | Signed Apple package; local initial pairing fails and Windows forgets the device; recovery validation pending |
| USB-C Magic Trackpad, PID 0324 | USB / Bluetooth | Native detection; installer support and hardware validation pending |

Before a model is advertised as supported, test pointer movement, scroll/zoom, taps,
three/four-finger gestures, sleep/wake, cable removal, Bluetooth reconnect/re-pair,
different DPI settings and Windows 10/11 separately. This is the concrete requirement
for extending support; no untested all-model compatibility claim is made.
