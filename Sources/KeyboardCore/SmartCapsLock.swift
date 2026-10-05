// SPDX-License-Identifier: MIT
/// Tap/hold decision, separate from native delivery and keyboard layout policy.
public struct CapsDecision: Sendable {
    public var suppress = false
    public var tap = false
    public var toggleCaps = false
}
public struct SmartCapsLock {
    private var started: UInt64?
    private var completed = false
    private let threshold: UInt64
    /// Creates a bounded user-controlled hold threshold, in milliseconds.
    public init(threshold: Int = 300) { self.threshold = UInt64(max(150, min(800, threshold))) }
    /// A native timer is needed only during an undecided hold.
    public var pendingHold: Bool { started != nil && !completed }
    /// Resolves a physical Caps event or an intervening key. Modifier chords pass through.
    public mutating func process(key: UInt16, down: Bool, time: UInt64, modifiers: UInt8, capsOn: Bool, enabled: Bool)
        -> CapsDecision
    {
        var result = CapsDecision()
        if key == 20 {
            if down {
                if started != nil {
                    result.suppress = true
                    return result
                }
                guard enabled, modifiers == 0 else { return result }
                started = time
                completed = capsOn
                result.suppress = true
                result.toggleCaps = capsOn
            } else if let started {
                result.suppress = true
                if !completed, enabled {
                    if time >= started && time - started >= threshold {
                        result.toggleCaps = true
                    } else {
                        result.tap = true
                    }
                }
                self.started = nil
                completed = false
            }
        } else if down, started != nil, !completed {
            completed = true
            result.tap = enabled
        }
        return result
    }
    /// The owning input thread calls this while waiting for native messages.
    public mutating func tick(time: UInt64, enabled: Bool) -> CapsDecision {
        var result = CapsDecision()
        if let started, !completed, time >= started, time - started >= threshold {
            completed = true
            result.toggleCaps = enabled
        }
        return result
    }
    /// Cancels a pending tap on focus/context changes, pause or shutdown.
    public mutating func cancel() {
        started = nil
        completed = false
    }
}
