// SPDX-License-Identifier: MIT
import BrightnessCore
import KeyboardCore

struct KeyboardConfiguration: Sendable {
    var enabled = true
    var rules: [RemapRule] = RemapRule.macPreset
    var excluded = ["mstsc.exe"]
    var reverseVertical = false
    var reverseHorizontal = false
    var smartCaps = false
    var capsThreshold = 300
    var capsAction = "Switch language"
    var languageMode = "cycle"
    var languagePair: [UInt16] = []
    init() throws {
        let file = try NativeFiles.path("keyboard.ini")
        guard try NativeFiles.exists(file) else { return }
        rules = []
        for line in try NativeFiles.text(file).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("enabled=") {
                enabled = line == "enabled=1"
            } else if line.hasPrefix("reverseVertical=") {
                reverseVertical = line == "reverseVertical=1"
            } else if line.hasPrefix("reverseHorizontal=") {
                reverseHorizontal = line == "reverseHorizontal=1"
            } else if line.hasPrefix("smartCaps=") {
                smartCaps = line == "smartCaps=1"
            } else if line.hasPrefix("capsThreshold=") {
                capsThreshold = max(150, min(800, Int(line.dropFirst(14)) ?? 300))
            } else if line.hasPrefix("capsAction=") {
                capsAction = String(line.dropFirst(11))
                _ = try RemapRule(from: "CapsLock", to: capsAction)
            } else if line.hasPrefix("languageMode=") {
                languageMode = String(line.dropFirst(13))
                guard ["cycle", "latin", "pair"].contains(languageMode) else {
                    throw WindowsError.unsupported("Invalid language-switch mode.")
                }
            } else if line.hasPrefix("languagePair=") {
                languagePair = line.dropFirst(13).split(separator: ",").compactMap { UInt16($0) }
                guard languagePair.count <= 2 else { throw WindowsError.unsupported("Invalid language pair.") }
            } else if line.hasPrefix("exclude=") {
                excluded = line.dropFirst(8).split(separator: ",").map { $0.trimmingWhitespace().lowercased() }
                guard excluded.count <= 32,
                    excluded.allSatisfy({ !$0.contains("\\") && !$0.contains("/") && $0.utf8.count <= 260 })
                else {
                    throw WindowsError.unsupported("Invalid application exclusions.")
                }
            } else if !line.hasPrefix("#") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3, rules.count < 64 else {
                    throw WindowsError.unsupported("Invalid keyboard rule file.")
                }
                rules.append(try RemapRule(from: String(parts[0]), to: String(parts[1]), application: String(parts[2])))
            }
        }
        let preset = RemapRule.macPreset
        let additions: Set<String> = ["Win+H", "Win+Alt+Left", "Win+Alt+Right"]
        if rules.filter({ !additions.contains($0.source.description) }) == preset.filter({ !additions.contains($0.source.description) }) {
            rules += preset.filter { candidate in additions.contains(candidate.source.description) && !rules.contains(where: { $0.source == candidate.source }) }
        }
    }
    func save() throws {
        _ = try RemapRule(from: "CapsLock", to: capsAction)
        guard !smartCaps || (!rules.contains(where: { $0.source.key == 20 }) && rules.count < 64),
            (150...800).contains(capsThreshold)
        else {
            throw WindowsError.unsupported(
                "Tap/hold needs a free rule slot and no explicit CapsLock rules; threshold is 150–800 ms.")
        }
        guard excluded.count <= 32,
            excluded.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 260 && !$0.contains(where: { $0.isNewline || "\\/:\t".contains($0) })
            })
        else { throw WindowsError.unsupported("Use executable names for exclusions, separated by commas.") }
        var identities = Set<String>()
        for rule in rules {
            guard identities.insert(rule.source.description + "\t" + rule.application).inserted else {
                throw WindowsError.unsupported("Duplicate source shortcut for the same application.")
            }
        }
        let text =
            ([
                "# SwiftyToys keyboard rules: source<TAB>destination<TAB>executable", "enabled=\(enabled ? 1 : 0)",
                "reverseVertical=\(reverseVertical ? 1 : 0)", "reverseHorizontal=\(reverseHorizontal ? 1 : 0)",
                "smartCaps=\(smartCaps ? 1 : 0)", "capsThreshold=\(capsThreshold)", "capsAction=\(capsAction)",
                "languageMode=\(languageMode)", "languagePair=\(languagePair.map(String.init).joined(separator:","))",
                "exclude=\(excluded.joined(separator: ","))",
            ]
            + rules.map { "\($0.source.description)\t\($0.destination)\t\($0.application)" }).joined(separator: "\r\n")
            + "\r\n"
        guard text.utf8.count <= 32767 else { throw WindowsError.unsupported("Keyboard configuration is too large.") }
        try NativeFiles.write(Array(text.utf8), to: NativeFiles.path("keyboard.ini"))
    }
}
