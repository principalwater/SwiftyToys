// SPDX-License-Identifier: MIT

/// One repeat stream for keyboard and consumer-HID sources. Call on the owning message thread.
public struct BrightnessKeyRepeat: Sendable {
    private struct Held: Sendable {
        var keys: UInt8
        var cancelled = false
    }
    private var sources: [Int: Held] = [:]
    private var direction = 0
    private var nextRepeat: UInt64 = 0
    private var delayMs: UInt64
    private var intervalMs: UInt64

    public init(delayMs: UInt64 = 400, intervalMs: UInt64 = 60) {
        self.delayMs = max(1, delayMs)
        self.intervalMs = max(1, intervalMs)
    }

    public var isHeld: Bool { direction != 0 }

    /// Refresh native repeat timing without forgetting cancelled held sources.
    public mutating func configure(delayMs: UInt64, intervalMs: UInt64) {
        self.delayMs = max(1, delayMs)
        self.intervalMs = max(1, intervalMs)
    }

    /// F1/decrease is bit 0; F2/increase is bit 1. Zero releases this source.
    public mutating func update(source: Int, keys: UInt8, time: UInt64) -> Int {
        guard keys <= 3 else { return 0 }
        if keys == 0 {
            sources.removeValue(forKey: source)
        } else {
            guard sources[source] != nil || sources.count < 64 else { return 0 }
            let cancelled = sources[source]?.cancelled ?? false
            sources[source] = Held(keys: keys, cancelled: cancelled)
        }
        let mask = sources.values.reduce(UInt8(0)) { $0 | ($1.cancelled ? 0 : $1.keys) }
        let updated = mask == 1 ? -1 : mask == 2 ? 1 : 0
        guard updated != direction else { return 0 }
        direction = updated
        nextRepeat = time &+ delayMs
        return direction
    }

    /// A stalled message loop produces one step, without a burst of overdue repeats.
    public mutating func tick(time: UInt64) -> Int {
        guard isHeld, time >= nextRepeat else { return 0 }
        nextRepeat = time &+ intervalMs
        return direction
    }

    /// Focus/power changes stop a held press until its source reports every key released.
    public mutating func cancel() {
        for source in sources.keys { sources[source]?.cancelled = true }
        direction = 0
        nextRepeat = 0
    }

    public mutating func reset() {
        sources.removeAll(keepingCapacity: true)
        direction = 0
        nextRepeat = 0
    }
}
