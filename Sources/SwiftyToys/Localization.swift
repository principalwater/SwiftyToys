// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

/// A data-only, bounded UTF-8 language pack. English source text is the fallback key.
struct LanguagePack {
    let locale: String
    let name: String
    let strings: [String: String]
    static let english = LanguagePack(locale: "en-US", name: "English", strings: [:])
    init(locale: String, name: String, strings: [String: String]) {
        self.locale = locale; self.name = name; self.strings = strings
    }
    init(bytes: [UInt8]) throws {
        let fields = try StateJSON.decode(bytes)
        guard let locale = fields["_locale"]?.string, Self.validLocale(locale),
            let name = fields["_name"]?.string, !name.isEmpty, name.utf8.count <= 80, !name.contains("\0"),
            fields.values.allSatisfy({ $0.string != nil }) else {
            throw WindowsError.unsupported("Invalid language pack metadata or string value.")
        }
        var strings: [String: String] = [:]
        for (key, field) in fields where !key.hasPrefix("_") {
            guard !key.isEmpty, key.utf8.count <= 4096, let value = field.string, value.utf8.count <= 4096,
                !key.contains("\0"), !value.contains("\0"),
                (0...9).allSatisfy({ key.containsText("{\($0)}") == value.containsText("{\($0)}") }) else {
                throw WindowsError.unsupported("Invalid language pack string or placeholder.")
            }
            strings[key] = value
        }
        self.init(locale: locale, name: name, strings: strings)
    }
    static func validLocale(_ locale: String) -> Bool {
        let parts = locale.split(separator: "-", omittingEmptySubsequences: false)
        return locale.utf8.count <= 35 && !parts.isEmpty && (2...8).contains(parts[0].utf8.count)
            && parts.enumerated().allSatisfy { index, part in
                !part.isEmpty && part.utf8.count <= 8 && part.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (index > 0 && (48...57).contains($0))
                }
            }
    }
}

/// UI-thread-owned localization; no files are read from an input hook or paint callback.
final class Localization {
    private(set) var pack = LanguagePack.english
    init() {
        if let path = try? NativeFiles.path("language.txt"), let locale = try? NativeFiles.text(path),
            let saved = available().first(where: { $0.locale == locale.trimmingWhitespace() }) { pack = saved }
    }
    func text(_ english: String, _ values: [String] = []) -> String {
        var remainder = (pack.strings[english] ?? english)[...]
        var result = ""
        while let open = remainder.firstIndex(of: "{"), let close = remainder[open...].firstIndex(of: "}") {
            result += remainder[..<open]
            if let index = Int(remainder[remainder.index(after: open)..<close]), values.indices.contains(index) {
                result += values[index]
            } else { result += remainder[open...close] }
            remainder = remainder[remainder.index(after: close)...]
        }
        return result + remainder
    }
    func select(_ language: LanguagePack, persist: Bool = true) throws {
        if persist { try NativeFiles.write(Array(language.locale.utf8), to: NativeFiles.path("language.txt")) }
        pack = language
    }
    func available() -> [LanguagePack] {
        var packs = [LanguagePack.english]
        let executableDirectory = executablePath().split(separator: "\\").dropLast().joined(separator: "\\")
        let directories = [executableDirectory + "\\Languages", (try? NativeFiles.directory()).map { $0 + "\\Languages" }].compactMap { $0 }
        // ponytail: at most 64 small packs per directory; an indexed catalog only if this grows.
        for directory in directories {
            var data = WIN32_FIND_DATAW()
            guard let find = withWideString(directory + "\\*.json", { FindFirstFileW($0, &data) }), find != HANDLE(bitPattern: -1) else { continue }
            defer { FindClose(find) }
            for _ in 0..<64 {
                let filename = withUnsafePointer(to: &data.cFileName) {
                    $0.withMemoryRebound(to: WCHAR.self, capacity: 260) { String(decoding: UnsafeBufferPointer(start: $0, count: 260).prefix(while: { $0 != 0 }), as: UTF16.self) }
                }
                if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
                    let bytes = try? NativeFiles.read(directory + "\\" + filename),
                    let language = try? LanguagePack(bytes: bytes), filename.lowercased() == (language.locale + ".json").lowercased(), language.locale != "en-US" {
                    packs.removeAll { $0.locale == language.locale }; packs.append(language)
                }
                if !FindNextFileW(find, &data) { break }
            }
        }
        return packs
    }
    static func selfTest() throws {
        let fields: [String: StateField] = ["_locale": .string("fr-FR"), "_name": .string("Français"), "Brightness": .string("Luminosité"), "{0}%": .string("{0} %")]
        let pack = try LanguagePack(bytes: StateJSON.encode(fields))
        guard pack.strings["Brightness"] == "Luminosité", pack.strings["Missing"] == nil,
            LanguagePack.validLocale("zh-Hant-TW"), !LanguagePack.validLocale("../ru-RU"), !LanguagePack.validLocale("en--US") else {
            throw WindowsError.unsupported("Language pack fallback / locale validation failed.")
        }
        var invalid = fields; invalid["{0}%"] = .string("wrong")
        guard (try? LanguagePack(bytes: StateJSON.encode(invalid))) == nil else {
            throw WindowsError.unsupported("Language pack lost a placeholder.")
        }
        invalid = fields; invalid["_name"] = .string("bad\0name")
        guard (try? LanguagePack(bytes: StateJSON.encode(invalid))) == nil else {
            throw WindowsError.unsupported("Language pack accepted a NUL in its display name.")
        }
        let localization = Localization()
        try localization.select(pack, persist: false)
        guard localization.text("Brightness") == "Luminosité", localization.text("Missing") == "Missing",
            localization.text("{0}%", ["70"]) == "70 %", "café".containsText("fé"), "".containsText("") else {
            throw WindowsError.unsupported("Language pack lookup or substitution failed.")
        }
        let directory = executablePath().split(separator: "\\").dropLast().joined(separator: "\\") + "\\Languages"
        for locale in ["en-US", "ru-RU"] {
            let path = directory + "\\" + locale + ".json"
            if try NativeFiles.exists(path) { _ = try LanguagePack(bytes: NativeFiles.read(path)) }
        }
    }
}
