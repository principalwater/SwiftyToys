// SPDX-License-Identifier: MIT
import KeyboardCore
import Testing

struct ForegroundApplicationTests {
    @Test(arguments: ["browser.exe", "mstsc.exe", "editor.exe"], [UInt16(72), 9])
    func resolvedFirstChordUsesCurrentContextWithoutForegroundNotification(_ application: String, key: UInt16) throws {
        var foreground = ForegroundApplication()
        foreground.resolve(processID: 1, windowID: 1, time: 0) { _ in "previous.exe" }
        var engine = RemapEngine(rules: RemapRule.macPreset + [
            try RemapRule(from: "Win+H", to: "Ctrl+X", application: "editor.exe")
        ])
        _ = engine.process(key: 91, down: true)
        let current = foreground.resolve(processID: 2, windowID: 2, time: 0) { _ in application }
        let enabled = current != nil && current != "mstsc.exe"
        let result = engine.process(key: key, down: true, application: current ?? "", enabled: enabled)
        switch application {
        case "mstsc.exe":
            #expect(result.suppress == false)
            #expect(result.action == nil && result.events.isEmpty)
        case "editor.exe":
            #expect(result.suppress)
            #expect(result.action == nil)
            #expect(result.events.contains(KeyTransition(key == 72 ? 88 : 164, down: true)))
        default:
            #expect(result.suppress)
            if key == 72 { #expect(result.action == "minimize window") }
            else { #expect(result.events.contains(KeyTransition(164, down: true))) }
        }
        _ = engine.process(key: key, down: false, application: current ?? "", enabled: enabled)
        _ = engine.process(key: 91, down: false, application: current ?? "", enabled: enabled)
        #expect(engine.release().isEmpty)
    }

    @Test func failedLookupPassesThroughAndRetriesBeforeNextChord() {
        var foreground = ForegroundApplication()
        foreground.resolve(processID: 1, windowID: 1, time: 0) { _ in "previous.exe" }
        var engine = RemapEngine(rules: RemapRule.macPreset)
        _ = engine.process(key: 91, down: true)
        #expect(foreground.resolve(processID: 2, windowID: 2, time: 0) { _ in nil } == nil)
        #expect(foreground.application == nil)
        #expect(engine.process(key: 9, down: true, enabled: foreground.application != nil).suppress == false)
        _ = engine.process(key: 9, down: false, enabled: false)
        #expect(foreground.resolve(processID: 2, windowID: 3, time: 999) { _ in
            Issue.record("Persistent lookup failure must not query on every keystroke")
            return "wrong.exe"
        } == nil)
        let current = foreground.resolve(processID: 2, windowID: 2, time: 1000) { _ in "browser.exe" }
        let tab = engine.process(key: 9, down: true, application: current ?? "", enabled: current != nil)
        #expect(tab.suppress)
        #expect(tab.events.contains(KeyTransition(164, down: true)))
        _ = engine.process(key: 9, down: false)
        foreground.resolve(processID: 3, windowID: 3, time: 1000) { _ in "mstsc.exe" }
        let release = engine.process(key: 91, down: false, application: "mstsc.exe", enabled: false)
        #expect(release.events.contains(KeyTransition(164, down: false)))
        #expect(engine.release().isEmpty)
    }

    @Test func successfulLookupsAreReusedAcrossWindowsButEmptyNamesAreNot() {
        var foreground = ForegroundApplication()
        var queries = 0
        for _ in 0..<1000 {
            #expect(foreground.resolve(processID: 1, windowID: 1, time: 0) { _ in
                queries += 1
                return "browser.exe"
            } == "browser.exe")
        }
        #expect(queries == 1)
        #expect(foreground.resolve(processID: 1, windowID: 2, time: 0) { _ in
            Issue.record("A new window in the same live process must not query its executable again")
            return "mstsc.exe"
        } == "browser.exe")
        #expect(foreground.resolve(processID: 0, windowID: 0, time: 0) { _ in Issue.record("No process to resolve"); return "wrong.exe" } == nil)
        #expect(foreground.resolve(processID: 2, windowID: 3, time: 0) { _ in "" } == nil)
        #expect(foreground.resolve(processID: 2, windowID: 3, time: 1000) { _ in "browser.exe" } == "browser.exe")
    }

    @Test func delayedSnapshotNeverAppliesToAnotherForegroundAndConsumeDoesNotLookup() throws {
        var published = ForegroundApplication()
        var queries = 0
        #expect(published.consume(processID: 2) == nil)
        published.resolve(processID: 1, windowID: 1, time: 0) { _ in queries += 1; return "editor.exe" }
        // A delayed worker publishes the old process after focus already moved.
        #expect(published.consume(processID: 2) == nil)
        for _ in 0..<1000 { #expect(published.consume(processID: 1) == "editor.exe") }
        #expect(queries == 1)
        var engine = RemapEngine(rules: RemapRule.macPreset)
        _ = engine.process(key: 91, down: true, enabled: false)
        let unresolved = engine.process(key: 9, down: true, application: published.consume(processID: 2) ?? "",
            enabled: published.consume(processID: 2) != nil)
        #expect(!unresolved.suppress && unresolved.events.isEmpty)
        _ = engine.process(key: 9, down: false, enabled: false)
        _ = engine.process(key: 91, down: false, enabled: false)
        #expect(engine.release().isEmpty)
        #expect(published.consume(processID: 0) == nil)
    }
}
