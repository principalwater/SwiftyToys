// SPDX-License-Identifier: MIT

import Synchronization
import KeyboardCore
import WinSDK

let brightnessKeyBatchMessage: UINT = 0x8036
let indicatorBrightnessMailbox = IndicatorBrightnessMailbox()

/// Ordered HID transitions share one notification; failed posts retain the batch.
final class IndicatorBrightnessMailbox: Sendable {
    enum Transition { case keys(Int, UInt8), cancel }
    struct Batch {
        let transitions: [Transition]
        let sources: [Int: UInt8]
        let overflowReleases: Set<Int>
    }
    private struct State {
        var sources: [Int: UInt8] = [:]
        var transitions: [Transition] = []
        var overflowReleases: Set<Int> = []
        var dirty = false
        var posted = false
    }
    private let state = Mutex(State())

    func update(source: Int, states: [UInt8]) {
        state.withLock { state in
            for keys in states where keys <= 3 {
                guard state.sources[source] != nil || state.sources.count < 64,
                    keys != (state.sources[source] ?? 0) else { continue }
                state.sources[source] = keys
                // shortcut: retain 128 ordered transitions and every final mask, raise the cap only after measured real bursts.
                if state.transitions.count < 128 { state.transitions.append(.keys(source, keys)) }
                else if keys == 0 { state.overflowReleases.insert(source) }
                state.dirty = true
            }
        }
    }

    func cancel() {
        state.withLock { state in
            if state.transitions.count >= 128 {
                // A full batch must still establish each held source before cancellation.
                state.transitions = state.sources.map { .keys($0.key, $0.value) }
            }
            state.transitions.append(.cancel)
            state.overflowReleases.removeAll(keepingCapacity: true)
            state.dirty = true
        }
    }

    func notify(_ post: () -> Bool) {
        state.withLock { state in
            if state.dirty && !state.posted { state.posted = post() }
        }
    }

    func drain() -> Batch {
        state.withLock { state in
            let batch = Batch(transitions: state.transitions, sources: state.sources,
                overflowReleases: state.overflowReleases)
            state.sources = state.sources.filter { $0.value != 0 }
            state.transitions.removeAll(keepingCapacity: true)
            state.overflowReleases.removeAll(keepingCapacity: true)
            state.dirty = false; state.posted = false
            return batch
        }
    }
}

/// WinEvent callbacks only record facts; the observer mutates foreign windows later.
struct IndicatorEventQueue {
    struct Event { var kind: DWORD; var timestamp: DWORD; var showed: Bool }
    private var events: [Int: Event] = [:]
    private var posted = false
    private var processing = false

    mutating func enqueue(window: Int, kind: DWORD, timestamp: DWORD) {
        guard events[window] != nil || events.count < 64 else { return }
        events[window] = Event(kind: kind, timestamp: timestamp,
            showed: kind == DWORD(EVENT_OBJECT_SHOW) || events[window]?.showed == true)
    }

    mutating func notify(_ post: () -> Bool) {
        if !events.isEmpty && !posted { posted = post() }
    }

    mutating func begin() -> [Int: Event]? {
        posted = false
        guard !processing else { return nil }
        processing = true
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
    }

    mutating func end() { processing = false }
}

/// Hardware-independent checks: no HWND, input registration or foreign-window calls.
func testIndicatorMailboxes() throws(WindowsError) {
    func replay(_ batch: IndicatorBrightnessMailbox.Batch, _ keys: inout BrightnessKeyRepeat) -> Int {
        var steps = 0
        for transition in batch.transitions {
            switch transition {
            case .keys(let source, let mask): steps += keys.update(source: source, keys: mask, time: 0)
            case .cancel: keys.cancel()
            }
        }
        for source in batch.overflowReleases { _ = keys.update(source: source, keys: 0, time: 0) }
        for (source, mask) in batch.sources { _ = keys.update(source: source, keys: mask, time: 0) }
        return steps
    }
    let mailbox = IndicatorBrightnessMailbox()
    mailbox.update(source: 1, states: [2, 0, 2, 0])
    var posts = 0
    mailbox.notify { posts += 1; return false }
    mailbox.update(source: 1, states: [2])
    mailbox.notify { posts += 1; return true }
    mailbox.notify { posts += 1; return true }
    var keys = BrightnessKeyRepeat()
    let taps = mailbox.drain()
    guard posts == 2, replay(taps, &keys) == 3, keys.isHeld else {
        throw .unsupported("HID tap/failed-notification coalescing check failed.")
    }
    mailbox.cancel()
    mailbox.update(source: 1, states: [0, 1, 0, 2, 0])
    guard replay(mailbox.drain(), &keys) == 0, !keys.isHeld else {
        throw .unsupported("HID cancellation/alternating tap/final release check failed.")
    }
    let overlap = IndicatorBrightnessMailbox()
    _ = keys.update(source: -1, keys: 2, time: 0)
    overlap.update(source: 1, states: [2, 0, 2])
    guard replay(overlap.drain(), &keys) == 0, keys.isHeld else {
        throw .unsupported("Hook/HID complete-pulse and held-direction deduplication check failed.")
    }
    overlap.update(source: 1, states: [0])
    _ = replay(overlap.drain(), &keys)
    _ = keys.update(source: -1, keys: 0, time: 0)
    guard !keys.isHeld else { throw .unsupported("Dual-source final release check failed.") }
    let releaseRetry = IndicatorBrightnessMailbox()
    releaseRetry.update(source: 3, states: [2])
    _ = replay(releaseRetry.drain(), &keys)
    releaseRetry.update(source: 3, states: [0])
    var releasePosts = 0
    releaseRetry.notify { releasePosts += 1; return false }
    releaseRetry.notify { releasePosts += 1; return true }
    releaseRetry.notify { releasePosts += 1; return true }
    let released = releaseRetry.drain()
    _ = replay(released, &keys)
    guard releasePosts == 2, released.sources[3] == 0, !keys.isHeld else {
        throw .unsupported("Failed HID release notification lost the final release.")
    }
    let overflow = IndicatorBrightnessMailbox()
    overflow.update(source: 1, states: Array(repeating: [UInt8(2), UInt8(0)], count: 512).flatMap { $0 })
    let bounded = overflow.drain()
    guard bounded.transitions.count == 128, bounded.sources[1] == 0 else {
        throw .unsupported("HID transition bound/final release check failed.")
    }
    _ = replay(bounded, &keys)
    guard !keys.isHeld else { throw .unsupported("Overflow left a held HID source.") }
    overflow.update(source: 1, states: Array(repeating: [UInt8(2), UInt8(0)], count: 128).flatMap { $0 } + [2])
    overflow.cancel()
    let cancelledOverflow = overflow.drain()
    _ = replay(cancelledOverflow, &keys)
    guard cancelledOverflow.transitions.count <= 128, !keys.isHeld else {
        throw .unsupported("HID overflow lost cancellation.")
    }
    let freshOverflow = IndicatorBrightnessMailbox()
    var freshKeys = BrightnessKeyRepeat()
    freshOverflow.update(source: 1, states: [2])
    _ = replay(freshOverflow.drain(), &freshKeys)
    freshOverflow.cancel()
    freshOverflow.update(source: 2, states: Array(repeating: [UInt8(2), UInt8(0)], count: 63).flatMap { $0 } + [2])
    freshOverflow.update(source: 2, states: [0])
    freshOverflow.update(source: 1, states: [0, 2])
    let freshBatch = freshOverflow.drain()
    _ = replay(freshBatch, &freshKeys)
    guard freshBatch.transitions.count == 128, freshBatch.overflowReleases == Set([1, 2]),
        freshKeys.isHeld, freshKeys.tick(time: 1000) == 1 else {
        throw .unsupported("Overflow release/repress retained a cancelled HID source.")
    }
    for _ in 0..<500 { freshOverflow.cancel() }
    let repeatedCancellation = freshOverflow.drain()
    _ = replay(repeatedCancellation, &freshKeys)
    guard repeatedCancellation.transitions.count <= 128, !freshKeys.isHeld else {
        throw .unsupported("Repeated HID cancellation exceeded its transition bound.")
    }
    var events = IndicatorEventQueue()
    events.enqueue(window: 1, kind: DWORD(EVENT_OBJECT_SHOW), timestamp: 1)
    events.enqueue(window: 1, kind: DWORD(EVENT_OBJECT_HIDE), timestamp: 2)
    events.notify { false }
    events.notify { true }
    guard let batch = events.begin(), batch.count == 1, batch[1]?.showed == true,
        batch[1]?.kind == DWORD(EVENT_OBJECT_HIDE) else {
        throw .unsupported("Indicator event coalescing check failed.")
    }
    events.enqueue(window: 2, kind: DWORD(EVENT_OBJECT_CREATE), timestamp: 3)
    guard events.begin() == nil else { throw .unsupported("Indicator processing reentered.") }
    events.end()
    guard events.begin()?[2]?.timestamp == 3 else { throw .unsupported("Nested indicator event was lost.") }
    events.end()
    Console.writeLine("PASS: bounded HID transitions/release, dual-source pulses, failed-post retry, cancellation and nested deferred indicator events; no system changes")
}
