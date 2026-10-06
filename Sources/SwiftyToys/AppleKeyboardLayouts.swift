// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

/// Enables already installed Boot Camp layouts using Windows input-profile APIs.
enum AppleKeyboardLayouts {
    private static let standard = ["00000409", "00000809", "00000419"]
    private static let apple = ["a0000409", "a0000809", "a0000419"]
    private typealias Install = @convention(c) (UnsafePointer<WCHAR>?, DWORD) -> Int32
    private static func tips(_ ids: [String]) -> String {
        ids.map { "0x" + String($0.suffix(4)) + ":0x" + $0 }.joined(separator: ";")
    }
    private static func preload() throws -> [String] {
        var key: HKEY?
        let status = withWideString("Keyboard Layout\\Preload") { RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(KEY_QUERY_VALUE), &key) }
        guard status == ERROR_SUCCESS, let key else { throw WindowsError.api("Read installed input profiles", DWORD(status)) }
        defer { RegCloseKey(key) }
        var substitutes: HKEY?
        _ = withWideString("Keyboard Layout\\Substitutes") { RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(KEY_QUERY_VALUE), &substitutes) }
        defer { if let substitutes { RegCloseKey(substitutes) } }
        var ids: [String] = []
        for index in 1...16 {
            var buffer = Array(repeating: WCHAR(0), count: 32); var size = DWORD(buffer.count * 2); var type: DWORD = 0
            let read = withWideString(String(index)) { name in
                buffer.withUnsafeMutableBytes { RegQueryValueExW(key, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
            }
            if read == ERROR_FILE_NOT_FOUND { break }
            var id = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self).lowercased()
            guard read == ERROR_SUCCESS, type == REG_SZ, id.utf8.count == 8, UInt32(id, radix: 16) != nil else { throw WindowsError.unsupported("Unexpected input profile value.") }
            if let substitutes {
                buffer = Array(repeating: WCHAR(0), count: 32); size = DWORD(buffer.count * 2)
                let replaced = withWideString(id) { name in
                    buffer.withUnsafeMutableBytes { RegQueryValueExW(substitutes, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
                }
                if replaced == ERROR_SUCCESS {
                    id = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self).lowercased()
                    guard type == REG_SZ, id.utf8.count == 8, UInt32(id, radix: 16) != nil else { throw WindowsError.unsupported("Invalid input-profile substitution.") }
                }
            }
            ids.append(id)
        }
        return ids
    }
    private static func withAPI<Result>(_ body: (Install) throws -> Result) throws -> Result {
        let lock = try OwnedHandle(withWideString("Local\\SwiftyToys.InputProfiles") { CreateMutexW(nil, false, $0) })
        let locked = WaitForSingleObject(lock.raw, 0)
        guard locked == DWORD(WAIT_OBJECT_0) || locked == 0x80 else { throw WindowsError.unsupported("Input profiles are already changing.") }
        defer { ReleaseMutex(lock.raw) }
        guard let library = withWideString("input.dll", { LoadLibraryExW($0, nil, 0x800) }) else { throw WindowsError.api("Load Windows input API", GetLastError()) }
        defer { FreeLibrary(library) }
        guard let address = GetProcAddress(library, "InstallLayoutOrTip") else { throw WindowsError.unsupported("Windows input-profile API unavailable.") }
        return try body(unsafeBitCast(address, to: Install.self))
    }
    static func use(english: String) throws {
        guard english == "us" || english == "uk" else { throw WindowsError.unsupported("Choose US or UK Apple English.") }
        let selected = [english == "uk" ? "a0000809" : "a0000409", "a0000419"]
        for id in selected {
            let file = id == "a0000419" ? "RussianA.dll" : id == "a0000809" ? "BritishA.dll" : "USA.dll"
            var directory = Array(repeating: WCHAR(0), count: 32768)
            let count = GetSystemDirectoryW(&directory, UINT(directory.count))
            guard count > 0, count < directory.count,
                try NativeFiles.exists(String(decoding: directory.prefix(Int(count)), as: UTF16.self) + "\\" + file) else {
                throw WindowsError.unsupported("Install Apple's Boot Camp keyboard support first. Layout DLLs are not bundled.")
            }
        }
        try withAPI { install in
            let previous = try preload()
            let original = previous.filter { standard.contains($0) || apple.contains($0) }
            let removed = original.filter { !selected.contains($0) }
            let added = selected.filter { !previous.contains($0) }
            let backup = try NativeFiles.path("apple-layouts-backup.json")
            if try !NativeFiles.exists(backup) {
                try NativeFiles.write(StateJSON.encode(["original": .string(original.joined(separator: ",")), "added": .string(added.joined(separator: ","))]), to: backup)
            }
            guard withWideString(tips(selected), { install($0, 0) }) != 0 else { throw WindowsError.unsupported("Windows could not enable the Apple layouts.") }
            guard removed.isEmpty || withWideString(tips(removed), { install($0, 1) }) != 0 else {
                _ = withWideString(tips(original)) { install($0, 0) }
                throw WindowsError.unsupported("Apple layouts added; Windows could not disable the previous profiles. Verify Windows language settings.")
            }
        }
        Console.writeLine("Apple Russian and " + (english == "uk" ? "United Kingdom" : "United States") + " layouts enabled. Previous Windows profiles have a local recovery backup.")
    }
    static func restore() throws {
        let fields = try StateJSON.decode(NativeFiles.read(NativeFiles.path("apple-layouts-backup.json")))
        guard let oldText = fields["original"]?.string, let addedText = fields["added"]?.string else { throw WindowsError.unsupported("Invalid Apple layout backup.") }
        let original = oldText.split(separator: ",").map(String.init); let added = addedText.split(separator: ",").map(String.init)
        guard original.count <= 6, added.count <= 2, original.allSatisfy({ standard.contains($0) || apple.contains($0) }), added.allSatisfy(apple.contains) else { throw WindowsError.unsupported("Unexpected layouts in recovery backup.") }
        try withAPI { install in
            guard original.isEmpty || withWideString(tips(original), { install($0, 0) }) != 0,
                added.isEmpty || withWideString(tips(added), { install($0, 1) }) != 0 else { throw WindowsError.unsupported("Windows could not restore input profiles. Backup retained.") }
        }
        Console.writeLine("Previous Windows input profiles restored.")
    }
    static func selfCheck() throws {
        guard tips(["a0000809", "a0000419"]) == "0x0809:0xa0000809;0x0419:0xa0000419" else { throw WindowsError.unsupported("Input profile format failed.") }
        try withAPI { _ in }
        Console.writeLine("PASS: native input-profile format and System32 API resolution; no profile changed")
    }
}
