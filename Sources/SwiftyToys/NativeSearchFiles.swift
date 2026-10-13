// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK

enum NativeSearchFiles {
    static func knownFolder(_ id: GUID) throws -> String {
        var id = id, value: PWSTR?
        let result = SHGetKnownFolderPath(&id, 0, nil, &value)
        guard result >= 0, let value else { throw WindowsError.status("Find search folder", result) }
        defer { CoTaskMemFree(value) }
        var length = 0; while length < 32768, value[length] != 0 { length += 1 }
        guard length < 32768 else { throw WindowsError.unsupported("Invalid search folder.") }
        return String(decoding: UnsafeBufferPointer(start: value, count: length), as: UTF16.self)
    }
    static func validFolder(_ path: String) -> Bool {
        let bytes = Array(path.utf8.prefix(3))
        guard bytes.count == 3, ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])), bytes[1] == 58, bytes[2] == 92,
            !path.split(separator: "\\").contains(where: { $0 == ".." || $0 == "." || $0.lowercased() == ".agent-private" }),
            let native = try? NativeFiles.windowsPath(path) else { return false }
        let driveType = withWideString(String(decoding:bytes,as:UTF8.self)) { GetDriveTypeW($0) }
        guard [UINT(DRIVE_FIXED),UINT(DRIVE_REMOVABLE),UINT(DRIVE_RAMDISK)].contains(driveType) else { return false }
        // Every component is checked: traversing a parent junction would escape the chosen scope.
        let components = path.split(separator: "\\", omittingEmptySubsequences: true)
        var current = ""
        for component in components {
            current += current.isEmpty ? String(component) + "\\" : String(component) + "\\"
            guard let currentPath = try? NativeFiles.windowsPath(current) else { return false }
            let attributes = withWideString(currentPath) { GetFileAttributesW($0) }
            if attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return false }
        }
        let attributes = withWideString(native) { GetFileAttributesW($0) }
        return attributes != DWORD(INVALID_FILE_ATTRIBUTES) && attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
    }
    static func collect(roots: [String], maximum: Int = 2048, textOnly: Bool = false, cancelled: () -> Bool) -> [SearchItem] {
        let deadline = GetTickCount64() + 250
        var directories = roots.filter(validFolder).map { ($0, 0) }, items: [SearchItem] = [], visited = 0
        while let (directory, depth) = directories.first, items.count < maximum, visited < 8192, !cancelled(), GetTickCount64() < deadline {
            directories.removeFirst(); visited += 1
            var entry = WIN32_FIND_DATAW()
            guard let native = try? NativeFiles.windowsPath(directory + "\\*"), let find = withWideString(native, { FindFirstFileW($0, &entry) }), find != HANDLE(bitPattern: -1) else { continue }
            defer { FindClose(find) }
            repeat {
                if cancelled() || items.count >= maximum || visited >= 8192 || GetTickCount64() >= deadline { break }
                visited += 1
                let name = withUnsafePointer(to: &entry.cFileName) { $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: Int(MAX_PATH)).prefix(while: { $0 != 0 }), as: UTF16.self)
                } }
                let attributes = entry.dwFileAttributes
                guard !name.hasPrefix("."), !["node_modules", "git", "packages", "windows", "appdata"].contains(name.lowercased()),
                    attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM) == 0 else { continue }
                let path = directory + "\\" + name
                let folder = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
                if folder {
                    if depth < 4, directories.count < 256 { directories.append((path, depth + 1)) }
                    if textOnly { continue }
                } else if textOnly && !isText(path) { continue }
                items.append(SearchItem(id: path, title: name, subtitle: directory, path: path, kind: folder ? "Folder" : "File"))
            } while FindNextFileW(find, &entry)
        }
        return items
    }
    static func isText(_ path: String) -> Bool { ["txt", "md", "markdown", "csv", "json", "log", "swift", "rs", "html", "xml"].contains(path.split(separator: ".").last?.lowercased() ?? "") }
    static func decodeSnippet(_ bytes: [UInt8]) -> String? {
        var decoded: String?
        if bytes.starts(with:[255,254]) || bytes.starts(with:[254,255]) {
            let little = bytes[0] == 255
            var words = stride(from:2,to:bytes.count - 1,by:2).map { little ? UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8 : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0+1]) }
            if let last = words.last, (0xD800...0xDBFF).contains(last) { words.removeLast() }
            decoded = String(validating:words,as:UTF16.self)
        } else {
            var data = bytes.starts(with:[239,187,191]) ? Array(bytes.dropFirst(3)) : bytes
            for _ in 0..<4 {
                if let text = String(validating:data,as:UTF8.self) { decoded = text; break }
                guard !data.isEmpty else { break }; data.removeLast()
            }
        }
        guard let decoded, !decoded.utf16.contains(0) else { return nil }; return decoded
    }
    static func preview(_ item: SearchItem) -> String {
        func bounded(_ text: String) -> String { String(decoding:text.utf16.prefix(4000),as:UTF16.self) }
        guard item.kind == "File", isText(item.path) else { return bounded(item.subtitle + "\n\n" + item.path) }
        do {
            let bytes = try readSnippet(item.path, maximum: 8192)
            guard let text = decodeSnippet(bytes) else { return bounded("This file has no plain-text preview. Press Enter to open it in its default application.\n\n" + item.path) }
            return bounded(text)
        } catch { return bounded("This file could not be previewed. Check that it is available locally.\n\n" + item.path) }
    }
    static func readSnippet(_ path: String, maximum: Int) throws -> [UInt8] {
        guard maximum > 0, maximum <= 65536, let parent = path.lastIndex(of: "\\"), validFolder(String(path[..<parent])) else { throw WindowsError.unsupported("The preview is outside a local folder.") }
        let file = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN), nil)
        })
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(file.raw, &info), info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_OFFLINE) == 0 else { throw WindowsError.unsupported("Linked and offline files are excluded from preview.") }
        var bytes = [UInt8](repeating: 0, count: maximum), count: DWORD = 0
        guard ReadFile(file.raw, &bytes, DWORD(maximum), &count, nil) else { throw WindowsError.api("Read file preview", GetLastError()) }
        bytes.removeLast(bytes.count - Int(count)); return bytes
    }
}
