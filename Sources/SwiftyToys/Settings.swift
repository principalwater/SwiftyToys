// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK

/// Portable user settings. Hardware identities remain only in the local file.
struct Settings: Sendable {
    var targetID: String?
    var legacyTarget: String?
    var step = 5
    var grabFunctionKeys = false
    var interceptInjectedKeys = false
    var restoreOnResume = true
    var ddcEnabled = false
    var softwareBackend = "auto"
    var hotkeys = ["Ctrl+Alt+Up", "Ctrl+Alt+Down", "Ctrl+Alt+PageUp", "Ctrl+Alt+PageDown"]
    var backend = "auto"
    var indicator = IndicatorMode.custom
    var brightness: BrightnessLevel

    init() throws {
        try NativeFiles.createDirectory(NativeFiles.directory())
        let configuration = try NativeFiles.path("config.ini")
        if try !NativeFiles.exists(configuration) {
            let defaults = [
                "# SwiftyToys: one physical SDR display. Use CLI list/select.",
                "step=5",
                "up=Ctrl+Alt+Up",
                "down=Ctrl+Alt+Down",
                "max=Ctrl+Alt+PageUp",
                "min=Ctrl+Alt+PageDown",
                "grabF1F2=0",
                "interceptInjectedKeys=0",
                "restoreOnResume=1",
                "ddcEnabled=0",
                "backend=auto",
                "osd=custom",
                "targetDisplay=",
                "",
            ].joined(separator: "\r\n")
            try NativeFiles.write(Array(defaults.utf8), to: configuration)
        }
        let brightnessFile = try NativeFiles.path("software.txt")
        let saved =
            try NativeFiles.exists(brightnessFile)
            ? try NativeFiles.text(brightnessFile) : ""
        try self.init(contents: NativeFiles.text(configuration), brightness: Int(saved.trimmingWhitespace()) ?? 100)
    }

    init(contents content: String, brightness percentage: Int = 100) throws {
        brightness = try BrightnessLevel(max(0, min(100, percentage)))
        var legacyMaximum = true
        var explicitDDC: Bool?
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingWhitespace().lowercased()
            let value = parts[1].trimmingWhitespace()
            switch key {
            case "targetdisplay": targetID = value.isEmpty ? nil : value
            case "targetoutput": legacyTarget = value.isEmpty ? nil : value
            case "step": step = max(1, min(25, Int(value) ?? 5))
            case "grabf1f2": grabFunctionKeys = value == "1" || value.lowercased() == "true"
            case "interceptinjectedkeys": interceptInjectedKeys = value == "1" || value.lowercased() == "true"
            case "restoreonresume": restoreOnResume = value == "1" || value.lowercased() == "true"
            case "hardwaremaximum": legacyMaximum = value == "1" || value.lowercased() == "true"
            case "ddcenabled":
                if ["0", "1", "false", "true"].contains(value.lowercased()) { explicitDDC = value == "1" || value.lowercased() == "true" }
                else { explicitDDC = false; Diagnostics.write("Invalid DDC preference; using software dimming.") }
            case "up": hotkeys[0] = value
            case "down": hotkeys[1] = value
            case "max": hotkeys[2] = value
            case "min": hotkeys[3] = value
            case "backend":
                backend = ["auto", "amd", "native", "hardware"].contains(value.lowercased()) ? value.lowercased() : "auto"
            case "osd": indicator = IndicatorMode(rawValue: value.lowercased()) ?? .custom
            default: break
            }
        }
        // The old maximum-backlight checkbox meant software dimming. Honor it when
        // old settings conflict; thereafter DDC is an explicit, independent choice.
        ddcEnabled = explicitDDC ?? (backend == "hardware" && !legacyMaximum)
        softwareBackend = backend == "hardware" ? "auto" : backend
        backend = ddcEnabled ? "hardware" : softwareBackend
    }

    func saveBrightness(_ level: BrightnessLevel) throws {
        try NativeFiles.write(Array("\(level.percent)\r\n".utf8), to: NativeFiles.path("software.txt"))
    }

    mutating func select(_ id: String) throws {
        try setValue(id, forKey: "targetDisplay")
        targetID = id
    }

    /// Persists an indicator choice without changing the selected monitor or level.
    mutating func setIndicator(_ mode: IndicatorMode) throws {
        try setValue(mode.rawValue, forKey: "osd")
        indicator = mode
    }

    func setValue(_ value: String, forKey key: String) throws {
        try setValues([key: value])
    }

    /// Persist the DDC switch and software preference together, before rebinding.
    func setBackend(_ mode: String) throws {
        guard ["auto", "native", "amd", "hardware"].contains(mode) else { throw WindowsError.unsupported("Invalid brightness mode.") }
        try setValues(["ddcEnabled": mode == "hardware" ? "1" : "0", "backend": mode == "hardware" ? softwareBackend : mode])
    }

    private func setValues(_ values: [String: String]) throws {
        guard values.values.allSatisfy({ !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw WindowsError.unsupported("Invalid setting value.")
        }
        let lock = try OwnedHandle(withWideString("Local\\SwiftyToys.Configuration") { CreateMutexW(nil, false, $0) })
        let acquired = WaitForSingleObject(lock.raw, 5000)
        guard acquired == DWORD(WAIT_OBJECT_0) || acquired == 0x80 else { throw WindowsError.unsupported("Settings are busy. Finish the other operation, then retry.") }
        defer { ReleaseMutex(lock.raw) }
        var content = try NativeFiles.text(NativeFiles.path("config.ini"))
        let changedKeys = Set(values.keys.map { $0.lowercased() })
        content = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { line in
                !changedKeys.contains(line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingWhitespace().lowercased() ?? "")
            }.joined(separator: "\r\n").trimmingWhitespace()
        for key in values.keys.sorted() { content += "\r\n\(key)=\(values[key]!)" }
        content += "\r\n"
        try NativeFiles.write(Array(content.utf8), to: NativeFiles.path("config.ini"))
    }

    static func selfCheck() throws {
        for (contents, expected) in [
            ("", "auto"), ("backend=hardware\nhardwareMaximum=1", "auto"),
            ("backend=hardware\nhardwareMaximum=0", "hardware"),
            ("backend=hardware\nddcEnabled=0", "auto"),
            ("backend=native\nddcEnabled=1\nhardwareMaximum=1", "hardware"),
            ("backend=amd\nddcEnabled=0", "amd"),
        ] {
            guard try Settings(contents: contents).backend == expected else { throw WindowsError.unsupported("DDC/software brightness policy check failed.") }
        }
        guard try Settings(contents: "ddcEnabled=invalid").ddcEnabled == false else { throw WindowsError.unsupported("Invalid DDC preference did not fail safely to software.") }
        Console.writeLine("PASS: explicit DDC opt-in, software-only defaults and conflicting legacy preferences")
    }
}
