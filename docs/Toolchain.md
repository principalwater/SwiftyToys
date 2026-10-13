# Swift toolchain

[.swift-version](../.swift-version) is the single default compiler/SDK pin for the
application, payload builder, setup bootstrap and Windows/Linux/macOS CI. It is
currently **6.4.1**. Package.swift retains Swift 6.4 as its minimum manifest API
version and Swift 6 language mode; those are compatibility declarations, not
alternative compiler pins.

Windows scripts select a complete official compiler, SDK and runtime from one
installation root and require the exact requested version. An older compiler on
PATH or stale SDKROOT cannot silently select a different release. The package
records the selected compiler in swift-version.txt; the application's version
output reads this bounded metadata, and setup refuses a mismatched package pin.
Do not edit installed SDKs, prune runtime archives or weaken DLL/security checks.

## Upgrade procedure

1. Read the official release notes and check downloadable packages for every CI
   platform. Install the official candidate alongside the current toolkit when the
   upstream installer permits it. Keep the previous application release for rollback.
2. Test a Windows candidate with `scripts/test.ps1 -SwiftVersion X.Y.Z`, then
   `scripts/build.ps1 -SwiftVersion X.Y.Z`. Run them sequentially. An explicit
   override is for validation; it does not change the shared release pin.
3. Change .swift-version in a reviewed PR. Update the current README version and
   record relevant fixes in CHANGELOG. CI must verify the active compiler and pass
   Windows native checks plus Linux/macOS portable tests on that same version.
4. Build a fresh package and setup with the pin. Check static imports, size budgets,
   payload extraction, rollback, icons and preserved settings. Install the complete
   package and verify its reported application and compiler versions.
5. Publish only after required CI and maintainer review. Do not auto-upgrade to
   `latest`, snapshots or untested major/minor toolchains.

## Why 6.4.1

The [official release notes](https://forums.swift.org/t/announcing-swift-6-4-1/90029)
include optimizer fixes for -Osize/weak closures, writes through pointers and
assignment motion; a Linux backtracer DWARF fix; dependency-resolution fixes; and
correct static-stdlib autolinking in Swift Build. This is a correctness update,
not a new Windows hardware API or measured performance improvement.

The static-stdlib compile fix lets the application build use the standard
`-static-stdlib` option without the redundant frontend `-use-static-resource-dir`
override. Explicit official dispatch/BlocksRuntime link inputs and all size,
import, recovery and signing checks remain. WinHTTP, Win32 jobs and native UI
stay in the Windows adapter; introducing Foundation/Subprocess solely for this
patch would add dependencies without a needed feature.

BrightnessCore, KeyboardCore and SearchCore remain independent of WinSDK. Linux
CI tests those portable algorithms as preparation for a future Linux application;
it does not claim Linux GUI, brightness or input support. Platform services should
stay in platform targets until an actual second implementation needs an interface.
