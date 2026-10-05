// SPDX-License-Identifier: MIT

import WinSDK

/// Exercises native file operations in a newly created temporary directory.
/// No display controller, user settings or recovery lease is constructed.
func testStorage() throws {
    for value in ["Ubuntu", "space in argument", "quote \" and \\", "trailing\\", "$(curl URL)\nquoted \"shellenv\""] {
        var count: Int32 = 0
        guard let arguments = withWideString("SwiftyToys " + quoteArgument(value), { CommandLineToArgvW($0, &count) })
        else { throw WindowsError.api("Parse test argument", GetLastError()) }
        defer { LocalFree(arguments) }
        guard count == 2, let argument = arguments[1] else {
            throw WindowsError.unsupported("Invalid argument round trip.")
        }
        var length = 0
        while argument[length] != 0 { length += 1 }
        guard String(decoding: UnsafeBufferPointer(start: argument, count: length), as: UTF16.self) == value else {
            throw WindowsError.unsupported("Windows argument escaping failed.")
        }
    }
    try testRecoveryStateMapping()
    var buffer = Array(repeating: WCHAR(0), count: 32768)
    let length = GetTempPathW(DWORD(buffer.count), &buffer)
    guard length > 0, length < buffer.count else { throw WindowsError.api("Get temp path", GetLastError()) }
    let directory =
        String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        + "SwiftyToys-test-\(GetCurrentProcessId())-\(GetTickCount64())"
    guard withWideString(directory, { CreateDirectoryW($0, nil) }) else {
        throw WindowsError.api("Create test directory", GetLastError())
    }
    defer { _ = withWideString(directory) { RemoveDirectoryW($0) } }
    let path = directory + "\\state-🍎.json"
    guard try NativeFiles.exists(path) == false else { throw WindowsError.unsupported("Test file already exists.") }
    defer { try? NativeFiles.remove(path) }
    let original = Array("α🍎\r\n".utf8)
    try NativeFiles.write(original, to: path)
    guard try NativeFiles.read(path) == original, try NativeFiles.text(path) == "α🍎\r\n" else {
        throw WindowsError.unsupported("Storage test: Unicode round trip failed.")
    }
    try NativeFiles.write(Array("replacement".utf8), to: path)
    guard try NativeFiles.text(path) == "replacement" else {
        throw WindowsError.unsupported("Storage test: atomic replacement failed.")
    }
    func blockedCommit() throws {
        let lock = try OwnedHandle(
            withWideString(path) {
                CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), 0, nil)
            })
        defer { _ = lock.raw }  // Retain the sharing lock through the replacement attempt.
        var refused = false
        do { try NativeFiles.write(original, to: path) } catch WindowsError.api("Commit local file", _) {
            refused = true
        }
        guard refused, try NativeFiles.text(path) == "replacement" else {
            throw WindowsError.unsupported("Storage test: failed commit did not preserve its destination.")
        }
        var data = WIN32_FIND_DATAW()
        let search = withWideString(path + ".*.tmp") { FindFirstFileW($0, &data) }
        if search != INVALID_HANDLE_VALUE {
            FindClose(search)
            throw WindowsError.unsupported("Leaked temporary file.")
        }
    }
    try blockedCommit()
    var bounded = false
    do { _ = try NativeFiles.read(path, maximum: 2) } catch WindowsError.unsupported("Invalid local file size.") {
        bounded = true
    }
    guard bounded else { throw WindowsError.unsupported("Storage test: read limit was bypassed.") }
    try NativeFiles.write([255], to: path)
    var invalid = false
    do { _ = try NativeFiles.text(path) } catch WindowsError.unsupported("Local file is not valid UTF-8.") {
        invalid = true
    }
    guard invalid else { throw WindowsError.unsupported("Storage test: invalid UTF-8 was accepted.") }
    try NativeFiles.write([], to: path)
    guard try NativeFiles.read(path).isEmpty else { throw WindowsError.unsupported("Storage test: empty file failed.") }
    Console.writeLine(
        "PASS: Windows argument escaping, Unicode, atomic replacement, failed-commit recovery, temp cleanup, bounds and UTF-8"
    )
}
