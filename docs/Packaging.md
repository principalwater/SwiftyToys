# SwiftyToys packaging

The default build is a single statically linked Swift executable. The Windows SDK
and Visual C++ Redistributable remain platform prerequisites. No executable packer,
self-extracting loader, runtime pruning or patched SDK is used. The build embeds
Common Controls v6, per-monitor DPI and asInvoker manifest entries.

The inherited BrightnessCtl experiments measured 23.62 MB ZIP with dynamic Foundation,
52.76 MB exe with static Foundation, 9.68 MB exe with FoundationEssentials, and about
6.12 MB exe / 2.3 MB ZIP using Swift standard library plus Win32. Those are upstream
measurements, not SwiftyToys results or PowerToys comparisons. The first SwiftyToys
native UI/remapping build was about 6.29 MB. The 0.1.1 release measures 6,327,296 bytes
for the executable and about 2.46 MB for the full ZIP with language packs, installer
scripts, documentation and licenses. Driver downloads are separate from that archive.

Build uses -Osize, -static-stdlib, -use-static-resource-dir, /OPT:REF and /OPT:ICF.
Official dispatch.lib and BlocksRuntime.lib satisfy the static Swift concurrency
archive. Native threads are CRT initialized; driver work runs on its serial Swift
actor executor. The build rejects accidental dynamic Swift imports and has a 6.5 MB
exe / 3 MB ZIP regression budget. These budgets can be revised when an explicit
feature or a measured improvement justifies larger distribution; they are not a
reason to remove requested functionality or correctness checks.

## Checks

Run scripts/test.ps1, then build.ps1 (sequentially: SwiftBuild shares its database).
Run --abi-check and --test-storage without a display controller. --test-input checks
an isolated brightness hook with injected F2 taps and a blocked UI, without adjusting
a monitor. The complete remap algorithm is covered by KeyboardCoreTests; native
physical-key/UIPI/AltGr and application-specific integration need interactive checks.

Storage uses bounded strict UTF-8 reads and adjacent atomic replace with flush,
close and MoveFileExW. Failed commits preserve the previous destination. Gamma
recovery leases remain compatible with the upstream JSON format. Packaging preserves
licenses and source provenance. The installer waits for the old resident/watchdog,
never kills it to unlock files, copies settings and disables old startup after the
new resident starts. A shared ownership mutex prevents both applications from owning
the display at once.

No speed or memory superiority is claimed merely from executable size. Measurements
must distinguish the settings process, resident, watchdog and installer/download.

References: [Swift](https://www.swift.org/documentation/),
[Common Controls manifest](https://learn.microsoft.com/en-us/windows/win32/controls/cookbook-overview),
[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
