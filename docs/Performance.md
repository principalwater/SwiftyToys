# Performance and legacy hardware

The reference machine is MacPro6,1 (Late 2013), Windows 10 Pro build 19045,
24 logical processors and about 64 GiB RAM. It is old hardware, not a controlled
low-memory machine. Measurements on another platform do not establish Windows latency.

## Reproducible counters

```powershell
./scripts/measure-idle.ps1 -OutputPath ./idle.json -Seconds 600
```

The script reads counters without starting/stopping applications or changing
priority, UI, settings or power plan. It records executable hashes, Windows/model,
power plan, elapsed CPU seconds, private bytes, working set, handles and threads
for the resident and watchdog separately. CPU percent is relative to one core,
not divided by this machine's 24 logical processors. Keep identical settings,
foreground workload, startup state and sampling duration for comparisons.

A 60-second pre-change sample of the installed intermediate 0.1.3 build
`6CDC7E3451BD09CCC1D9C0EB16ED7251C350AE54BB00341A76CDB40491F1EA26`
recorded resident private bytes 5.04 MiB, working set 28.31 MiB, 8 threads,
341 handles and about 0.085% of one core. Watchdog: private bytes 1.95 MiB,
working set 8.66 MiB, 1 thread, 118 handles, no measured CPU increment.
Foreground activity was not controlled; this is a short counter sample, not a
startup, input latency, energy or weakest-hardware benchmark.

After installing the optimized build, a separate 60-second software-mode sample
recorded resident private bytes 3.36 MiB, working set 13.36 MiB, 10 threads,
225 handles and about 0.057% of one core. The app had just restarted and its settings
window had not been opened; the first sample came from a longer-running resident.
These are different lifecycle states, so the memory/CPU differences are not
attributed solely to the code changes.

A 120-second hardware-mode sample while UAC awaited input recorded resident
private bytes 4.41 MiB, working set 24.31 MiB, 11 threads and 367 handles. No CPU
increment was visible at the Windows counter resolution. This is not proof of
zero CPU usage, and UAC/waiting threads make it unsuitable for an idle A/B claim.

## Swift hotspot map and audit

- RemapEngine handles physical keyboard events; its rule scan is capped at 64.
- Native keyboard injection handles only remapped key transitions; no mouse hook exists.
- Foreground executable names are cached by a separate WinEvent callback.
- GammaRamp contains 768 fixed UInt16 values and uses InlineArray/Span for native calls.
- ColorLease arrays are serialized for recovery, outside the input callback.
- DisplayController owns driver state on a dedicated serial executor.
- DisplayBridge creates one actor request per brightness/status command, not per pixel/key.
- Native handle/thread ownership prevents double closes and overlapping input workers.
- Weak captures are lifecycle guards in worker startup/UI callbacks; no hot-loop ARC finding.
- Driver enumeration and language-pack parsing are cold UI/diagnostic paths.

Axiom Swift Performance Analyzer searches were run individually for type/loop,
copy, collection-growth, weak-capture, existential, actor and inlining patterns.
The source scan found bounded eager rule-filter allocations and unnecessary timer
work; it did not establish a CPU bottleneck or justify an executor/actor rewrite.
The two rule matchers now use a single bounded traversal without temporary match arrays or repeated no-match scans.
App-specific first-match priority is covered by a regression test.

The tray now modifies its icon only when its text changes. The duplicate timer
update was removed. The 10-second DDC gate runs before reading configuration,
including when maximum-backlight enforcement is disabled. Unchanged mouse direction
does not request UAC or restart a device. These eliminate concrete operations;
their independent timing/energy benefit is not claimed from source inspection.

| Audit dimension | Result |
| --- | --- |
| Large values | Fixed gamma ramp; recovery/configuration values outside physical hooks |
| ARC | 3 weak capture sites; retained for lifecycle correctness |
| Existentials | Decoder/Encoder in portable serialization; no dynamic protocol collection in input path |
| Collections | Bounded scans; eager match arrays removed; no justified pooling/index framework |
| Actors | 2 await sites in the display bridge; no actor call inside a tight loop |
| Inlining | No speculative @inlinable/@_specialize annotations |
| Classification | Source overhead reduced; latency and longer memory-growth profiling pending |

## Build budget and safety

Release uses `-Osize`, static official Swift runtime, no debug information, dead
stripping and identical COMDAT folding. Budget: executable <=6.5 MB, ZIP <=3 MB.
Static DLL imports are restricted to System32 and verified with dumpbin loadconfig;
there are no bundled Swift DLLs or web renderer. Do not replace `-Osize` with `-O`
or change CPU target/ownership/concurrency based on guesswork.

For deeper Windows profiling, use WPR/WPA CPU sampling and precise context switches,
native process/GDI/USER counters and diagnostic QPC timing around physical input.
Measure cold/warm startup separately, retain executable hashes, and compare p50/p95/
p99 under the same workload. Preserve watchdog recovery and input validation.
