# Third-party notices and provenance

## BrightnessCtl — integrated source

SwiftyToys incorporates the MIT-licensed Swift source of
[BrightnessCtl 0.5.3](https://github.com/principalwater/BrightnessCtl).
The original copyright in LICENSE and the repository history are preserved.
Display control, recovery, watchdog, HID, OSD, native files and CLI derive directly
from that project; no external BrightnessCtl process is required during normal use.

## Microsoft PowerToys — inspiration

[PowerToys](https://github.com/microsoft/PowerToys) inspired the settings/module model
and configurable keyboard tools. SwiftyToys complements it for Mac/Boot Camp users.
No PowerToys code, branding or artwork is redistributed. This is an independent
project, not affiliated with Microsoft or Apple.

## AMD Display Library interop

The native function signatures, struct layouts and constants in
`Sources/WindowsDisplayABI/AMDABI.h` and `Sources/SwiftyToys/AMDColor.swift`
are adapted from AMD's public ADL SDK headers:
[adl_sdk.h](https://github.com/GPUOpen-LibrariesAndSDKs/display-library/blob/master/include/adl_sdk.h),
[adl_structures.h](https://github.com/GPUOpen-LibrariesAndSDKs/display-library/blob/master/include/adl_structures.h).
Those headers carry the following MIT notice. No AMD driver DLL, SDK binary,
sample application, or SDK documentation is redistributed. `atiadlxx.dll` is
loaded from the user's installed AMD display driver, whose license remains separate.

Copyright (c) 2016 - 2022 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## MonitorControl — conceptual reference

[MonitorControl](https://github.com/MonitorControl/MonitorControl) and its
[`Display.setSwBrightness`](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Model/Display.swift)
were consulted to understand per-display RGB output scaling and baseline restoration.
No Swift source was copied or translated into SwiftyToys. The Windows/AMD backend,
hotkeys, tray, persistence and recovery helper are independently implemented.
For transparency, MonitorControl's MIT license is reproduced below as published
in [License.txt](https://github.com/MonitorControl/MonitorControl/blob/main/License.txt).
The source file also credits JoniVR, theOneyouseek, waydabber and other contributors.

MIT License

Copyright © 2017

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
## BetterDisplay — inspiration, no redistributed code

[BetterDisplay](https://github.com/waydabber/BetterDisplay) inspired the goal of
software brightness affecting one local monitor. Its current public landing
branch contains documentation and releases, not the current application sources.
The historical `opensource` branch (BetterDummy) has an MIT license, but none of
its code or assets is included here. Reading that branch does not license the
current proprietary application. SwiftyToys does not claim to be an exact
port, fork, or endorsed version of either project.

## Swift runtime

Starting with 0.5.2, packages statically link the standard library, Concurrency,
Synchronization, WinSDK, Dispatch and Blocks runtime from the unmodified official
Swift 6.4.0 Windows SDK. The Apache 2.0 license and Swift runtime exception remain
in `Licenses/Swift.txt` and `Licenses/Dispatch.txt`. The application's MIT license
does not replace those licenses. No Foundation or ICU binary is linked or bundled.

The 0.5.0/0.5.1 packages included Foundation, Foundation Essentials/Internationalization
and Foundation ICU 76.1 DLLs. Their license texts and notices remain in `Licenses`
for reference, including the Unicode/third-party notices in `ICU.txt`. Foundation
Essentials is used only by compatibility tests in 0.5.2, not by the application.

Sources: [Swift](https://github.com/swiftlang/swift/tree/swift-6.4.0-RELEASE),
[Foundation](https://github.com/swiftlang/swift-corelibs-foundation/tree/swift-6.4.0-RELEASE),
[Swift Foundation](https://github.com/swiftlang/swift-foundation/tree/swift-6.4.0-RELEASE),
[Dispatch](https://github.com/swiftlang/swift-corelibs-libdispatch/tree/swift-6.4.0-RELEASE),
[Foundation ICU](https://github.com/swiftlang/swift-foundation-icu/tree/swift-6.4.0-RELEASE),
[ICU](https://github.com/unicode-org/icu/tree/release-76-1).

## ModernFlyouts — Shell compatibility reference

Shell flyout class/band signatures in `SystemIndicator.swift` are adapted from
[ModernFlyouts' NativeFlyoutHandler](https://github.com/ModernFlyouts-Community/ModernFlyouts/blob/main/ModernFlyouts.Core/Interop/NativeFlyoutHandler.cs).
The event gate, Swift implementation and brightness-only suppression are written
for SwiftyToys. No ModernFlyouts binary or UI assets are distributed.
The upstream MIT license is retained in `Licenses/ModernFlyouts.txt`.

## Windows system dependencies

Win32 interop declarations were written against Microsoft's public API documentation.
Windows SDK layouts are imported at build time. Windows and the Microsoft Visual
C++ x64 Redistributable are system prerequisites; their binaries are not bundled.
There is no .NET dependency in the Swift application.
