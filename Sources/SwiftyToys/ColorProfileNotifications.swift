// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK

let colorProfileChangedMessage: UINT = 0x8039

/// The immutable event owner outlives both the UI and its background wait.
private final class ColorNotificationStop: @unchecked Sendable {
    let event: OwnedHandle
    let registered = Mutex(false)
    init() throws { event = try OwnedHandle(CreateEventW(nil, true, false, nil)) }
}

/// Watches the documented WCS trees only while the Brightness page is visible.
final class ColorProfileNotifications {
    private let stop: ColorNotificationStop
    private let thread: NativeThread

    init(destination: MessageDestination) throws {
        let stop = try ColorNotificationStop()
        self.stop = stop
        thread = try NativeThread(name: "SwiftyToys color notifications") {
            var keys: [HKEY] = []
            var events: [HANDLE?] = [stop.event.raw]
            var stopped = false
            defer {
                if !stopped { _ = destination.post(colorProfileChangedMessage, value: 1) }
                for event in events.dropFirst() { if let event { CloseHandle(event) } }
                for key in keys { RegCloseKey(key) }
            }
            let locations = [
                (HKEY_CURRENT_USER, "Software\\Microsoft\\Windows NT\\CurrentVersion\\ICM\\ProfileAssociations\\Display\\{4d36e96e-e325-11ce-bfc1-08002be10318}"),
                (HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e96e-e325-11ce-bfc1-08002be10318}"),
            ]
            for (root, location) in locations {
                var candidate = location
                var key: HKEY?
                while !candidate.isEmpty {
                    let code = withWideString(candidate) { RegOpenKeyExW(root, $0, 0, REGSAM(KEY_NOTIFY), &key) }
                    if code == ERROR_SUCCESS { break }
                    guard code == ERROR_FILE_NOT_FOUND, let separator = candidate.lastIndex(of: "\\") else { return }
                    candidate = String(candidate[..<separator])
                }
                guard let key else { return }
                keys.append(key)
                guard let event = CreateEventW(nil, true, false, nil) else { return }
                events.append(event)
                guard RegNotifyChangeKeyValue(key, true, DWORD(REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET), event, true) == ERROR_SUCCESS else { return }
            }
            stop.registered.withLock { $0 = true }
            // Cover a change between the initial UI snapshot and notification registration.
            _ = destination.post(colorProfileChangedMessage)
            while true {
                let result = WaitForMultipleObjects(DWORD(events.count), &events, false, DWORD(INFINITE))
                if result == DWORD(WAIT_OBJECT_0) { stopped = true; return }
                guard result > DWORD(WAIT_OBJECT_0), result < DWORD(WAIT_OBJECT_0) + DWORD(events.count) else { return }
                let index = Int(result - DWORD(WAIT_OBJECT_0))
                guard ResetEvent(events[index]),
                    RegNotifyChangeKeyValue(keys[index - 1], true, DWORD(REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET), events[index], true) == ERROR_SUCCESS else { return }
                _ = destination.post(colorProfileChangedMessage)
            }
        }
    }
    deinit { SetEvent(stop.event.raw) }

    static func selfCheck() throws {
        guard let window = withWideString("STATIC", {
            CreateWindowExW(0, $0, nil, 0, 0, 0, 1, 1, HWND(bitPattern: -3), nil, GetModuleHandleW(nil), nil)
        }) else { throw WindowsError.api("Create hidden color notification fixture", GetLastError()) }
        defer { DestroyWindow(window) }
        let watcher = try ColorProfileNotifications(destination: MessageDestination(window))
        SetEvent(watcher.stop.event.raw)
        for _ in 0..<100 {
            if watcher.thread.isFinished {
                guard watcher.stop.registered.withLock({ $0 }) else {
                    throw WindowsError.unsupported("Windows color notifications could not be registered.")
                }
                return
            }
            Sleep(10)
        }
        throw WindowsError.unsupported("Color notification worker did not stop.")
    }
}
