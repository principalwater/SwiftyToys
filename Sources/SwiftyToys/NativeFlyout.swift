// SPDX-License-Identifier: MIT

import WinSDK

/// Recognized Shell hosts only. Existing nonempty window regions are preserved.
enum NativeFlyout {
    private static let ownerProperty = "SwiftyToys.Indicator.Owner"
    private static let startedProperty = "SwiftyToys.Indicator.Started"
    private typealias WindowBand = @convention(c) (HWND?, UnsafeMutablePointer<DWORD>?) -> Int32

    static func isKnown(_ window: HWND) -> Bool {
        var shellPID: DWORD = 0
        var pid: DWORD = 0
        if let shell = GetShellWindow() { GetWindowThreadProcessId(shell, &shellPID) }
        GetWindowThreadProcessId(window, &pid)
        guard shellPID != 0, pid == shellPID, GetWindowTextLengthW(window) == 0 else { return false }
        var name = Array(repeating: WCHAR(0), count: 128)
        GetClassNameW(window, &name, Int32(name.count))
        let type = String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self)
        guard ["NativeHWNDHost", "XamlExplorerHostIslandWindow"].contains(type) else { return false }
        let address = withWideString("user32.dll") { GetModuleHandleW($0) }
            .flatMap { GetProcAddress($0, "GetWindowBand") }
        guard let address else { return false }
        let getBand = unsafeBitCast(address, to: WindowBand.self)
        var band: DWORD = 0
        return getBand(window, &band) != 0 && band == 18
    }

    static func windows() -> [HWND] {
        var windows: [HWND] = []
        for type in ["NativeHWNDHost", "XamlExplorerHostIslandWindow"] {
            var previous: HWND?
            while let window = withWideString(
                type,
                { type in
                    withWideString("") { FindWindowExW(nil, previous, type, $0) }
                })
            {
                if isKnown(window) { windows.append(window) }
                previous = window
            }
        }
        return windows
    }

    private static func property(_ name: String, on window: HWND) -> UInt64? {
        withWideString(name) { GetPropW(window, $0) }.map { UInt64(UInt(bitPattern: $0)) }
    }

    private static func removeProperties(_ window: HWND) {
        _ = withWideString(ownerProperty) { RemovePropW(window, $0) }
        _ = withWideString(startedProperty) { RemovePropW(window, $0) }
    }

    @discardableResult
    static func clip(_ window: HWND, owner: UInt32, started: UInt64) -> Bool {
        guard isKnown(window), let region = CreateRectRgn(0, 0, 0, 0) else { return false }
        let kind = GetWindowRgn(window, region)
        DeleteObject(region)
        if property(ownerProperty, on: window) == UInt64(owner), property(startedProperty, on: window) == started {
            if kind == Int32(NULLREGION) { return true }
            // Shell layout updates can clear the region without clearing our
            // ownership properties. Reapply only the original unshaped state.
            guard kind == 0, let empty = CreateRectRgn(0, 0, 0, 0) else { return false }
            if SetWindowRgn(window, empty, true) != 0 { return true }
            DeleteObject(empty)
            return false
        }
        // ponytail: support the Shell's default unshaped host; retain the hide
        // fallback for shaped windows rather than serialize arbitrary regions.
        guard kind == 0, property(ownerProperty, on: window) == nil,
            property(startedProperty, on: window) == nil
        else { return false }
        guard withWideString(ownerProperty, { SetPropW(window, $0, HANDLE(bitPattern: UInt(owner))) }) else {
            return false
        }
        guard withWideString(startedProperty, { SetPropW(window, $0, HANDLE(bitPattern: UInt(started))) }) else {
            removeProperties(window)
            return false
        }
        guard let empty = CreateRectRgn(0, 0, 0, 0) else {
            removeProperties(window)
            return false
        }
        guard SetWindowRgn(window, empty, true) != 0 else {
            DeleteObject(empty)
            removeProperties(window)
            return false
        }
        // Windows owns the region after SetWindowRgn succeeds. Window properties
        // identify our exact process lifetime for watchdog/startup restoration.
        return true
    }

    static func restore(owner: UInt32? = nil, started: UInt64? = nil) {
        for window in windows() {
            guard let savedOwner = property(ownerProperty, on: window).flatMap(UInt32.init(exactly:)),
                let savedStarted = property(startedProperty, on: window)
            else { continue }
            if let owner, let started, owner != savedOwner || started != savedStarted { continue }
            if owner == nil {
                if let raw = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, savedOwner) {
                    guard let process = try? OwnedHandle(raw), let ticks = try? processStartTicks(process.raw) else {
                        continue
                    }
                    if ticks == savedStarted && WaitForSingleObject(process.raw, 0) != DWORD(WAIT_OBJECT_0) {
                        continue
                    }
                } else if GetLastError() != DWORD(ERROR_INVALID_PARAMETER) {
                    continue
                }
            }
            guard let region = CreateRectRgn(0, 0, 0, 0) else { continue }
            let kind = GetWindowRgn(window, region)
            DeleteObject(region)
            if kind == Int32(NULLREGION), SetWindowRgn(window, nil, true) == 0 { continue }
            removeProperties(window)
        }
    }
}
