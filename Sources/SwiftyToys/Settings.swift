// SPDX-License-Identifier: MIT

import BrightnessCore

/// Portable user settings. Hardware identities remain only in the local file.
struct Settings: Sendable {
    var targetID: String?
    var legacyTarget: String?
    var step = 5
    var grabFunctionKeys = false
    var interceptInjectedKeys = false
    var restoreOnResume = true
    var hardwareMaximum = true
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
                "hardwareMaximum=1",
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
        brightness = try BrightnessLevel(
            max(0, min(100, Int(saved.trimmingWhitespace()) ?? 100)))
        let content = try NativeFiles.text(configuration)
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
            case "hardwaremaximum": hardwareMaximum = value == "1" || value.lowercased() == "true"
            case "up": hotkeys[0] = value
            case "down": hotkeys[1] = value
            case "max": hotkeys[2] = value
            case "min": hotkeys[3] = value
            case "backend":
                backend = ["auto", "amd", "native"].contains(value.lowercased()) ? value.lowercased() : "auto"
            case "osd": indicator = IndicatorMode(rawValue: value.lowercased()) ?? .custom
            default: break
            }
        }
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
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw WindowsError.unsupported("Invalid setting value.")
        }
        var content = try NativeFiles.text(NativeFiles.path("config.ini"))
        content = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { line in
                line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?
                    .trimmingWhitespace().lowercased() != key.lowercased()
            }.joined(separator: "\r\n").trimmingWhitespace()
        content += "\r\n\(key)=\(value)\r\n"
        try NativeFiles.write(Array(content.utf8), to: NativeFiles.path("config.ini"))
    }
}
