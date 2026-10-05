// SPDX-License-Identifier: MIT
import BrightnessCore

/// A validated physical key or shortcut, independent of the active text layout.
public struct KeyChord: Equatable, Sendable {
    public let modifiers: UInt8
    public let key: UInt16

    /// Parses names such as Cmd+Tab, Ctrl+Space, F2 and LeftCtrl.
    public init(_ text: String) throws {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingWhitespace().lowercased()
        }
        guard !parts.isEmpty, parts.count <= 5, parts.allSatisfy({ !$0.isEmpty }) else {
            throw KeyboardError.invalidChord(text)
        }
        var mask: UInt8 = 0
        for part in parts.dropLast() {
            guard let bit = Self.modifierNames[part], mask & bit == 0 else {
                throw KeyboardError.invalidChord(text)
            }
            mask |= bit
        }
        guard let last = parts.last, let key = Self.keyCode(last), mask == 0 || Self.modifier(for: key) == 0 else {
            throw KeyboardError.invalidChord(text)
        }
        modifiers = mask
        self.key = key
    }

    /// Returns a normalized, editable shortcut name.
    public var description: String {
        var names: [String] = []
        for (bit, name) in [(UInt8(8), "Win"), (2, "Ctrl"), (1, "Alt"), (4, "Shift")] {
            if modifiers & bit != 0 { names.append(name) }
        }
        names.append(Self.keyName(key))
        return names.joined(separator: "+")
    }

    /// Identifies combinations Windows reserves for security or workstation locking.
    public var isReserved: Bool {
        (key == 76 && modifiers & 8 != 0) || (key == 46 && modifiers & 3 == 3)
    }

    /// Returns the modifier group shared by left and right keys.
    public static func modifier(for key: UInt16) -> UInt8 {
        switch key {
        case 16, 160, 161: 4
        case 17, 162, 163: 2
        case 18, 164, 165: 1
        case 91, 92: 8
        default: 0
        }
    }

    /// Uses a concrete left-side virtual key when an output name is generic.
    public static func concrete(_ key: UInt16) -> UInt16 {
        switch key {
        case 16: 160
        case 17: 162
        case 18: 164
        default: key
        }
    }

    /// Compares generic Ctrl/Alt/Shift with either corresponding physical key.
    public static func matches(_ configured: UInt16, _ physical: UInt16) -> Bool {
        if (16...18).contains(configured) {
            return modifier(for: configured) == modifier(for: physical)
        }
        return configured == physical || (configured == 91 && physical == 92)
    }

    private static let modifierNames: [String: UInt8] = [
        "ctrl": 2, "control": 2, "alt": 1, "option": 1, "shift": 4,
        "win": 8, "windows": 8, "cmd": 8, "command": 8, "⌘": 8,
    ]
    private static let names: [String: UInt16] = [
        "backspace": 8, "tab": 9, "enter": 13, "return": 13, "shift": 16, "ctrl": 17,
        "control": 17, "alt": 18, "option": 18, "pause": 19, "capslock": 20, "escape": 27,
        "esc": 27, "space": 32, "pageup": 33, "pagedown": 34, "end": 35, "home": 36,
        "left": 37, "up": 38, "right": 39, "down": 40, "printscreen": 44, "insert": 45,
        "delete": 46, "win": 91, "cmd": 91, "leftwin": 91, "rightwin": 92,
        "menu": 93, "numlock": 144, "scrolllock": 145,
        "leftshift": 160, "rightshift": 161, "leftctrl": 162, "rightctrl": 163,
        "leftalt": 164, "rightalt": 165, "volumeup": 175, "volumedown": 174, "mute": 173,
        "playpause": 179, "nexttrack": 176, "previoustrack": 177,
        "semicolon": 186, "oemplus": 187, "comma": 188, "oemminus": 189,
        "period": 190, "slash": 191, "backtick": 192, "leftbracket": 219,
        "backslash": 220, "rightbracket": 221, "quote": 222,
    ]
    private static func keyCode(_ text: String) -> UInt16? {
        if let named = names[text] { return named }
        if text.hasPrefix("f"), let number = UInt16(text.dropFirst()), (1...24).contains(number) {
            return 111 + number
        }
        if text.hasPrefix("numpad"), let number = UInt16(text.dropFirst(6)), number <= 9 { return 96 + number }
        if text.count == 1, let code = text.uppercased().unicodeScalars.first?.value,
            (48...57).contains(code) || (65...90).contains(code)
        {
            return UInt16(code)
        }
        return nil
    }
    private static func keyName(_ key: UInt16) -> String {
        if (48...57).contains(key) || (65...90).contains(key) { return String(Unicode.Scalar(key)!) }
        if (112...135).contains(key) { return "F\(key - 111)" }
        if (96...105).contains(key) { return "Numpad\(key - 96)" }
        let preferred: [UInt16: String] = [
            8: "Backspace", 9: "Tab", 13: "Enter", 16: "Shift", 17: "Ctrl", 18: "Alt", 19: "Pause",
            20: "CapsLock", 27: "Escape", 32: "Space", 33: "PageUp", 34: "PageDown", 35: "End",
            36: "Home", 37: "Left", 38: "Up", 39: "Right", 40: "Down", 44: "PrintScreen",
            45: "Insert", 46: "Delete", 91: "Win", 92: "RightWin", 93: "Menu",
            160: "LeftShift", 161: "RightShift", 162: "LeftCtrl", 163: "RightCtrl",
            164: "LeftAlt", 165: "RightAlt",
        ]
        if let name = preferred[key] { return name }
        return names.filter { $0.value == key }.map(\.key).sorted().first ?? "Unknown"
    }
}

/// A configuration error suitable for display next to the editable rule.
public enum KeyboardError: Error, CustomStringConvertible, Sendable {
    case invalidChord(String)
    case invalidRule(String)
    public var description: String {
        switch self {
        case .invalidChord(let value): "Invalid key or shortcut: \(value). Example: Ctrl+Space or Win+Tab."
        case .invalidRule(let reason): reason
        }
    }
}

/// One explicit key/shortcut transformation or native action.
public struct RemapRule: Equatable, Sendable {
    public let source: KeyChord
    public let target: KeyChord?
    public let action: String?
    public let application: String

    /// Validates keys, reserved shortcuts and an optional executable basename.
    public init(from: String, to: String, application: String = "") throws {
        source = try KeyChord(from)
        let actionName = to.lowercased().trimmingWhitespace()
        if ["switch language", "pin window", "disable key"].contains(actionName) {
            action = actionName
            target = nil
        } else {
            target = try KeyChord(to)
            action = nil
        }
        let app = application.trimmingWhitespace().lowercased()
        guard app.utf8.count <= 260,
            !app.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\\" || $0 == "/" || $0 == ":" }),
            !source.isReserved, target?.isReserved != true
        else {
            throw KeyboardError.invalidRule(
                "Use an executable name such as notepad.exe; reserved Windows shortcuts cannot be remapped.")
        }
        guard source != target else { throw KeyboardError.invalidRule("The source and destination are identical.") }
        self.application = app
    }

    /// Presents the destination in the editor and configuration file.
    public var destination: String { target?.description ?? action ?? "Disable key" }

    /// Familiar shortcuts, while preserving every Windows combination not listed.
    public static var macPreset: [RemapRule] {
        var pairs = [
            ("Ctrl+Space", "Switch language"), ("Win+Tab", "Alt+Tab"),
            ("Win+Shift+Tab", "Alt+Shift+Tab"), ("Win+Ctrl+T", "Pin window"),
        ]
        for key in ["C", "V", "X", "Z", "A", "F", "S", "W", "T"] { pairs.append(("Win+\(key)", "Ctrl+\(key)")) }
        pairs += [("Win+Shift+Z", "Ctrl+Shift+Z"), ("Win+Shift+T", "Ctrl+Shift+T")]
        pairs += [
            ("Alt+Left", "Ctrl+Left"), ("Alt+Right", "Ctrl+Right"), ("Alt+Backspace", "Ctrl+Backspace"),
            ("Win+Left", "Home"), ("Win+Right", "End"), ("Win+Shift+Left", "Shift+Home"),
            ("Win+Shift+Right", "Shift+End"), ("Win+Up", "Ctrl+Home"), ("Win+Down", "Ctrl+End"),
            ("Win+Shift+4", "Win+Shift+S"), ("Win+Space", "Win+S"),
        ]
        return pairs.compactMap { try? RemapRule(from: $0.0, to: $0.1) }
    }
}
