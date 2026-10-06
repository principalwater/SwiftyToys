// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK
import WindowsDisplayABI

/// A checked error returned by a native Windows or display-driver operation.
enum WindowsError: Error, Sendable, CustomStringConvertible {
    case api(String, UInt32)
    case status(String, Int32)
    case unsupported(String)

    var description: String {
        switch self {
        case .api(let operation, let code): Self.describe(operation, code, kind: "Win32")
        case .status(let operation, let code): Self.describe(operation, UInt32(bitPattern: code), kind: "status")
        case .unsupported(let reason): reason
        }
    }
    private static func describe(_ operation: String, _ code: DWORD, kind: String) -> String {
        let win32 = code & 0xFFFF_0000 == 0x8007_0000 ? code & 0xFFFF : code
        var buffer = [WCHAR](repeating: 0, count: 4096)
        var count = FormatMessageW(
            DWORD(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS), nil, win32, 0x0409, &buffer,
            DWORD(buffer.count), nil)
        if count == 0, let module = withWideString("ntdll.dll", { GetModuleHandleW($0) }) {
            count = FormatMessageW(
                DWORD(FORMAT_MESSAGE_FROM_HMODULE | FORMAT_MESSAGE_IGNORE_INSERTS), module, code, 0x0409, &buffer,
                DWORD(buffer.count), nil)
        }
        let explanation = String(decoding: buffer.prefix(Int(count)), as: UTF16.self).split(whereSeparator: {
            $0 == "\r" || $0 == "\n"
        }).joined(separator: " ")
        let message =
            explanation.isEmpty
            ? "\(operation) failed (\(kind) \(code))." : "\(operation): \(explanation) (\(kind) \(code))."
        let next: String
        switch code {
        case 0x8037_0102, 0x8037_0114:
            next =
                "Enable Virtual Machine Platform and virtualization in firmware or your supported boot configuration, then restart Windows."
        case 0x8007_019E:
            next = "Install the Windows WSL components and restart Windows if requested."
        default:
            switch win32 {
            case DWORD(ERROR_ACCESS_DENIED):
                next = "Check permissions. If this action requests administrator consent, approve the Windows prompt."
            case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND):
                next = "Check that the required file or component is installed, then retry."
            case DWORD(ERROR_SHARING_VIOLATION), DWORD(ERROR_LOCK_VIOLATION):
                next = "The resource is busy. Finish the other operation, then retry."
            case DWORD(ERROR_NOT_ENOUGH_MEMORY), DWORD(ERROR_OUTOFMEMORY):
                next = "Close unused applications, then retry."
            case DWORD(ERROR_DEVICE_NOT_CONNECTED): next = "Reconnect the affected device and refresh its status."
            case DWORD(ERROR_CANCELLED): next = "The action was cancelled. Retry when ready."
            default: next = ""
            }
        }
        return next.isEmpty ? message : message + "\n\n" + next
    }
    static func selfCheck() throws {
        let denied = WindowsError.api("Open file", DWORD(ERROR_ACCESS_DENIED)).description
        let status = WindowsError.status("Open file", Int32(bitPattern: 0x8007_0005)).description
        guard denied.hasPrefix("Open file: "), status.hasPrefix("Open file: "),
            WindowsError.unsupported("Retry the action.").description == "Retry the action."
        else {
            throw WindowsError.unsupported("Windows error readability check failed.")
        }
        guard
            WindowsError.status("Start WSL", Int32(bitPattern: 0x8037_0102)).description.hasSuffix(
                "then restart Windows.")
        else {
            throw WindowsError.unsupported("WSL recovery instruction check failed.")
        }
        Console.writeLine("PASS: readable Win32/HRESULT explanations and explicit recovery instructions preserved")
    }
}
/// Owns one Windows handle. Swift forbids accidental copies and double closes.
struct OwnedHandle: ~Copyable {
    let raw: HANDLE

    init(_ raw: HANDLE?) throws(WindowsError) {
        guard let raw, raw != INVALID_HANDLE_VALUE else { throw .api("Create handle", GetLastError()) }
        self.raw = raw
    }

    deinit { CloseHandle(raw) }
}
/// Keeps a UTF-16 pointer alive only for the duration of a native call.
func withWideString<Result>(_ value: String, _ body: (UnsafePointer<WCHAR>) throws -> Result) rethrows -> Result {
    try (Array(value.utf16) + [0]).withUnsafeBufferPointer { try body($0.baseAddress!) }
}
/// Resolve a trusted Windows executable independently of PATH and App Paths.
func systemExecutable(_ name: String) throws -> String {
    var directory = [WCHAR](repeating: 0, count: 32768)
    let size = GetSystemDirectoryW(&directory, UINT(directory.count))
    guard size > 0, size < directory.count else {
        throw WindowsError.api("Resolve Windows system directory", GetLastError())
    }
    return String(decoding: directory.prefix(Int(size)), as: UTF16.self) + "\\" + name
}
/// Decodes the bounded, null-terminated UTF-16 fields imported from Windows SDK.
func wideString<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { bytes in
        let words = bytes.bindMemory(to: UInt16.self)
        return String(decoding: words.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
}
func setWideString<Value>(_ value: String, in field: inout Value) {
    withUnsafeMutableBytes(of: &field) { bytes in
        let words = bytes.bindMemory(to: UInt16.self)
        words.initialize(repeating: 0)
        for (index, word) in value.utf16.prefix(max(0, words.count - 1)).enumerated() { words[index] = word }
    }
}
/// A thread-safe message destination without sharing thread-affine UI objects.
struct MessageDestination: Sendable {
    let address: UInt
    init(_ window: HWND) { address = UInt(bitPattern: window) }
    var window: HWND { HWND(bitPattern: address)! }
    func post(_ message: UINT, value: Int = 0, data: Int = 0) -> Bool {
        PostMessageW(window, message, WPARAM(bitPattern: Int64(value)), LPARAM(data))
    }
}
/// Service cross-thread sent messages while joining a worker, without dispatching queued UI commands.
func waitForWindowEvent(_ event: HANDLE, timeout: DWORD) -> DWORD {
    let deadline = GetTickCount64() + UInt64(timeout)
    var handle: HANDLE? = event
    while true {
        let now = GetTickCount64()
        let remaining = now < deadline ? DWORD(deadline - now) : 0
        let result = MsgWaitForMultipleObjectsEx(
            1, &handle, remaining, DWORD(QS_SENDMESSAGE), DWORD(MWMO_INPUTAVAILABLE))
        guard result == DWORD(WAIT_OBJECT_0) + 1 else { return result }
        var message = MSG()
        // PeekMessage dispatches sent messages; PM_QS_SENDMESSAGE leaves clicks/timers queued.
        PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE | PM_QS_SENDMESSAGE))
        if GetTickCount64() >= deadline { return WaitForSingleObject(event, 0) }
    }
}
/// Local diagnostics stay in the user installation and may contain native error details.
enum Diagnostics {
    private static let lock = Mutex(())
    static func write(_ message: String) {
        lock.withLock { _ in
            guard let directory = try? NativeFiles.directory(), let path = try? NativeFiles.path("startup.log") else {
                return
            }
            try? NativeFiles.createDirectory(directory)
            let raw = withWideString(path) {
                CreateFileW(
                    $0, DWORD(FILE_APPEND_DATA), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_ALWAYS),
                    DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let handle = try? OwnedHandle(raw) else { return }
            var time = SYSTEMTIME()
            GetSystemTime(&time)
            func padded(_ value: WORD, _ width: Int = 2) -> String {
                let text = String(value)
                return String(repeating: "0", count: max(0, width - text.count)) + text
            }
            let date =
                "\(padded(time.wYear, 4))-\(padded(time.wMonth))-\(padded(time.wDay))T\(padded(time.wHour)):\(padded(time.wMinute)):\(padded(time.wSecond))Z"
            let bytes = Array("\(date)  \(message)\r\n".utf8)
            var written: DWORD = 0
            _ = bytes.withUnsafeBytes { WriteFile(handle.raw, $0.baseAddress, DWORD($0.count), &written, nil) }
        }
    }
}

/// Windows identifiers and paths use ordinal case folding, independent of locale.
func equalWindowsNames(_ first: String, _ second: String) -> Bool {
    withWideString(first) { lhs in
        withWideString(second) { rhs in CompareStringOrdinal(lhs, -1, rhs, -1, true) == CSTR_EQUAL }
    }
}
