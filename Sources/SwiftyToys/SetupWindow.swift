// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK
import WindowsDisplayABI

private let setupChanged: UINT = 0x8051
private struct SetupState: Sendable {
    var status = "Ready to install."
    var running = false
    var installed: String?
    var failure: String?
    var notice: String?
}
private final class SetupMailbox: Sendable { let state = Mutex(SetupState()) }
private func setupProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window else { return DefWindowProcW(window, message, value, data) }
    if message == UINT(WM_NCCREATE), let creation = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(data)), let context = creation.pointee.lpCreateParams {
        SetWindowLongPtrW(window, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: context)))
    }
    if let pointer = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(window, Int32(GWLP_USERDATA)))) {
        return Unmanaged<SetupWindow>.fromOpaque(pointer).takeUnretainedValue().handle(window, message, value, data)
    }
    return DefWindowProcW(window, message, value, data)
}

/// The installer paints only its own window; file, COM and driver recovery waits run on a worker.
final class SetupWindow {
    private var window: HWND?
    private var statusLabel: HWND?
    private var installButton: HWND?
    private var cancelButton: HWND?
    private var worker: NativeThread?
    private let mailbox = SetupMailbox()
    private var fonts: [HFONT] = []
    private var brush: HBRUSH?
    private var icon: ApplicationIcon?
    private var captionIcon: ApplicationIcon?
    private let source: String
    private let trackpadAction: String?
    private var highContrast = false
    private var automatic = false
    private var presentingDialog = false
    private var scale: Double { window.map { Double(GetDpiForWindow($0)) / 96 } ?? 1 }

    init(source: String, trackpadAction: String? = nil) throws {
        self.source = source
        self.trackpadAction = trackpadAction
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        let identity = withWideString("SwiftyToys.Setup") { SetCurrentProcessExplicitAppUserModelID($0) }
        guard identity >= 0 else { throw WindowsError.status("Set installer identity", identity) }
        updateTheme()
        var type = WNDCLASSEXW(); type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = setupProcedure; type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        let registered = withWideString("SwiftyToys.Setup") { type.lpszClassName = $0; return RegisterClassExW(&type) }
        guard registered != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS) else { throw WindowsError.api("Register installer window", GetLastError()) }
        window = withWideString("SwiftyToys.Setup") { name in
            withWideString(trackpadAction == nil ? "SwiftyToys Setup" : "SwiftyToys Magic Trackpad") {
                CreateWindowExW(DWORD(WS_EX_CONTROLPARENT), name, $0,
                    DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN),
                    Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 590, 470, nil, nil, GetModuleHandleW(nil), Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard let window else { throw WindowsError.api("Create installer window", GetLastError()) }
        try updateIcons()
        try child("STATIC", trackpadAction == nil ? "SwiftyToys" : "Magic Trackpad", 20)
        try child("STATIC", "Mac habits. Windows capabilities.", 21)
        try child("STATIC", trackpadAction == nil ? "Install for your Windows account.\nYour settings are kept when reinstalling." : "Verified driver packages and native Windows APIs.\nKeep your trackpad connected while this runs.", 22)
        try child("STATIC", trackpadAction == nil ? "Starts automatically when you sign in." : "Recovery backups are retained. No automatic restart.", 23)
        statusLabel = try child("STATIC", "Ready to install.", 24)
        installButton = try child("BUTTON", "Install", 1, style: DWORD(WS_TABSTOP | BS_DEFPUSHBUTTON))
        cancelButton = try child("BUTTON", "Cancel", 2, style: DWORD(WS_TABSTOP | BS_PUSHBUTTON))
        updateLayout()
        var info = MONITORINFO(); info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        if GetMonitorInfoW(MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)), &info) {
            let width = Int32(590 * scale), height = Int32(470 * scale)
            SetWindowPos(window, nil, info.rcWork.left + (info.rcWork.right - info.rcWork.left - width) / 2, info.rcWork.top + (info.rcWork.bottom - info.rcWork.top - height) / 2, width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
    }
    @discardableResult private func child(_ kind: String, _ title: String, _ id: Int, style: DWORD = 0) throws -> HWND {
        let control = withWideString(kind) { kind in withWideString(title) {
            CreateWindowExW(0, kind, $0, DWORD(WS_CHILD | WS_VISIBLE) | style, 0, 0, 0, 0, window, HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
        } }
        guard let control else { throw WindowsError.api("Create installer control", GetLastError()) }
        return control
    }
    private func updateTheme() {
        var contrast = HIGHCONTRASTW(); contrast.cbSize = DWORD(MemoryLayout<HIGHCONTRASTW>.size)
        highContrast = SystemParametersInfoW(UINT(SPI_GETHIGHCONTRAST), contrast.cbSize, &contrast, 0) && contrast.dwFlags & DWORD(HCF_HIGHCONTRASTON) != 0
        if let replacement = CreateSolidBrush(highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00F9_F7F7) {
            let previous = brush; brush = replacement; DeleteObject(previous)
        }
    }
    private func updateIcons() throws {
        guard let window else { return }
        let large = try ApplicationIcon(size: Int32(64 * scale))
        let small = try ApplicationIcon(size: GetSystemMetricsForDpi(Int32(SM_CXSMICON), GetDpiForWindow(window)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: large.handle)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: small.handle)))
        icon = large; captionIcon = small
    }
    private func updateLayout() {
        guard let window else { return }
        let previous = fonts; fonts = []
        for (size, weight) in [(16, 400), (30, 600)] {
            if let font = withWideString("Segoe UI", { CreateFontW(-Int32(Double(size) * scale), 0, 0, 0, Int32(weight), 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0) }) { fonts.append(font) }
        }
        for (id, x, y, width, height) in [(20,104,28,410,46),(21,106,82,410,30),(22,32,150,516,72),(23,32,236,516,32),(24,32,284,516,68),(1,32,366,226,44),(2,360,366,188,44)] {
            if let control = GetDlgItem(window, Int32(id)) {
                let role = id == 20 ? 1 : 0
                SendMessageW(control, UINT(WM_SETFONT), WPARAM(fonts.indices.contains(role) ? UInt(bitPattern: fonts[role]) : UInt(bitPattern: GetStockObject(Int32(DEFAULT_GUI_FONT)))), 1)
                SetWindowPos(control, nil, Int32(Double(x) * scale), Int32(Double(y) * scale), Int32(Double(width) * scale), Int32(Double(height) * scale), UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
        }
        previous.forEach { DeleteObject($0) }
    }
    func run(automatic: Bool = false) throws {
        guard let window else { return }
        self.automatic = automatic
        ShowWindow(window, Int32(SW_SHOWNORMAL)); SetForegroundWindow(window)
        if automatic { begin() }
        var message = MSG()
        while true {
            let result = BC_GetMessageW(&message, nil, 0, 0)
            guard result >= 0 else { throw WindowsError.api("Read installer messages", GetLastError()) }
            if result == 0 { break }
            if !IsDialogMessageW(window, &message) { TranslateMessage(&message); DispatchMessageW(&message) }
        }
        if automatic, mailbox.state.withLock({ $0.installed }) == nil { throw WindowsError.unsupported("Installation did not complete. Previous settings and recovery files have been retained.") }
    }
    private func begin() {
        guard let window, worker?.isFinished != false else { return }
        let ready = mailbox.state.withLock { state in
            guard !state.running, state.installed == nil else { return false }
            state.running = true; state.status = "Preparing installation…"; return true
        }
        guard ready else { return }
        EnableWindow(installButton, false); EnableWindow(cancelButton, false)
        // A work-only fallback also delivers completion if the message queue rejected a post.
        SetTimer(window, 52, 200, nil)
        let mailbox = self.mailbox, destination = MessageDestination(window), source = self.source, action = trackpadAction
        do {
            worker = try NativeThread(name: "SwiftyToys installer") {
                do {
                    if let action {
                        mailbox.state.withLock { $0.status = "Checking packages, signatures and recovery…" }; _ = destination.post(setupChanged)
                        let result = try NativeTrackpadInstaller.runCLI(action: action)
                        mailbox.state.withLock { $0.installed = executablePath(); $0.running = false; $0.status = result; $0.notice = result }
                    } else {
                        let installed = try NativeInstaller.install(from: source) { status in
                            mailbox.state.withLock { $0.status = status }; _ = destination.post(setupChanged)
                        }
                        mailbox.state.withLock { $0.installed = installed; $0.running = false; if $0.status.contains("\n") { $0.notice = $0.status } }
                    }
                } catch {
                    mailbox.state.withLock { $0.running = false; $0.status = "Installation could not finish. Review the error and retry."; $0.failure = String(describing: error) }
                }
                _ = destination.post(setupChanged)
            }
        } catch {
            mailbox.state.withLock { $0.running = false; $0.status = "Could not start installation. Please retry."; $0.failure = String(describing: error) }
        }
        refresh()
    }
    private func refresh() {
        guard !presentingDialog else { return }
        let state = mailbox.state.withLock { state in let result = state; state.failure = nil; state.notice = nil; return result }
        if !state.running, worker?.isFinished != false, let window { KillTimer(window, 52) }
        if let statusLabel { _ = withWideString(state.status) { SetWindowTextW(statusLabel, $0) } }
        EnableWindow(installButton, !state.running); EnableWindow(cancelButton, !state.running)
        if let installButton { _ = withWideString(state.installed == nil ? "Install" : "Open SwiftyToys") { SetWindowTextW(installButton, $0) } }
        if let cancelButton { _ = withWideString(state.installed == nil ? "Cancel" : "Close") { SetWindowTextW(cancelButton, $0) } }
        if let message = state.failure ?? state.notice {
            // MessageBox pumps messages: completion must not destroy its owner reentrantly.
            presentingDialog = true
            _ = withWideString(message) { message in withWideString("SwiftyToys Setup") { MessageBoxW(window, message, $0, UINT(MB_OK) | (state.failure == nil ? UINT(MB_ICONINFORMATION) : UINT(MB_ICONERROR))) } }
            presentingDialog = false
        }
        if automatic, state.installed != nil || state.failure != nil, let window { _ = handle(window, UINT(WM_CLOSE), 0, 0) }
    }
    fileprivate func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        switch message {
        case UINT(WM_DPICHANGED):
            if let area = UnsafePointer<RECT>(bitPattern: Int(data))?.pointee {
                SetWindowPos(window, nil, area.left, area.top, area.right - area.left, area.bottom - area.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            do { try updateIcons() } catch { Diagnostics.write("Installer icon resize failed") }
            updateLayout(); InvalidateRect(window, nil, true); return 0
        case UINT(WM_SETTINGCHANGE), UINT(WM_SYSCOLORCHANGE), UINT(WM_THEMECHANGED):
            updateTheme(); RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN)); return 0
        case setupChanged: refresh(); return 0
        case UINT(WM_COMMAND):
            guard !presentingDialog else { return 0 }
            if value & 0xffff == 2 { _ = handle(window, UINT(WM_CLOSE), 0, 0); return 0 }
            if value & 0xffff == 1 {
                if let installed = mailbox.state.withLock({ $0.installed }) {
                    _ = withWideString(installed) { path in withWideString("settings") { ShellExecuteW(window, nil, path, $0, nil, Int32(SW_SHOWNORMAL)) } }
                    _ = handle(window, UINT(WM_CLOSE), 0, 0)
                } else { begin() }
                return 0
            }
        case UINT(WM_CLOSE):
            guard !presentingDialog, !mailbox.state.withLock({ $0.running }) else { return 0 }
            if worker?.isFinished == false { SetTimer(window, 51, 25, nil); return 0 }
            KillTimer(window, 51)
            DestroyWindow(window); self.window = nil; PostQuitMessage(0); return 0
        case UINT(WM_TIMER):
            if value == 51 { _ = handle(window, UINT(WM_CLOSE), 0, 0) }
            if value == 52 { refresh() }; return 0
        case UINT(WM_CTLCOLORSTATIC):
            let dc = HDC(bitPattern: UInt(value)); SetBkMode(dc, Int32(TRANSPARENT))
            SetTextColor(dc, highContrast ? GetSysColor(Int32(COLOR_WINDOWTEXT)) : 0x002D_2525)
            return LRESULT(Int(bitPattern: brush))
        case UINT(WM_ERASEBKGND):
            var area = RECT(); GetClientRect(window, &area)
            if let dc = HDC(bitPattern: UInt(value)) { FillRect(dc, &area, brush) }; return 1
        case UINT(WM_PAINT):
            var paint = PAINTSTRUCT()
            if let dc = BeginPaint(window, &paint) {
                var area = RECT(); GetClientRect(window, &area); FillRect(dc, &area, brush)
                if let icon { DrawIconEx(dc, Int32(32 * scale), Int32(28 * scale), icon.handle, Int32(56 * scale), Int32(56 * scale), 0, nil, UINT(DI_NORMAL)) }
                EndPaint(window, &paint)
            }
            return 0
        default: break
        }
        return DefWindowProcW(window, message, value, data)
    }
    /// Constructs only this process's controls; never starts an installation.
    static func selfCheck() throws {
        let setup = try SetupWindow(source: "C:\\fixture")
        guard let window = setup.window, setup.worker == nil,
            SendMessageW(window, UINT(WM_GETICON), WPARAM(ICON_BIG), 0) != 0,
            SendMessageW(window, UINT(WM_GETICON), WPARAM(ICON_SMALL), 0) != 0 else { throw WindowsError.unsupported("Installer icon check failed.") }
        var client = RECT(); GetClientRect(window, &client)
        for id in [20,21,22,23,24,1,2] {
            guard let control = GetDlgItem(window, Int32(id)), GetWindowTextLengthW(control) > 0 else { throw WindowsError.unsupported("Installer control check failed.") }
            var area = RECT(); GetWindowRect(control, &area)
            _ = withUnsafeMutablePointer(to: &area) { $0.withMemoryRebound(to: POINT.self, capacity: 2) { MapWindowPoints(nil, window, $0, 2) } }
            guard area.left >= 0, area.top >= 0, area.right <= client.right, area.bottom <= client.bottom else { throw WindowsError.unsupported("Installer control layout check failed.") }
        }
        for id in [1,2] {
            guard let control = GetDlgItem(window, Int32(id)), GetWindowLongPtrW(control, Int32(GWL_STYLE)) & LONG_PTR(WS_TABSTOP) != 0 else { throw WindowsError.unsupported("Installer keyboard navigation check failed.") }
        }
        setup.updateLayout(); setup.updateTheme(); setup.refresh()
        guard !setup.mailbox.state.withLock({ $0.running }), setup.mailbox.state.withLock({ $0.installed }) == nil else { throw WindowsError.unsupported("Installer fixture unexpectedly started work.") }
        setup.automatic = true; setup.presentingDialog = true
        setup.mailbox.state.withLock { $0.installed = "C:\\fixture\\SwiftyToys.exe"; $0.notice = "Recovery instructions fixture" }
        setup.refresh(); _ = setup.handle(window, UINT(WM_CLOSE), 0, 0)
        guard IsWindow(window), setup.mailbox.state.withLock({ $0.notice }) != nil else { throw WindowsError.unsupported("Installer modal ownership guard failed.") }
        setup.automatic = false; setup.presentingDialog = false
        setup.mailbox.state.withLock { $0.installed = nil; $0.notice = nil }
        Console.writeLine("PASS: native installer controls, icons, layout, keyboard navigation and modal ownership; no installation started")
    }
    deinit { if let window { DestroyWindow(window) }; fonts.forEach { DeleteObject($0) }; DeleteObject(brush) }
}
