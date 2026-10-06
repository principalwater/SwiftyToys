# SwiftyToys contributor guide

SwiftyToys is a native Swift Windows utility for display control, familiar keyboard
shortcuts and input-device integration. Keep changes focused and follow existing
patterns. Read the relevant requirements and validation notes before editing.

## Repository map

- Sources/SwiftyToys: Windows application, native UI and system integration.
- Sources/BrightnessCore and Sources/KeyboardCore: portable algorithms.
- Sources/WindowsDisplayABI: header-only Windows interop.
- tests: hardware-independent Swift Testing checks.
- scripts: build, packaging and installation tooling.
- Languages: UTF-8 JSON language packs with English fallback.
- docs: architecture, compatibility, validation and performance notes.

## Build and validation

Use the official Swift 6.4 Windows toolchain, MSVC and Windows SDK. Run builds and
tests sequentially with scripts/build.ps1 and scripts/test.ps1. Run the native
ABI, storage, worker-wait, input-profile, mouse-scope and settings checks on Windows.
Run portable core tests on macOS. Distinguish physical device validation from tests.
For GUI-subsystem CLI checks, use Start-Process -Wait -PassThru with redirected
output. Install the complete packaged artifact. Verify CI before release.

## Implementation boundaries

Keep application code and default UI in English. Preserve language-pack fallback,
accessible native controls, DPI handling and keyboard navigation.
Use documented Windows APIs and existing helpers. Avoid extra dependencies or
abstractions without a required feature or measured benefit. Keep input callbacks
bounded and free of disk, driver and UI work. Do not intercept or synthesize wheel
input; preserve the native Precision Touchpad pipeline.

Keep the release size budgets, static Swift runtime and safe DLL resolution.
Measure CPU, memory and latency on the supported target platform before claiming
an improvement. Preserve input validation, calibration and resource ownership.
Never terminate the display watchdog or discard a recovery lease to unblock an
update. Preserve driver backups and working pairing. Driver packages must match
hardware and retain trusted signatures; do not edit INF/CAT, alter trusted roots,
enable test-signing or force unrelated packages. Observe third-party licenses.

## Documentation and privacy

Repository instructions describe the project, not a contributor's environment.
Do not commit personal agent preferences, private hostnames, SSH destinations,
local account/home paths, credentials, raw device identifiers or private logs.
Use generic placeholders and anonymized fixtures. Review documentation, commit
metadata, release archives and CI artifacts for unintended disclosures.
