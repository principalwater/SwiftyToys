# SwiftyToys packaging

The application and installer are written in standard Swift. The application links
the official Swift runtime statically. The separate setup EXE embeds a bounded
installation payload compressed by Windows Cabinet APIs; its bootstrap imports only
Windows system DLLs. No executable packer, experimental Swift mode, runtime pruning
or patched SDK is used. Both embed the Command Ember icon, Common Controls v6,
per-monitor DPI and asInvoker manifest entries.

The executable ceiling is 8.61 MB: native ICC validation, WCS controls and display
diagnostics add a bounded allowance over the 8.5 MB Search ceiling, retaining recovery
and native checks. ZIP is capped at 3.56 MB; Setup retains 2.7 MB. The measured 0.1.19 setup is about 2.60 MB; these
ceilings remain enforced by packaging checks.
An intermediate optimized Search build measured 7,381,504 bytes versus the installed
0.1.12 app's 6,885,888 bytes; final sizes are recorded in Validation. Model weights,
tokenizer and the original signed Microsoft CPU runtime are optional downloads,
excluded from the base payload. Their license texts are included in the package.

Setup uses native CNG SHA-256, Cabinet LZMS, protected temporary storage, COM shell
links and Task Scheduler. It validates the complete payload before copying, keeps
settings/recovery, waits for residents and watchdogs to restore their display, and
rolls back owned installation files and startup metadata on failure. The fixed ICO
and stable process/shortcut AppUserModelID are configured before the new resident
starts. Only changed application files receive targeted Shell notifications.

The bootstrap uses scalar/pointer Win32 storage and a custom entry point to avoid a
Swift or Microsoft runtime dependency before setup. It initializes the official
MSVC stack-security cookie before guarded frames; import and load-config checks
run during packaging. The installed application retains System32-only DLL loading.
When the Microsoft Visual C++ Runtime is older than 14.44.35211 or missing, setup
offers a pinned official download, checks SHA-256 and the complete Authenticode
chain under a read-only file lock, then waits for the Microsoft installer. Internet
and administrator approval are needed only for this separate prerequisite. Its
binary is not bundled. Fresh-system download/UAC behavior requires separate testing.

The inherited BrightnessCtl experiments measured 23.62 MB ZIP with dynamic Foundation,
52.76 MB exe with static Foundation, 9.68 MB exe with FoundationEssentials, and about
6.12 MB exe / 2.3 MB ZIP using Swift standard library plus Win32. Those are upstream
measurements, not SwiftyToys results or PowerToys comparisons. The first SwiftyToys
native UI/remapping build was about 6.29 MB. The 0.1.1 release measures 6,327,296 bytes
for the executable and about 2.46 MB for the full ZIP with language packs, installer
scripts, documentation and licenses. Driver downloads are separate from that archive.

Build uses -Osize, -static-stdlib, /OPT:REF and /OPT:ICF with the exact official
toolchain pinned in .swift-version. See [toolchain upgrades](Toolchain.md).
Official dispatch.lib and BlocksRuntime.lib satisfy the static Swift concurrency
archive. Native threads are CRT initialized; driver work runs on its serial Swift
actor executor. The build rejects accidental dynamic Swift imports and enforces
8.61 MB EXE / 3.56 MB ZIP regression budgets. These budgets can be revised when an explicit
feature or a measured improvement justifies larger distribution; they are not a
reason to remove requested functionality or correctness checks.

0.1.11 adds eight native icon frames and updates window-local GDI painting. Its
EXE is 31,744 bytes above 0.1.10; the budget is 6.7 MB. RC resource hashes form
part of the link input name, so changed icons invalidate incremental linking.

The 0.1.12 application includes native setup and signed-driver orchestration that
replaces runtime PowerShell helpers. The integrated build measured
6,885,888 bytes, 278,016 bytes above 0.1.11; the explicit executable budget is now
7 MB. These cold installation paths add no resident frame loop or bundled runtime.

## Checks

Run scripts/test.ps1, then build.ps1 (sequentially: SwiftBuild shares its database).
Developer PowerShell scripts only invoke build/test tools; none is shipped or run
by the application or installer. Package with scripts/package.ps1 under PowerShell 7,
as CI does; Windows PowerShell 5.1 compresses less and exceeds the ZIP budget. Then run
scripts/build-setup.ps1 -PackageDirectory artifacts/SwiftyToys-0.1.27-win-x64.
CI keeps the Setup and ZIP from one package, with their SHA-256 files, as a run artifact.
The setup build runs parser rejection checks and validates the actual resource,
protected extraction, native stage-two controls and owned cleanup without installing.
Native --test-installer, --test-shell-integration, --test-installer-ui and
--test-trackpad-installer and --test-package-setup cover task/rollback policy, shortcut metadata, controls,
driver selection, recovery format and in-memory security descriptors without changing
installed drivers, tasks, registry values or the display.
WSL/Ubuntu/Homebrew decisions and process/status handling are Swift. Direct WSL/Linux
utilities retain interactive password prompts; Homebrew's official downloaded Bash
installer remains upstream code, with no custom shell control program in SwiftyToys.
Run --abi-check and --test-storage without a display controller. --test-input checks
an isolated brightness hook with injected F2 taps and a blocked UI, without adjusting
a monitor. The complete remap algorithm is covered by KeyboardCoreTests; native
physical-key/UIPI/AltGr and application-specific integration need interactive checks.
--test-foreground verifies native executable lookup, cache reuse and unresolved
context rejection without sending keys, changing focus or constructing a display controller.

Storage uses bounded strict UTF-8 reads and adjacent atomic replace with flush,
close and MoveFileExW. Failed commits preserve the previous destination. Gamma
recovery leases remain compatible with the upstream JSON format. Packaging preserves
licenses and source provenance. The installer waits for the old resident/watchdog,
never kills it to unlock files, copies settings and disables old startup after the
new resident starts. A shared ownership mutex prevents both applications from owning
the display at once.

Long filesystem operations use normalized extended local/UNC paths. Short paths
retain their existing semantics and avoid a full-size normalization buffer. Native
tests exercise Unicode atomic replacement beyond MAX_PATH, blocked commits and
cleanup. Legacy task backups use SHA-256 names rather than an expanded task path.
This works without enabling a machine-wide long-path policy or changing recovery
and shortcut paths stored in configuration.

No speed or memory superiority is claimed merely from executable size. Measurements
must distinguish the settings process, resident, watchdog and installer/download.
Installation and driver work are cold paths, separate from resident input/UI work.
Setup's bounded decompression allocation is temporary; it is not a resident frame loop.

References: [Swift](https://www.swift.org/documentation/),
[Common Controls manifest](https://learn.microsoft.com/en-us/windows/win32/controls/cookbook-overview),
[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
