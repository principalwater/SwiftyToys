// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

private struct MagnifierSearch {
    let owned: HWND?
    var found = false
}

private func findMagnifierWindow(_ window: HWND?, _ data: LPARAM) -> WindowsBool {
    guard let window, let search = UnsafeMutablePointer<MagnifierSearch>(bitPattern: Int(data)) else { return true }
    if let owned = search.pointee.owned, window == owned || GetParent(window) == owned { return true }
    var name = [WCHAR](repeating: 0, count: 128)
    GetClassNameW(window, &name, Int32(name.count))
    let type = String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self)
    if type == "Magnifier" || type == "MagUIClass" { search.pointee.found = true }
    return search.pointee.found ? false : true
}

private func cursorDimmingProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window,
        let context = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(window, Int32(GWLP_USERDATA))))
    else { return DefWindowProcW(window, message, value, data) }
    return Unmanaged<SoftwareCursorDimmingSession>.fromOpaque(context).takeUnretainedValue()
        .handle(window, message, value, data)
}

/// A 1x, windowed Magnification viewport owned entirely by the display executor.
/// It scales the composed image and cursor together; it never writes display gamma.
/// Protected surfaces and exclusive fullscreen applications require physical validation.
final class SoftwareCursorDimmingSession {
    private static let windowClass = "SwiftyToys.SoftwareCursorDimming"

    /// OSD stays behind this process's visible viewport, so its first frame is
    /// dimmed too. Resolve through Windows; never transfer the actor's session.
    static func activeViewport() -> HWND? {
        guard let window = withWideString(windowClass, { FindWindowW($0, nil) }), IsWindowVisible(window) else { return nil }
        var owner: DWORD = 0
        GetWindowThreadProcessId(window, &owner)
        return owner == GetCurrentProcessId() ? window : nil
    }
    private static let frameTimer: UINT_PTR = 1
    private let threadID = GetCurrentThreadId()
    private let output: DisplayOutput
    private var source = RECT()
    private var host: HWND?
    private var control: HWND?
    private var initialized = false
    private var registeredClass = false
    private var sessionNotifications = false
    private var cursorRestoreNeeded = false
    private var appliedPercent: Int?
    private var invalidationMessage: UINT?
    private var traceCount = 0
    private(set) var isActive = false
    private(set) var isValid = true
    private(set) var failure: WindowsError?

    init(output: DisplayOutput) throws(WindowsError) {
        self.output = output
        do throws(WindowsError) {
            source = try Self.checkedBounds(output)
            try Self.requireVisibleCursor()
            guard MagInitialize() else { throw WindowsError.api("Initialize magnification", GetLastError()) }
            initialized = true
            try checkMagnifierState()
            try createWindows()
        } catch {
            closeWindows()
            if initialized { MagUninitialize(); initialized = false }
            throw error
        }
    }

    /// Call only after the controller durably saves its lease and starts recovery.
    func apply(_ level: BrightnessLevel) throws(WindowsError) {
        precondition(GetCurrentThreadId() == threadID)
        if level.percent == 100 { try restore(); return }
        if !isActive || appliedPercent != level.percent { trace("apply \(level.percent)%") }
        guard isValid else {
            throw failure ?? .unsupported("Software cursor dimming was invalidated. Select the display again.")
        }
        if isActive, appliedPercent == level.percent { return }
        do throws(WindowsError) {
            if !isActive {
                let bounds = try Self.checkedBounds(output)
                guard Self.sameRect(bounds, source) else {
                    throw WindowsError.unsupported("Display bounds changed. Select the display again.")
                }
                try Self.requireVisibleCursor()
                try checkMagnifierState()
                if host == nil { try createWindows() }
            }
            guard let host, let control else {
                throw WindowsError.unsupported("Software cursor viewport is unavailable.")
            }
            // Keep the existing viewport and its previous frame during adjacent changes.
            var effect = Self.colorEffect(level.percent)
            guard MagSetColorEffect(control, &effect) else {
                throw WindowsError.api("Set software brightness", GetLastError())
            }
            if isActive {
                guard InvalidateRect(control, nil, false) else {
                    throw WindowsError.api("Repaint software brightness", GetLastError())
                }
            } else { try refreshFrame(host, control) }
            if !isActive {
                guard SetTimer(host, Self.frameTimer, 16, nil) != 0 else {
                    throw WindowsError.api("Start software cursor refresh", GetLastError())
                }
                ShowWindow(host, SW_SHOWNOACTIVATE)
                UpdateWindow(host)
                guard isValid else {
                    throw failure ?? WindowsError.unsupported("Software cursor dimming was invalidated.")
                }
                // Record intent before the global call, so partial failure still restores it.
                cursorRestoreNeeded = true
                guard MagShowSystemCursor(false) else {
                    throw WindowsError.api("Show magnified cursor", GetLastError())
                }
                guard isValid else {
                    // A sent session/display message may invalidate during a native call.
                    cursorRestoreNeeded = true
                    throw failure ?? WindowsError.unsupported("Software cursor dimming was invalidated.")
                }
                isActive = true
            }
            appliedPercent = level.percent
        } catch {
            invalidate(error)
            throw error
        }
    }

    /// Restore visibility before destroying the viewport; release its native buffers at 100%.
    func restore() throws(WindowsError) {
        precondition(GetCurrentThreadId() == threadID)
        if host != nil || cursorRestoreNeeded || !isValid { trace("restore") }
        let error = deactivate()
        closeWindows()
        if let error { throw error }
    }

    private func deactivate() -> WindowsError? {
        var error: WindowsError?
        if cursorRestoreNeeded {
            if MagShowSystemCursor(true) {
                cursorRestoreNeeded = false
            } else {
                error = .api("Restore system cursor visibility", GetLastError())
            }
        }
        if let host {
            KillTimer(host, Self.frameTimer)
            ShowWindow(host, SW_HIDE)
        }
        isActive = false
        appliedPercent = nil
        return error
    }

    private func invalidate(_ error: WindowsError) {
        isValid = false
        failure = deactivate() ?? error
    }

    fileprivate func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        switch message {
        case UINT(WM_TIMER):
            if value == Self.frameTimer, isActive, let control {
                do { try refreshFrame(window, control) } catch { invalidate(error) }
            }
            return 0
        case UINT(WM_DISPLAYCHANGE), UINT(WM_SETTINGCHANGE), UINT(WM_DEVICECHANGE),
            UINT(WM_WTSSESSION_CHANGE), UINT(WM_POWERBROADCAST), UINT(WM_CLOSE):
            // Native callback: bounded visibility/window work only; no discovery or lease I/O.
            invalidationMessage = message
            invalidate(.unsupported("The display or Windows session changed. Select the display again."))
            return message == UINT(WM_POWERBROADCAST) ? 1 : 0
        case UINT(WM_MOUSEACTIVATE): return LRESULT(MA_NOACTIVATE)
        case UINT(WM_NCHITTEST): return LRESULT(HTTRANSPARENT)
        case UINT(WM_NCDESTROY):
            SetWindowLongPtrW(window, Int32(GWLP_USERDATA), 0)
        default: break
        }
        return DefWindowProcW(window, message, value, data)
    }

    private func refreshFrame(_ host: HWND, _ control: HWND) throws(WindowsError) {
        guard MagSetWindowSource(control, source) else {
            throw .api("Refresh software cursor source", GetLastError())
        }
        guard SetWindowPos(host, HWND(bitPattern: -1), 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) else {
            throw .api("Refresh software cursor viewport", GetLastError())
        }
        guard InvalidateRect(control, nil, false) else {
            throw .api("Refresh magnified cursor", GetLastError())
        }
    }

    private func createWindows() throws(WindowsError) {
        let instance = GetModuleHandleW(nil)
        if !registeredClass {
            let atom = withWideString(Self.windowClass) { name in
                var cls = WNDCLASSEXW()
                cls.cbSize = UINT(MemoryLayout.size(ofValue: cls))
                cls.lpfnWndProc = cursorDimmingProcedure
                cls.hInstance = instance
                cls.lpszClassName = name
                return RegisterClassExW(&cls)
            }
            guard atom != 0 else { throw .api("Register software cursor viewport", GetLastError()) }
            registeredClass = true
        }
        let width = source.right - source.left; let height = source.bottom - source.top
        host = withWideString(Self.windowClass) {
            CreateWindowExW(DWORD(WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW),
                $0, nil, DWORD(WS_POPUP), source.left, source.top, width, height, nil, nil, instance, nil)
        }
        guard let host else { throw .api("Create software cursor viewport", GetLastError()) }
        SetWindowLongPtrW(host, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
        guard SetLayeredWindowAttributes(host, 0, 255, DWORD(LWA_ALPHA)) else {
            throw .api("Configure software cursor viewport", GetLastError())
        }
        control = withWideString("Magnifier") {
            CreateWindowExW(0, $0, nil, DWORD(WS_CHILD | WS_VISIBLE) | DWORD(MS_SHOWMAGNIFIEDCURSOR),
                0, 0, width, height, host, nil, instance, nil)
        }
        guard let control else { throw .api("Create magnified cursor", GetLastError()) }
        var excluded: HWND? = host
        var transform = MAGTRANSFORM()
        withUnsafeMutableBytes(of: &transform) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for index in [0, 4, 8] { values[index] = 1 }
        }
        guard MagSetWindowFilterList(control, DWORD(MW_FILTERMODE_EXCLUDE), 1, &excluded),
            MagSetWindowTransform(control, &transform), MagSetWindowSource(control, source)
        else { throw .api("Configure magnified cursor", GetLastError()) }
        guard WTSRegisterSessionNotification(host, DWORD(NOTIFY_FOR_THIS_SESSION)) else {
            throw .api("Monitor software cursor session", GetLastError())
        }
        sessionNotifications = true
        trace("create viewport")
    }

    private func trace(_ event: String) {
        // Bound temporary lifecycle diagnostics; never log from the frame/input callbacks.
        guard traceCount < 32 else { return }
        traceCount += 1
        Diagnostics.write("software cursor: \(event); active=\(isActive) valid=\(isValid) previous=\(appliedPercent ?? 100) message=\(invalidationMessage ?? 0) failure=\(failure?.description ?? "none")")
    }

    private func closeWindows() {
        if let host {
            KillTimer(host, Self.frameTimer)
            if sessionNotifications { WTSUnRegisterSessionNotification(host) }
            sessionNotifications = false
            // The session owns the HWND; its userdata never retains the session.
            SetWindowLongPtrW(host, Int32(GWLP_USERDATA), 0)
            DestroyWindow(host)
        }
        control = nil; host = nil
        if registeredClass {
            withWideString(Self.windowClass) { UnregisterClassW($0, GetModuleHandleW(nil)) }
            registeredClass = false
        }
    }

    private static func checkedBounds(_ output: DisplayOutput) throws(WindowsError) -> RECT {
        var paths: UINT32 = 0; var modes: UINT32 = 0
        let result = GetDisplayConfigBufferSizes(UINT32(QDC_ONLY_ACTIVE_PATHS), &paths, &modes)
        guard result == ERROR_SUCCESS else { throw .api("Read cursor display topology", UInt32(result)) }
        // Count raw paths as discovery can omit outputs whose device-name query fails.
        let displays = try discoverDisplays()
        guard supports(output, activePathCount: Int(paths), displays: displays), GetSystemMetrics(SM_CMONITORS) == 1,
            let monitor = monitorForDevice(output.device)
        else { throw .unsupported("Software cursor dimming needs exactly one physical, independent SDR output.") }
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout.size(ofValue: info))
        guard GetMonitorInfoW(monitor, &info), info.rcMonitor.right > info.rcMonitor.left,
            info.rcMonitor.bottom > info.rcMonitor.top
        else { throw .api("Read software cursor display bounds", GetLastError()) }
        return info.rcMonitor
    }

    private static func requireVisibleCursor() throws(WindowsError) {
        var cursor = CURSORINFO()
        cursor.cbSize = DWORD(MemoryLayout.size(ofValue: cursor))
        guard GetCursorInfo(&cursor), cursor.flags & DWORD(CURSOR_SHOWING) != 0 else {
            throw .unsupported("Software cursor dimming needs the original Windows cursor to be visible.")
        }
    }

    private func checkMagnifierState() throws(WindowsError) {
        var effect = MAGCOLOREFFECT(); var zoom: Float = 0; var x: Int32 = 0; var y: Int32 = 0
        guard MagGetFullscreenColorEffect(&effect), MagGetFullscreenTransform(&zoom, &x, &y) else {
            throw .api("Read Windows magnifier state", GetLastError())
        }
        let identity = withUnsafeBytes(of: effect) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            return (0..<25).allSatisfy { values[$0] == ($0 % 6 == 0 ? 1 : 0) }
        }
        var search = MagnifierSearch(owned: host)
        withUnsafeMutablePointer(to: &search) { pointer in
            EnumWindows({ window, data in
                guard findMagnifierWindow(window, data).boolValue else { return false }
                EnumChildWindows(window, findMagnifierWindow, data)
                return UnsafeMutablePointer<MagnifierSearch>(bitPattern: Int(data))!.pointee.found ? false : true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        guard identity, zoom == 1, x == 0, y == 0, !search.found else {
            throw .unsupported("Close Windows Magnifier before using software cursor dimming.")
        }
    }

    private static func supports(_ output: DisplayOutput, activePathCount: Int, displays: [DisplayOutput]) -> Bool {
        guard activePathCount == 1, displays.count == 1, output.isPhysical, !output.isCloned, !output.isHDR,
            let current = displays.first else { return false }
        return current.isPhysical && !current.isCloned && !current.isHDR && current.id == output.id
            && current.adapterLow == output.adapterLow && current.adapterHigh == output.adapterHigh
            && current.source == output.source && current.target == output.target && current.device == output.device
    }

    private static func sameRect(_ lhs: RECT, _ rhs: RECT) -> Bool {
        lhs.left == rhs.left && lhs.top == rhs.top && lhs.right == rhs.right && lhs.bottom == rhs.bottom
    }

    private static func colorEffect(_ percent: Int) -> MAGCOLOREFFECT {
        var effect = MAGCOLOREFFECT()
        withUnsafeMutableBytes(of: &effect) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for index in [0, 6, 12] { values[index] = Float(percent) / 100 }
            values[18] = 1; values[24] = 1
        }
        return effect
    }

    /// Pure policy/matrix checks; no HWND creation, Magnification API or cursor changes.
    static func selfCheck() throws(WindowsError) {
        func fixture(_ id: String = "physical", physical: Bool = true, cloned: Bool = false, hdr: Bool = false) -> DisplayOutput {
            DisplayOutput(id: id, name: "Test", device: "DISPLAY", adapterLow: 1, adapterHigh: 0,
                source: 0, target: 1, isPhysical: physical, isCloned: cloned, isHDR: hdr)
        }
        let output = fixture()
        guard supports(output, activePathCount: 1, displays: [output]),
            !supports(output, activePathCount: 2, displays: [output]),
            !supports(output, activePathCount: 1, displays: [output, fixture("virtual", physical: false)]),
            !supports(output, activePathCount: 1, displays: []),
            !supports(output, activePathCount: 1, displays: [fixture(physical: false)]),
            !supports(output, activePathCount: 1, displays: [fixture(cloned: true)]),
            !supports(output, activePathCount: 1, displays: [fixture(hdr: true)]),
            !supports(output, activePathCount: 1, displays: [fixture("changed")])
        else { throw .unsupported("Software cursor output-policy check failed.") }
        for percent in [0, 1, 60, 99, 100] {
            let effect = colorEffect(percent)
            let correct = withUnsafeBytes(of: effect) { bytes in
                let values = bytes.bindMemory(to: Float.self)
                return (0..<25).allSatisfy {
                    values[$0] == ([0, 6, 12].contains($0) ? Float(percent) / 100 : ($0 == 18 || $0 == 24 ? 1 : 0))
                }
            }
            guard correct else { throw .unsupported("Software cursor color-matrix check failed.") }
        }
        Console.writeLine("PASS: software cursor single-output SDR policy and absolute color scaling; no cursor/display changes")
    }

    deinit {
        // Normal shutdown calls restore on the executor; this is a final native cleanup only.
        _ = deactivate()
        closeWindows()
        if initialized { MagUninitialize() }
    }
}

/// Recovery does not require a connected display. This restores Magnification's global
/// cursor visibility flag only; it does not alter another application's ShowCursor count.
func restoreSoftwareCursorVisibility() throws(WindowsError) {
    guard MagInitialize() else { throw .api("Initialize cursor visibility recovery", GetLastError()) }
    defer { MagUninitialize() }
    guard MagShowSystemCursor(true) else { throw .api("Recover system cursor visibility", GetLastError()) }
}
