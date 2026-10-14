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

## 0.1.19 persistent Search library

The library owns a separate low-priority process. Metadata admission is limited
to 128 entries or 40 ms per step, normally every two seconds. Content extraction
and vector generation require user idle time, sufficient memory, no active Search
and no fullscreen application; input cancels the owned child. Queries retrieve
saved fragments and encode only their query text. Native codecs can block inside
Windows, so the parent also enforces an owned-job deadline and commit limit.

The production-frozen candidate
`41b459a8f9dfd157d16233805a1b5d1f78b222eb2b96c3038729ca1a01e63c33`
passed real CPU-worker tests with verified downloaded assets. Gemma 2 cold setup
took 7.08 s, two 128-token documents 5.24 s and eight 16.77 s; MiniLM took 1.38 s,
0.203 s and 0.843 s respectively. Both cold cancellations completed in about
140 ms, with owned-process cleanup and file-lease release verified. These are
individual samples, not a controlled model-quality or optimization comparison.

Its optional media fixture completed in 78.58 s under a 1,536 MiB commit-limited
job. Three synthetic images took about 9.2–10.9 s each, video features 9.59 s and
a complete 30-second synthetic audio window 27.75 s. Peak private commit was
about 638 MiB and peak working set about 1,157 MiB. Color/tone retrieval passed;
this does not establish broad media-search quality, hardware-independent timing
or suitability for a low-memory machine. Encoders remain a separate opt-in download.

A 61.2-second installed 0.1.18 baseline recorded about 4.61 MiB resident private
bytes and 2.47 MiB watchdog private bytes, with stable handles and no measured
CPU increment. Foreground work was not controlled. Process counters do not
attribute GPU load or prove absence of system microfreezes; future comparisons
must retain equivalent settings, lifecycle and workloads.

Two separate 61.2-second installed 0.1.19 observations used the final executable
hash in Validation.md. The first recorded resident CPU about 0.051% of one core,
private bytes falling from 4.36 to 4.27 MiB, and 289–290 handles. Watchdog private
bytes stayed at 2.85 MiB, 181 handles, with no measured CPU increment. The library
child initially used at most about 0.92% of one core in five-second metadata bins;
later expensive work reached about one core, averaging 35.15% over the interval.
Private bytes grew from 3.25 to 63.34 MiB during that initialization/work interval.

In the second observation, the same library process averaged about 0.255% of one
core; private bytes stayed near 81.63 MiB and handles fell from 345 to 341. Resident
private bytes stayed at 4.26 MiB, 288 handles; watchdog counters stayed unchanged.
Neither showed a measured CPU increment. All sampled processes responded. These
are startup/settling observations under uncontrolled user activity, not a steady
state A/B benchmark, GPU attribution or proof that every Search interaction is
free of microfreezes. Heavy model/content work is reported separately from the
small resident and can use a CPU core while its idle gate permits it.

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

A separate 300.8-second steady-state sample of the installed executable
`65729E124718E38B309AF4EDD97AC04086A41F5351E7E8354C8BE18AA45342E8`
(6,411,264 bytes) used the High performance power plan. Resident counters stayed
at 3.57 MiB private bytes, 16.59 MiB working set, 8 threads and 258 handles;
CPU advanced by 0.015625 seconds, approximately 0.0052% of one core. Watchdog
counters stayed at 1.95 MiB private bytes, 8.66 MiB working set, 1 thread and
118 handles, with no measured CPU increment. Foreground activity was not
controlled; this is evidence of a small resident footprint during this interval,
not an isolated optimization gain, input-latency or low-end-hardware benchmark.

## Swift hotspot map and audit

- RemapEngine handles physical keyboard events; its rule scan is capped at 64.
- Native keyboard injection handles only remapped key transitions; no mouse hook exists.
- Foreground executable names/layouts are resolved by one independent worker; the hook consumes a bounded live-process cache.
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
update was removed. The former maximum-backlight worker was removed in 0.1.6; software dimming has
no periodic physical-backlight writes. Display requests are bounded and coalesced. Unchanged mouse direction
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
stripping and identical COMDAT folding. Budget: executable <=8.5 MB, ZIP <=3.5 MB.
Static DLL imports are restricted to System32 and verified with dumpbin loadconfig;
there are no bundled Swift DLLs or web renderer. Do not replace `-Osize` with `-O`
or change CPU target/ownership/concurrency based on guesswork.

For deeper Windows profiling, use WPR/WPA CPU sampling and precise context switches,
native process/GDI/USER counters and diagnostic QPC timing around physical input.

## Search cancellation and owned scratch memory

Search now checks cancellation before provider filesystem/process setup and
between Apps and Index stages. A process-local invalid-path fixture verifies
that a pre-cancelled provider reaches no setup I/O. Existing generation guards,
timeouts, below-normal priority and job ownership remain in place.

Streaming SHA-256 verification uses a pinned SwiftOSPrimitives PageRegion for its
64 KiB scratch buffer, borrowed synchronously and released explicitly. Read-size
validation, callback error propagation, CNG hashing and signature checks remain.
The tokenizer already uses a read-only native file mapping; it does not copy its
32 MB file into an anonymous region. Page ownership is not a global allocator or
a claim of faster hashing.

A bounded 120-second idle observation recorded about 0.013% of one core, stable
18.16 MiB private memory and 502 handles for the resident. A later interactive
observation mixed Search, settings and optional-model activity: about 8.501% of
one core, private memory 18.87 to 27.29 MiB and handles 529 to 965. The workload
and lifecycle were not controlled, so these are not A/B gains or proof of a leak.

The private ETW trace reports zero lost events, but its circular kernel buffers
retain about 31 seconds of the interactive recording. Samples from the known UI
thread mostly fall in Windows kernel/drawing/system code; Rich Edit and XAML were
loaded without attributed samples in that retained window. This is instruction
sampling, with unmapped addresses and incomplete scheduling/render evidence. It
does not establish a Search/GPU cause, input latency or absence of microfreezes.

## 0.1.10 freeze-related work elimination

The copied-desktop renderer and 16-ms refresh/Z-order loop are removed, rather than
moved to another high-frequency worker. Native brightness retains its validated
binding and skips unchanged writes. Slow executable/layout queries are isolated
from the hook owner; repeated requests coalesce. See [runtime architecture](RuntimeArchitecture.md).

A 120-second installed observation recorded resident CPU about 0.081% of one core,
4.40 MiB private bytes, 15.03 MiB working set, 9 threads and 258 handles; watchdog
showed no counter-resolution CPU increment, 2.34 MiB private and 9.75 MiB working
set. Historical composition samples had different workload/lifecycle states, so
no numerical speedup or memory reduction is attributed solely to these changes.
No old frozen renderer was relaunched for comparison, and no GPU or weakest-device
claim follows from this sample. Physical users confirmed the repaired runtime
continues updating the desktop and input during their short check.
A separate ten-minute interactive observation recorded about 0.016% of one core,
4.39 MiB resident private bytes and 14.48 MiB working set at its last sample.
Watchdog private bytes ended at 2.34 MiB, working set 9.75 MiB, with no measured
CPU increment. This is an observation of this workload, not a controlled benchmark
or proof of long-session stability.
Measure cold/warm startup separately, retain executable hashes, and compare p50/p95/
p99 under the same workload. Preserve watchdog recovery and input validation.
