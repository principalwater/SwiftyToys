// SPDX-License-Identifier: MIT

import WinSDK

/// Bounded UTF-8 local files, written atomically beside their destination.
enum NativeFiles {
    private static let appData = Result { () throws(WindowsError) -> String in
        var buffer = Array(repeating: WCHAR(0), count: 32768)
        let length = withWideString("LOCALAPPDATA") { GetEnvironmentVariableW($0, &buffer, DWORD(buffer.count)) }
        if length > 0, length < buffer.count {
            return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        }
        var folder = FOLDERID_LocalAppData
        var path: PWSTR?
        let result = SHGetKnownFolderPath(&folder, 0, nil, &path)
        guard result >= 0, let path else { throw .status("Find Local AppData", result) }
        defer { CoTaskMemFree(path) }
        var count = 0
        while count < 32768, path[count] != 0 { count += 1 }
        guard count < 32768 else { throw .unsupported("Invalid Local AppData path.") }
        return String(decoding: UnsafeBufferPointer(start: path, count: count), as: UTF16.self)
    }

    static func directory() throws -> String { try appData.get() + "\\SwiftyToys" }
    static func legacyDirectory() throws -> String { try appData.get() + "\\BrightnessCtl" }
    static func path(_ name: String) throws -> String { try directory() + "\\" + name }

    /// Extended filesystem paths work without changing Windows long-path policy.
    /// Short paths retain their existing Win32 semantics and avoid a full-size buffer.
    static func windowsPath(_ path: String) throws(WindowsError) -> String {
        let length = path.utf16.count
        guard length > 0, length < 32768, !path.utf16.contains(0),
            !path.hasPrefix("\\\\.\\"), !path.hasPrefix("\\??\\"), !path.hasPrefix("\\\\??\\") else {
            throw .unsupported("Invalid filesystem path.")
        }
        func localDrive(_ value: String) -> Bool {
            let first = value.utf8.first ?? 0
            return ((65...90).contains(first) || (97...122).contains(first)) && value.dropFirst().hasPrefix(":\\")
        }
        var plain = path, extended = false
        if path.hasPrefix("\\\\?\\") {
            extended = true
            let rest = String(path.dropFirst(4))
            if localDrive(rest) { plain = rest }
            else if rest.prefix(4).lowercased() == "unc\\" { plain = "\\\\" + rest.dropFirst(4) }
            else { throw .unsupported("Filesystem paths must use a local drive or UNC share, not a device namespace.") }
        }
        if !extended, length < 248 { return path }
        var buffer = [WCHAR](repeating: 0, count: length < 248 ? Int(MAX_PATH) : 32768)
        let count = withWideString(plain) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
        guard count > 0, count < buffer.count else { throw .api("Resolve filesystem path", GetLastError()) }
        let absolute = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        let result: String
        if localDrive(absolute) { result = "\\\\?\\" + absolute }
        else if absolute.hasPrefix("\\\\") {
            let parts = absolute.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[0] != ".", parts[0] != "?" else {
                throw .unsupported("Invalid filesystem UNC share.")
            }
            result = "\\\\?\\UNC\\" + absolute.dropFirst(2)
        } else { throw .unsupported("Filesystem paths must use a local drive or UNC share.") }
        guard result.utf16.count < 32768 else { throw .unsupported("Filesystem path exceeds the Windows limit.") }
        return result
    }

    static func exists(_ path: String) throws(WindowsError) -> Bool {
        let (attributes, error) = withWideString(try windowsPath(path)) {
            let attributes = GetFileAttributesW($0)
            return (attributes, attributes == DWORD(INVALID_FILE_ATTRIBUTES) ? GetLastError() : 0)
        }
        if attributes != DWORD(INVALID_FILE_ATTRIBUTES) { return true }
        if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) { return false }
        throw .api("Inspect local file", error)
    }

    static func createDirectory(_ path: String) throws(WindowsError) {
        let path = try windowsPath(path)
        if withWideString(path, { CreateDirectoryW($0, nil) }) { return }
        let error = GetLastError()
        let attributes = withWideString(path) { GetFileAttributesW($0) }
        guard error == DWORD(ERROR_ALREADY_EXISTS), attributes != DWORD(INVALID_FILE_ATTRIBUTES),
            attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        else { throw .api("Create settings directory", error) }
    }

    static func read(_ path: String, maximum: Int = 32767) throws -> [UInt8] {
        let handle = try OwnedHandle(
            withWideString(try windowsPath(path)) {
                CreateFileW(
                    $0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                    DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            })
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(handle.raw, &size), size.QuadPart >= 0, size.QuadPart <= maximum else {
            throw WindowsError.unsupported("Invalid local file size.")
        }
        var bytes = Array(repeating: UInt8(0), count: Int(size.QuadPart))
        var received: DWORD = 0
        guard bytes.withUnsafeMutableBytes({ ReadFile(handle.raw, $0.baseAddress, DWORD($0.count), &received, nil) }),
            received == bytes.count
        else { throw WindowsError.api("Read local file", GetLastError()) }
        return bytes
    }

    static func text(_ path: String) throws -> String {
        guard var text = String(validating: try read(path), as: UTF8.self) else {
            throw WindowsError.unsupported("Local file is not valid UTF-8.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text
    }

    static func remove(_ path: String) throws(WindowsError) {
        guard withWideString(try windowsPath(path), { DeleteFileW($0) }) || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND) else {
            throw .api("Remove local file", GetLastError())
        }
    }

    static func write(_ bytes: [UInt8], to path: String) throws {
        var guid = GUID()
        guard CoCreateGuid(&guid) >= 0 else { throw WindowsError.unsupported("Create temporary file name.") }
        var name = Array(repeating: WCHAR(0), count: 40)
        guard StringFromGUID2(&guid, &name, Int32(name.count)) > 0 else {
            throw WindowsError.unsupported("Encode temporary file name.")
        }
        let temporary = path + "." + String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self) + ".tmp"
        let destinationPath = try windowsPath(path), temporaryPath = try windowsPath(temporary)
        let handle = try OwnedHandle(
            withWideString(temporaryPath) {
                CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            })
        // Close the handle before attempting to delete an uncommitted temporary file.
        // Commit requires a closed handle too; a nested owner makes the order explicit.
        do {
            try writeAndClose(consume handle, bytes: bytes)
            guard
                withWideString(
                    temporaryPath,
                    { source in
                        withWideString(destinationPath) {
                            MoveFileExW(source, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                        }
                    })
            else { throw WindowsError.api("Commit local file", GetLastError()) }
        } catch {
            try? remove(temporary)
            throw error
        }
    }

    private static func writeAndClose(_ handle: consuming OwnedHandle, bytes: [UInt8]) throws(WindowsError) {
        guard bytes.count <= Int(DWORD.max) else { throw .unsupported("Local file is too large.") }
        var written: DWORD = 0
        guard bytes.withUnsafeBytes({ WriteFile(handle.raw, $0.baseAddress, DWORD($0.count), &written, nil) }),
            written == bytes.count, FlushFileBuffers(handle.raw)
        else { throw .api("Write local file", GetLastError()) }
    }
}
