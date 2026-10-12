# Native runtime and freeze prevention

SwiftyToys serves one interactive Windows session. The expensive paths are driver
calls, process/layout queries, durable storage and Shell observation; moving closer
to a native API does not give that API a return-time guarantee.

| Owner | Work | Boundaries |
| --- | --- | --- |
| Win32 UI thread | Controls, short input decisions, bounded brightness intents | GUI display requests complete by messages; display lists scan independently |
| Keyboard hook thread | Physical-key state machine and remapped transitions | No process, registry, layout-loading, display or file operations; unknown contexts pass through |
| Shared foreground resolver | Executable identity and configured loaded-layout order | One latest request, 64 cached process identities, failure backoff; signal-only stop |
| Display actor/executor | Native WDDM/AMD/DDC and calibration recovery | One admitted command; unchanged successful bindings do not rewrite brightness |
| Shell/HID observer | Consumer reports and deferred recognized flyouts | One pending notification, bounded ordered transitions/final masks, failed-post retry |
| Independent watchdog | Recover a terminated owner's exact saved output | It handles process death, not an indefinitely blocked live driver |

The v0.1.6–0.1.9 copied-desktop renderer could keep a stale opaque bitmap visible
if its refresh/native thread stalled. It is removed: there is no full-screen copy,
Magnifier window or per-frame application refresh. Software dimming uses the
existing calibrated WDDM/AMD paths; unavailable paths leave the desktop visible.
This removes that application's stale-frame failure mode, not every possible
Windows/GPU failure. No hang dump identified the precise native call in the report.

Cached display reuse requires the entire physical SDR binding. Recovery snapshots
are durable before writes, and cleanup requires the exact owner/start time, backend
and baseline. Missing checkpoints are recreated before restoration; failed recovery
retains its record. UI timeouts do not cancel an already-running kernel/driver call,
and therefore retain admission until actual completion. Legacy synchronous CLI
requests still have a bounded compatibility wait; ordinary GUI requests are async.

Native kernel scheduling, third-party hooks and driver stalls remain platform
limits. A previously unknown application's first chord may reach Windows before
background resolution; cached contexts retain application exclusions/overrides.
HID overflow above 128 pending transitions can drop additional completed taps,
while retaining final release/held state. Deferred Shell handling may show a brief
first-frame flash. Native cursors can remain brighter with DDC off.

Validation must separate pure checks, actual API checks, user input and measurements.
No frozen old renderer is relaunched merely to produce an A/B number. Historical
samples are context, not a controlled baseline or proof for weaker hardware.
