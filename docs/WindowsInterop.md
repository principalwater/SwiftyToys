# Windows interop in Swift 6.4

SwiftyToys uses official WinSDK and Clang imports for native layouts. Its
header-only module adds declarations for WDDM, HID, AMD and COM; no C implementation.

References:

- [Swift on Windows](https://www.swift.org/blog/swift-on-windows/): native Win32
  UI from Swift. Its 2020 package-manager limitations are historical.
- [Windows interoperability](https://www.swift.org/blog/swift-everywhere-windows-interop/):
  WinSDK, COM's C ABI and DirectX. Proposed `@COM` syntax is a design idea, not an
  implemented feature used here.
- [Windows workgroup](https://www.swift.org/blog/announcing-windows-workgroup/):
  platform maintenance, Foundation and toolchain interoperability.
- [C library usability](https://www.swift.org/blog/improving-usability-of-c-libraries-in-swift/):
  API notes and `swift-synthesize-interface` importer inspection.
- [SwiftCOM](https://github.com/compnerd/swift-com) and
  [DXSample](https://github.com/compnerd/DXSample) demonstrate COM/DirectX techniques.
  They are references, not dependencies or copied code.

## Ownership and concurrency

Native handles, WDDM sessions, BSTRs and COM references use noncopyable Swift types
with deterministic `deinit`. UTF-16 strings, gamma buffers and device-info pointers
stay within scoped closures. Release `--abi-check` verifies native SDK layouts.

Gamma storage uses `InlineArray` and scoped `Span` access. A dedicated serial actor
executor owns blocking driver calls. Win32 UI and low-level input own separate
message threads. The original brightness hook avoids allocation. The general remap
engine uses bounded Swift collections (64 rules) and emits small input batches;
no file/process-path queries, actor hops or driver calls occur inside its hook.
Foreground executable lookup runs in a WinEvent callback on the input thread. Mutexes
protect shared completion state; unchecked Sendable declarations explain their
ownership invariant.

Shell flyout observation has its own Win32 message thread. Out-of-context WinEvent
callbacks run on that thread and hide only recognized Shell brightness hosts
synchronously, avoiding a tray queue hop and a second `ShowWindowAsync` delay.
To prevent the first composed frame, recognized unshaped hosts are pre-clipped
with an empty native window region. Brightness HID reports are parsed on this
observer and arm suppression before posting steps to the tray. Media reports and
Shell media triggers restore normal rendering; completion rearms suppression.
The preference crosses threads through a mutex. System mode and shutdown restore
the region. Window properties identify the owning PID and process creation time,
allowing the existing watchdog and next startup to undo an interrupted change.
Existing window shapes are preserved and retain the scoped hide fallback.
The observer handles Explorer restarts independently of display-driver work.
Internal Shell signatures remain optional; unrelated windows are never hidden.

Run `scripts/test-indicator.ps1` in an interactive Windows session with the
resident running and a recognized native flyout already created. It verifies
suppression while the tray thread is briefly paused, delayed show events and
volume/system-mode cancellation, then restores the original indicator setting.
Microsoft documents the callback affinity and asynchronous delivery in
[SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook).
The display clip and region ownership follow
[SetWindowRgn](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn).

Native threads use `_beginthreadex` to initialize CRT thread state. An immutable
Sendable closure is retained until its entry point takes ownership; a noncopyable
handle closes independently of the running thread. An auto-reset kernel event
wakes the display executor, which drains its mutex-protected queue before waiting.
Stopping drains accepted jobs before the thread returns. Actor lifetime keeps
timed-out replies alive until their driver work finishes.

The release links the official static runtime and uses native Win32 file/process
APIs. See [packaging notes](Packaging.md) for the measured dependency reduction.

## A WinSDK overlay limitation

Swift 6.4 imports `GetMessageW` and `TrackPopupMenu` as Bool. Windows defines signed
-1/0/positive results for `GetMessageW`, and `TPM_RETURNCMD` returns the selected
menu command ID. Bool loses information required by these contracts.

`WindowsDisplayABI.h` declares signed-result aliases bound to the same DLL symbols.
No Windows DLL or Swift SDK file is patched. A destroyed HWND verifies that -1 is
preserved. The aliases target supported x64; 32-bit stdcall needs other decoration.
This is a focused candidate for an upstream overlay improvement with compatibility
tests for existing Bool callers and the two native contracts.

## Output boundary

Discovery excludes virtual/indirect adapters, shared clone sources and HDR.
`D3DKMTSetGammaRamp` uses EMULATED ownership with `AllowOutputDuplication=1`.
API success alone does not prove physical dimming or capture isolation: hardware
checks remain necessary. Native scanout was exercised on AMD hardware; Intel and
NVIDIA require hardware verification.

Recovery restores calibration through the existing owner before destroying it.
It never opens a competing owner while the backend holds the source, or overwrites
an unrecovered lease with another monitor's baseline.
