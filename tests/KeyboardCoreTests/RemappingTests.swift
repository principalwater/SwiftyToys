import KeyboardCore
// SPDX-License-Identifier: MIT
import Testing

struct RemappingTests {
    @Test func commandControlPowerActionsRunOnceWithoutSyntheticKeys() throws {
        for (key, action) in [(UInt16(81), "lock screen"), (83, "sleep")] {
            for modifiers in [[UInt16(91), 162], [163, 92]] {
                var engine = RemapEngine(rules: RemapRule.macPreset)
                for modifier in modifiers { #expect(engine.process(key: modifier, down: true).suppress == false) }
                let result = engine.process(key: key, down: true)
                #expect(result.action == action)
                #expect(result.suppress && result.events.isEmpty)
                #expect(engine.process(key: key, down: true).action == nil)
                #expect(engine.process(key: key, down: false).suppress)
                for modifier in modifiers.reversed() { #expect(engine.process(key: modifier, down: false).suppress == false) }
                #expect(engine.release().isEmpty)
            }
        }
        #expect(try RemapRule(from: "Ctrl+Option+Cmd+S", to: "Sleep").action == "sleep")
    }
    @Test func applicationRuleTakesPriorityWithoutChangingFirstMatchOrder() throws {
        var engine = RemapEngine(rules: [
            try RemapRule(from: "Win+C", to: "Ctrl+C"),
            try RemapRule(from: "Win+C", to: "Ctrl+X", application: "notepad.exe"),
        ])
        _ = engine.process(key: 91, down: true)
        let result = engine.process(key: 67, down: true, application: "notepad.exe")
        #expect(result.events.contains(KeyTransition(88, down: true)))
        #expect(!result.events.contains(KeyTransition(67, down: true)))
    }
    @Test func commandHRequestsNativeMinimize() throws {
        var engine = RemapEngine(rules: RemapRule.macPreset)
        _ = engine.process(key: 91, down: true)
        let result = engine.process(key: 72, down: true)
        #expect(result.action == "minimize window")
        #expect(result.suppress)
        #expect(result.events == [KeyTransition(162, down: true), KeyTransition(162, down: false)])
        #expect(engine.process(key: 72, down: false).suppress)
    }
    @Test func bareCommandPassesThroughAndOptionArrowsChangeTabs() throws {
        var engine = RemapEngine(rules: RemapRule.macPreset)
        #expect(engine.process(key: 91, down: true).suppress == false)
        #expect(engine.process(key: 91, down: false).suppress == false)
        _ = engine.process(key: 91, down: true)
        _ = engine.process(key: 164, down: true)
        let left = engine.process(key: 37, down: true)
        #expect(left.suppress)
        #expect(left.events.contains(KeyTransition(33, down: true)))
        _ = engine.process(key: 37, down: false)
        let right = engine.process(key: 39, down: true)
        #expect(right.suppress)
        #expect(right.events.contains(KeyTransition(34, down: true)))
    }
    @Test func parsesNamesAndRejectsMalformedInput() throws {
        #expect(try KeyChord("Cmd+Shift+Tab") == KeyChord("Win+Shift+Tab"))
        #expect(throws: KeyboardError.self) { try KeyChord("Ctrl++Space") }
        #expect(throws: KeyboardError.self) { try KeyChord("Ctrl+Ctrl+C") }
        #expect(throws: KeyboardError.self) { try RemapRule(from: "Win+L", to: "Ctrl+C") }
        #expect(throws: KeyboardError.self) { try RemapRule(from: "A", to: "B", application: "../app.exe") }
        #expect(RemapRule.macPreset.contains { $0.source.description == "Ctrl+Space" && $0.action == "switch language" })
    }

    @Test func heldCommandCyclesUntilReleased() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "Win+Tab", to: "Alt+Tab")])
        #expect(engine.process(key: 91, down: true).suppress == false)
        let first = engine.process(key: 9, down: true)
        #expect(first.suppress)
        #expect(first.events.contains(KeyTransition(164, down: true)))
        #expect(first.events.contains(KeyTransition(9, down: true)))
        let up = engine.process(key: 9, down: false)
        #expect(up.events.contains(KeyTransition(9, down: false)))
        #expect(up.events.contains(KeyTransition(164, down: false)) == false)
        #expect(engine.process(key: 9, down: true).events == [KeyTransition(9, down: true)])
        _ = engine.process(key: 9, down: false)
        let released = engine.process(key: 91, down: false)
        #expect(released.events.contains(KeyTransition(164, down: false)))
        #expect(engine.release().isEmpty)
    }

    @Test func releaseModifierBeforeTriggerDoesNotLeaveKeysDown() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "Win+C", to: "Ctrl+C")])
        _ = engine.process(key: 91, down: true)
        _ = engine.process(key: 67, down: true)
        let released = engine.process(key: 91, down: false)
        #expect(released.events.contains(KeyTransition(67, down: false)))
        #expect(released.events.contains(KeyTransition(162, down: false)))
        #expect(engine.process(key: 67, down: false).suppress)
        #expect(engine.release().isEmpty)
    }

    @Test func actionRunsOnceAndKeepsPhysicalControl() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "Ctrl+Space", to: "Switch language")])
        _ = engine.process(key: 162, down: true)
        #expect(engine.process(key: 32, down: true).action == "switch language")
        #expect(engine.process(key: 32, down: true).action == nil)
        #expect(engine.process(key: 32, down: false).suppress)
        #expect(engine.process(key: 162, down: false).suppress == false)
    }

    @Test func singleKeyReleaseUsesOriginalMappingAfterFocusChange() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "A", to: "B", application: "notepad.exe")])
        #expect(
            engine.process(key: 65, down: true, application: "notepad.exe").events == [KeyTransition(66, down: true)])
        #expect(
            engine.process(key: 65, down: false, application: "other.exe").events == [KeyTransition(66, down: false)])
        #expect(engine.process(key: 65, down: true, application: "other.exe").suppress == false)
    }

    @Test func mappedModifierCombinesWithOrdinaryTyping() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "CapsLock", to: "Ctrl")])
        let down = engine.process(key: 20, down: true)
        #expect(down.events == [KeyTransition(162, down: true)])
        #expect(down.suppress)
        #expect(engine.process(key: 67, down: true).suppress == false)
        _ = engine.process(key: 67, down: false)
        #expect(engine.process(key: 20, down: false).events == [KeyTransition(162, down: false)])
        #expect(engine.release().isEmpty)
    }

    @Test func unmappedShortcutPassesThroughAndAltGrIsPreserved() throws {
        var engine = RemapEngine(rules: RemapRule.macPreset)
        _ = engine.process(key: 91, down: true)
        #expect(engine.process(key: 69, down: true).suppress == false)
        _ = engine.process(key: 69, down: false)
        _ = engine.process(key: 91, down: false)
        _ = engine.process(key: 162, down: true)
        _ = engine.process(key: 165, down: true)
        #expect(engine.process(key: 32, down: true).suppress == false)
    }

    @Test func pauseReleasesSynthesizedKeys() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "Win+Tab", to: "Alt+Tab")])
        _ = engine.process(key: 91, down: true)
        _ = engine.process(key: 9, down: true)
        let released = engine.release()
        #expect(released.contains(KeyTransition(9, down: false)))
        #expect(released.contains(KeyTransition(164, down: false)))
        #expect(released.contains(KeyTransition(91, down: true)))
        #expect(engine.process(key: 9, down: false, enabled: false).suppress)
    }
    @Test func reversesWindowCycleWithoutReleasingAlt() throws {
        var engine = RemapEngine(rules: RemapRule.macPreset)
        _ = engine.process(key: 91, down: true)
        _ = engine.process(key: 9, down: true)
        _ = engine.process(key: 9, down: false)
        let shift = engine.process(key: 160, down: true)
        #expect(!shift.events.contains(KeyTransition(164, down: false)))
        #expect(engine.process(key: 9, down: true).events == [KeyTransition(9, down: true)])
        _ = engine.process(key: 9, down: false)
        #expect(!engine.process(key: 160, down: false).events.contains(KeyTransition(164, down: false)))
        #expect(engine.process(key: 37, down: true).suppress == false)
        _ = engine.process(key: 37, down: false)
        #expect(engine.process(key: 91, down: false).events.contains(KeyTransition(164, down: false)))
    }
    @Test func pauseReleasesMappedPhysicalModifier() throws {
        var engine = RemapEngine(rules: [try RemapRule(from: "CapsLock", to: "Ctrl")])
        _ = engine.process(key: 20, down: true)
        #expect(engine.release().contains(KeyTransition(162, down: false)))
    }
    @Test func capsLockTapHoldRepeatAndInterveningTyping() {
        var caps = SmartCapsLock()
        #expect(caps.process(key: 20, down: true, time: 0, modifiers: 0, capsOn: false, enabled: true).suppress)
        #expect(caps.process(key: 20, down: false, time: 120, modifiers: 0, capsOn: false, enabled: true).tap)
        _ = caps.process(key: 20, down: true, time: 1000, modifiers: 0, capsOn: false, enabled: true)
        #expect(!caps.process(key: 20, down: true, time: 1200, modifiers: 0, capsOn: false, enabled: true).toggleCaps)
        #expect(caps.tick(time: 1300, enabled: true).toggleCaps)
        #expect(!caps.tick(time: 1400, enabled: true).toggleCaps)
        #expect(!caps.process(key: 20, down: false, time: 1600, modifiers: 0, capsOn: true, enabled: true).tap)
        _ = caps.process(key: 20, down: true, time: 2000, modifiers: 0, capsOn: false, enabled: true)
        #expect(caps.process(key: 65, down: true, time: 2080, modifiers: 0, capsOn: false, enabled: true).tap)
        #expect(!caps.process(key: 20, down: false, time: 2100, modifiers: 0, capsOn: false, enabled: true).tap)
        #expect(!caps.process(key: 20, down: true, time: 3000, modifiers: 4, capsOn: false, enabled: true).suppress)
        #expect(caps.process(key: 20, down: true, time: 4000, modifiers: 0, capsOn: true, enabled: true).toggleCaps)
        caps.cancel()
        #expect(!caps.tick(time: 5000, enabled: true).toggleCaps)
    }
}
