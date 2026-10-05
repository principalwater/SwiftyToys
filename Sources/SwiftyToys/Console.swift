// SPDX-License-Identifier: MIT

import WinSDK

/// A GUI executable has no C stdout descriptor when launched from PowerShell.
/// Use Windows handles directly, preserving Unicode console and UTF-8 pipes.
enum Console {
    static func attach() { _ = AttachConsole(DWORD.max) }
    static func writeLine(_ line: String) {
        guard let handle = GetStdHandle(DWORD(bitPattern: -11)), handle != INVALID_HANDLE_VALUE else { return }
        var mode: DWORD = 0
        var written: DWORD = 0
        let message = line + "\r\n"
        if GetConsoleMode(handle, &mode) {
            _ = Array(message.utf16).withUnsafeBufferPointer { buffer in
                WriteConsoleW(handle, buffer.baseAddress, DWORD(buffer.count), &written, nil)
            }
        } else {
            _ = Array(message.utf8).withUnsafeBufferPointer { buffer in
                WriteFile(handle, buffer.baseAddress, DWORD(buffer.count), &written, nil)
            }
        }
    }
}
