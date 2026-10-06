// SPDX-License-Identifier: MIT

/// A virtual-key transition to emit, with no platform-specific pointers.
public struct KeyTransition: Equatable, Sendable {
    public let key: UInt16
    public let isDown: Bool
    /// Creates one native key transition.
    public init(_ key: UInt16, down: Bool) {
        self.key = key
        isDown = down
    }
}

/// The replacement for one physical event, or a native action for the UI thread.
public struct RemapResult: Sendable {
    public var suppress = false
    public var events: [KeyTransition] = []
    public var action: String?
    /// Creates a pass-through result.
    public init() {}
}

/// A thread-owned keyboard state machine. The native adapter owns delivery failures.
public struct RemapEngine {
    private struct Invocation {
        let physicalKey: UInt16
        let source: KeyChord
        let target: KeyChord
        var keyIsDown: Bool
        var isWindowCycle: Bool { target.key == 9 && target.modifiers & 1 != 0 && source.modifiers & 8 != 0 }
    }
    private var rules: [RemapRule]
    private var pressed: [UInt16: UInt16] = [:]
    private var swallowedUps: Set<UInt16> = []
    private var deliveredModifiers: Set<UInt16> = []
    private var syntheticKeys: Set<UInt16> = []
    private var invocation: Invocation?

    /// Installs a bounded, validated rule set before attaching the native hook.
    public init(rules: [RemapRule]) { self.rules = Array(rules.prefix(64)) }

    /// Physical modifiers, before replacement, for native function-key handling.
    public var physicalModifiers: UInt8 { pressed.keys.reduce(0) { $0 | KeyChord.modifier(for: $1) } }

    /// Seeds modifiers already held when the hook is attached, without emitting input.
    public mutating func seedHeldModifiers(_ keys: [UInt16]) {
        for key in keys where KeyChord.modifier(for: key) != 0 {
            pressed[key] = key
            deliveredModifiers.insert(key)
        }
    }

    /// Processes one physical event; the application name is a normalized executable basename.
    public mutating func process(key: UInt16, down: Bool, application: String = "", enabled: Bool = true) -> RemapResult
    {
        var result = RemapResult()
        let previous = pressed[key]
        let logical: UInt16
        if down {
            if let previous {
                logical = previous
            } else {
                let single = enabled ? matchingSingle(key, application: application) : nil
                logical =
                    single?.target.map { KeyChord.concrete($0.key) }
                    ?? (single?.action == "disable key" ? 256 : key)
                pressed[key] = logical
            }
        } else {
            logical = pressed.removeValue(forKey: key) ?? key
        }
        let sourceMask = heldMask
        let modifierEvent = KeyChord.modifier(for: logical) != 0

        if !enabled, invocation != nil { endInvocation(into: &result.events) }
        if let active = invocation,
            modifierEvent
                && (active.isWindowCycle
                    ? ((down && KeyChord.modifier(for: logical) != 4)
                        || sourceMask & (active.source.modifiers & ~4) != active.source.modifiers & ~4)
                    : (down || sourceMask & active.source.modifiers != active.source.modifiers))
        {
            endInvocation(into: &result.events)
        }

        if !down, swallowedUps.remove(key) != nil {
            result.suppress = true
            if var active = invocation, active.physicalKey == key {
                emitKey(active.target.key, down: false, into: &result.events)
                active.keyIsDown = false
                invocation = active
                if active.source.modifiers == 0 { endInvocation(into: &result.events) }
            } else if previous != key, logical < 256, !modifierEvent {
                emitKey(logical, down: false, into: &result.events)
            }
            return result
        }

        if modifierEvent {
            let desired =
                invocation.map {
                    targetModifiers(
                        $0.isWindowCycle ? ($0.target.modifiers & ~4) | (sourceMask & 4) : $0.target.modifiers)
                } ?? heldModifiers
            var passed = deliveredModifiers
            if KeyChord.modifier(for: key) != 0 {
                if down { passed.insert(key) } else { passed.remove(key) }
            }
            if passed == desired, logical == key, result.events.isEmpty {
                deliveredModifiers = passed
            } else {
                reconcileModifiers(desired, into: &result.events)
                result.suppress = true
            }
            return result
        }

        if !down {
            if logical != key {
                reconcileModifiers(heldModifiers, into: &result.events)
                if logical < 256 { emitKey(logical, down: false, into: &result.events) }
                result.suppress = true
            } else if pressed.values.contains(logical) {
                // Another held physical key maps to this same logical key.
                result.suppress = true
            }
            return result
        }

        if var active = invocation, active.physicalKey == key {
            emitKey(active.target.key, down: true, into: &result.events)
            active.keyIsDown = true
            invocation = active
            swallowedUps.insert(key)
            result.suppress = true
            return result
        }
        if invocation?.isWindowCycle == true, [UInt16(27), 37, 38, 39, 40].contains(key) { return result }
        if invocation != nil { endInvocation(into: &result.events) }

        // Preserve AltGr text entry. Explicit single-key remaps remain user controlled.
        let altGrHeld = pressed[165] != nil
        let rule =
            enabled && !altGrHeld
            ? matchingShortcut(logical, modifiers: sourceMask, application: application) : nil
        if let rule {
            swallowedUps.insert(key)
            result.suppress = true
            if let target = rule.target {
                reconcileModifiers(targetModifiers(target.modifiers), into: &result.events)
                emitKey(target.key, down: true, into: &result.events)
                invocation = Invocation(physicalKey: key, source: rule.source, target: target, keyIsDown: true)
            } else if previous == nil {
                if rule.source.modifiers & 8 != 0 { dummy(controlHeld: deliveredModifiers.contains(162) || deliveredModifiers.contains(163), into: &result.events) }
                result.action = rule.action == "disable key" ? nil : rule.action
            }
        } else if logical != key {
            swallowedUps.insert(key)
            result.suppress = true
            reconcileModifiers(heldModifiers, into: &result.events)
            if logical < 256 { emitKey(logical, down: true, into: &result.events) }
        }
        return result
    }

    /// Releases synthesized keys and restores physical modifiers before pause or shutdown.
    public mutating func release() -> [KeyTransition] {
        var events: [KeyTransition] = []
        endInvocation(into: &events)
        for key in syntheticKeys.sorted() { events.append(KeyTransition(key, down: false)) }
        syntheticKeys.removeAll()
        for key in pressed.keys { pressed[key] = key }
        reconcileModifiers(heldModifiers, into: &events)
        return events
    }

    private var heldModifiers: Set<UInt16> {
        Set(pressed.values.filter { KeyChord.modifier(for: $0) != 0 })
    }
    private var heldMask: UInt8 {
        heldModifiers.reduce(0) { $0 | KeyChord.modifier(for: $1) }
    }
    private func matchingSingle(_ key: UInt16, application: String) -> RemapRule? {
        // ponytail: bounded scan of 64 rules; index by key only if profiling requires it.
        let matches = rules.lazy.filter {
            $0.source.modifiers == 0 && KeyChord.matches($0.source.key, key)
                && ($0.target?.modifiers == 0 || $0.action == "disable key")
                && ($0.application.isEmpty || $0.application == application)
        }
        return matches.first { !$0.application.isEmpty } ?? matches.first
    }
    private func matchingShortcut(_ key: UInt16, modifiers: UInt8, application: String) -> RemapRule? {
        let matches = rules.lazy.filter {
            $0.source.modifiers == modifiers && KeyChord.matches($0.source.key, key)
                && ($0.application.isEmpty || $0.application == application)
                && !($0.source.modifiers == 0 && $0.target?.modifiers == 0)
        }
        return matches.first { !$0.application.isEmpty } ?? matches.first
    }
    private func targetModifiers(_ mask: UInt8) -> Set<UInt16> {
        Set([(UInt8(8), UInt16(91)), (2, 162), (1, 164), (4, 160)].compactMap { mask & $0.0 == 0 ? nil : $0.1 })
    }
    private mutating func reconcileModifiers(_ desired: Set<UInt16>, into events: inout [KeyTransition]) {
        let released = deliveredModifiers.subtracting(desired).sorted()
        if released.contains(91) || released.contains(92) { dummy(controlHeld: deliveredModifiers.contains(162) || deliveredModifiers.contains(163), into: &events) }
        for key in released { events.append(KeyTransition(key, down: false)) }
        let added = desired.subtracting(deliveredModifiers).sorted()
        for key in added { events.append(KeyTransition(key, down: true)) }
        // A restored Win key must not open Start when the physical key is released.
        if added.contains(91) || added.contains(92) { dummy(controlHeld: desired.contains(162) || desired.contains(163), into: &events) }
        deliveredModifiers = desired
    }
    private mutating func emitKey(
        _ key: UInt16, down: Bool, excluding physical: UInt16? = nil, into events: inout [KeyTransition]
    ) {
        let key = KeyChord.concrete(key)
        if down {
            events.append(KeyTransition(key, down: true))
            syntheticKeys.insert(key)
        } else {
            syntheticKeys.remove(key)
            if !pressed.contains(where: { $0.key != physical && $0.value == key }) {
                events.append(KeyTransition(key, down: false))
            }
        }
    }
    private mutating func endInvocation(into events: inout [KeyTransition]) {
        guard let active = invocation else { return }
        invocation = nil
        if active.keyIsDown { emitKey(active.target.key, down: false, excluding: active.physicalKey, into: &events) }
        reconcileModifiers(heldModifiers, into: &events)
    }
    private func dummy(controlHeld: Bool, into events: inout [KeyTransition]) {
        // A real Ctrl pulse disarms the Windows menu; VK 255 is ignored by Windows.
        if !controlHeld { events += [KeyTransition(162, down: true), KeyTransition(162, down: false)] }
    }
}
