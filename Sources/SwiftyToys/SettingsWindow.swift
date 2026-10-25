// SPDX-License-Identifier: MIT
import BrightnessCore
import KeyboardCore
import SearchCore
import WinSDK
import WindowsDisplayABI

private func settingsProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window else { return DefWindowProcW(window, message, value, data) }
    if message == UINT(WM_NCCREATE), let creation = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(data)),
        let context = creation.pointee.lpCreateParams
    {
        SetWindowLongPtrW(window, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: context)))
    }
    if let context = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(window, Int32(GWLP_USERDATA)))) {
        return Unmanaged<SettingsWindow>.fromOpaque(context).takeUnretainedValue().handle(window, message, value, data)
    }
    return DefWindowProcW(window, message, value, data)
}

private func viewportProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window, let parent = GetParent(window) else { return DefWindowProcW(window, message, value, data) }
    switch message {
    case UINT(WM_COMMAND), UINT(WM_DRAWITEM), UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN), UINT(WM_HSCROLL), UINT(WM_VSCROLL), UINT(WM_MOUSEWHEEL):
        return SendMessageW(parent, message, value, data)
    case UINT(WM_ERASEBKGND), UINT(WM_PRINTCLIENT):
        if let context = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(parent, Int32(GWLP_USERDATA)))), let dc = HDC(bitPattern: UInt(value)) {
            Unmanaged<SettingsWindow>.fromOpaque(context).takeUnretainedValue().paintViewport(dc, window)
        }
        return 1
    case UINT(WM_PAINT):
        var paint = PAINTSTRUCT()
        if let dc = BeginPaint(window, &paint) {
            _ = viewportProcedure(window, UINT(WM_PRINTCLIENT), WPARAM(UInt(bitPattern: dc)), 0)
            EndPaint(window, &paint)
        }
        return 0
    default: return DefWindowProcW(window, message, value, data)
    }
}

private func settingsButtonProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM, _ id: UINT_PTR, _ context: DWORD_PTR) -> LRESULT {
    if let window, let pointer = UnsafeRawPointer(bitPattern: UInt(context)) {
        let owner = Unmanaged<SettingsWindow>.fromOpaque(pointer).takeUnretainedValue()
        if message == UINT(WM_MOUSEMOVE) {
            if owner.hover(window, entered: true) {
                var tracking = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: window, dwHoverTime: 0)
                TrackMouseEvent(&tracking)
            }
        } else if message == UINT(WM_MOUSELEAVE) { owner.hover(window, entered: false) }
        else if message == UINT(WM_NCDESTROY) { RemoveWindowSubclass(window, settingsButtonProcedure, id) }
    }
    return DefSubclassProc(window, message, value, data)
}

/// Native accessible child controls, with a small painted shell. All state belongs to the UI thread.
final class SettingsWindow {
    private(set) var window: HWND?
    private var viewport: HWND?
    private var controls: [Int: HWND] = [:]
    private var content: [HWND] = []
    private var fonts: [HFONT] = []
    private var smallIcon: ApplicationIcon?
    private var largeIcon: ApplicationIcon?
    private var brandIcon: ApplicationIcon?
    private var layout: [(HWND, Int, Int, Int, Int)] = []
    private var fontRoles: [Int: Int] = [:]
    private var hovered: HWND?
    private var rendering = false
    private var draftText: [Int: [Int: String]] = [:]
    private var draftChecks: [Int: [Int: Bool]] = [:]
    private var draftSelections: [Int: [Int: Int]] = [:]
    private var pageOffsets: [Int: Int32] = [:]
    private var page = 0
    private var scrollOffset: Int32 = 0
    private var wheelRemainder: Int32 = 0
    private var keyboard: KeyboardConfiguration
    private var presentingActionError = false
    private var distributions: [LinuxDistribution] = []
    private var ubuntuInstalled = false
    private var wslVirtualizationBlocked = false
    private let wslBootDiagnostic = WSLBootDiagnostic()
    private let deviceReports = SettingsDeviceReports()
    private let displayReports = SettingsDisplayReports()
    private let colorProfiles = SettingsColorProfiles()
    private var colorProfileNames: [String] = []
    private var colorProfilesRefreshPending = false
    private var importedColorProfile: (displayID: String, name: String)?
    private var colorNotifications: ColorProfileNotifications?
    private var displays: [DisplayOutput] = []
    private var languages: [UInt16] = []
    private let localization = Localization()
    private var languagePacks: [LanguagePack] = []
    private var comboValues: [Int: [String]] = [:]
    private var level: Int
    private var pendingBrightness: Int?
    private var selectedRule: Int?
    private var draftRuleSelection: Int?
    private var brightnessConfiguration: Settings?
    private var monitorAutomaticBrightness: Bool?
    private var measuredBrightness = false
    private var modeBusy = false
    private var lastFocusedControl: Int?
    private let preview: Bool
    private let command: (Int, [String]) throws -> String
    private var searchPreferences = SearchPreferences()
    private var searchModelStatus = SearchModelStatus(text:"Optional model is not downloaded. Basic search works without it.",busy:false,downloaded:false)
    private var searchLibraryText = "The local library is waiting to start."
    private var highContrast = false
    private var background: HBRUSH?
    private var white: HBRUSH?
    private var textColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOWTEXT)) : 0x002D_2525 }
    private var secondaryColor: COLORREF { highContrast ? textColor : 0x006E_6162 }
    private var accentColor: COLORREF { highContrast ? textColor : 0x0024_37B6 }
    private var borderColor: COLORREF { highContrast ? textColor : 0x00E8_E3E2 }
    private var backgroundColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00F9_F7F7 }
    private let titles = [
        "Overview", "Brightness", "Keyboard", "Input languages", "Desktop", "Mouse", "Magic Trackpad", "Homebrew", "Boot Camp", "Search", "About SwiftyToys",
    ]
    private let tileDetails = [
        "Brightness, F1 / F2 keys, and indicator", "Command, Option, and your shortcuts",
        "Ctrl + Space and smart Caps Lock", "Always-on-top windows and no-sleep mode",
        "Natural wheel direction", "Precision Touchpad over USB and Bluetooth",
        "Package manager inside WSL 2", "Installed drivers and native Windows updates", "Apps, files, calculations and local semantic search", "Author, source code, and inspiration",
    ]
    private let tileGlyphs = ["\u{E706}", "\u{E765}", "\u{E775}", "\u{E7F4}", "\u{E962}", "\u{E7C9}", "\u{E756}", "\u{E713}", "\u{E721}", "\u{E946}"]
    init(
        brightness: Int, keyboard: KeyboardConfiguration, preview: Bool = false,
        command: @escaping (Int, [String]) throws -> String
    ) throws {
        self.level = brightness
        self.keyboard = keyboard
        self.preview = preview
        if !preview, let actual = try? NativeMouseScrolling.current() {
            self.keyboard.reverseVertical = actual.vertical ?? keyboard.reverseVertical
            self.keyboard.reverseHorizontal = actual.horizontal ?? keyboard.reverseHorizontal
        }
        self.command = command
        var common = INITCOMMONCONTROLSEX()
        common.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        common.dwICC = DWORD(ICC_BAR_CLASSES)
        InitCommonControlsEx(&common)
        var type = WNDCLASSEXW()
        type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = settingsProcedure
        type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        _ = withWideString("SwiftyToys.Settings") {
            type.lpszClassName = $0
            return RegisterClassExW(&type)
        }
        window = withWideString("SwiftyToys.Settings") { name in
            withWideString("SwiftyToys") {
                CreateWindowExW(
                    DWORD(WS_EX_CONTROLPARENT), name, $0,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN), Int32(CW_USEDEFAULT),
                    Int32(CW_USEDEFAULT), 1080, 790, nil, nil, GetModuleHandleW(nil),
                    Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard window != nil else { throw WindowsError.api("Create settings window", GetLastError()) }
        try updateIcons()
        if let window {
            var monitor = MONITORINFO()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            if GetMonitorInfoW(MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) {
                let area = monitor.rcWork
                let width = min(area.right - area.left, Int32(1080 * scale))
                let height = min(area.bottom - area.top, Int32(790 * scale))
                SetWindowPos(
                    window, nil, area.left + (area.right - area.left - width) / 2,
                    area.top + (area.bottom - area.top - height) / 2, width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE)
                )
            }
        }
        type.lpfnWndProc = viewportProcedure
        _ = withWideString("SwiftyToys.SettingsViewport") { type.lpszClassName = $0; return RegisterClassExW(&type) }
        viewport = withWideString("SwiftyToys.SettingsViewport") {
            CreateWindowExW(DWORD(WS_EX_CONTROLPARENT), $0, nil, DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_VSCROLL), 0, 0, 1, 1, window, nil, GetModuleHandleW(nil), nil)
        }
        guard viewport != nil else { throw WindowsError.api("Create settings viewport", GetLastError()) }
        makeTheme()
        makeFonts()
        button("←  Overview", 100, 80, 20, 172, 40, fixed: true)
        control("STATIC", "ON WINDOWS", 13, 870, 26, 142, 28, style: DWORD(SS_OWNERDRAW), fixed: true)
        label("SwiftyToys", 20, 32, 68, 920, 44, large: true, fixed: true)
        label("", 21, 34, 114, 920, 36, fixed: true)
        label("Swift. Native. Open source.", 12, 32, 708, 920, 30, fixed: true)
        label("", 99, 32, 674, 920, 40, fixed: true)
        renderPage()
    }
    func show() {
        guard let window else { return }
        ShowWindow(window, Int32(SW_SHOW))
        ShowWindow(window, Int32(SW_RESTORE))
        SetForegroundWindow(window)
    }
    func showPreview(page selected: Int) throws {
        guard preview, titles.indices.contains(selected) else { throw WindowsError.unsupported("Preview page must be 0–9.") }
        page = selected; renderPage(); show()
    }
    func dialogMessage(_ message: inout MSG) -> Bool {
        guard let window, IsWindowVisible(window) else { return false }
        if page != 0, message.message == UINT(WM_KEYDOWN), message.wParam == WPARAM(VK_ESCAPE) {
            var focused = GetFocus()
            var comboOpen = false
            for _ in 0..<2 {
                if let current = focused {
                    var name = [WCHAR](repeating: 0, count: 32)
                    GetClassNameW(current, &name, 32)
                    if String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self).lowercased() == "combobox" { comboOpen = SendMessageW(current, UINT(CB_GETDROPPEDSTATE), 0, 0) != 0; break }
                    focused = GetParent(current)
                }
            }
            if !comboOpen { navigate(to: 0); return true }
        }
        let handled=IsDialogMessageW(window, &message)
        if handled, let focus=GetFocus(), content.contains(focus) {
            let previousOffset = scrollOffset
            var area=RECT(); var client=RECT(); GetWindowRect(focus,&area); GetClientRect(viewport,&client)
            _ = withUnsafeMutablePointer(to:&area) { $0.withMemoryRebound(to:POINT.self,capacity:2) { MapWindowPoints(nil,viewport,$0,2) } }
            if area.top < 0 { scrollOffset=max(0,scrollOffset+area.top) }
            else if area.bottom > client.bottom { scrollOffset += area.bottom-client.bottom+8 }
            if previousOffset != scrollOffset { arrange(); InvalidateRect(window,nil,false) }
        }
        return handled
    }
    func update(brightness: Int) {
        guard pendingBrightness == nil, brightness != level else { return }
        if let slider = controls[211], GetCapture() == slider { return }
        level = brightness
        if let label = controls[210] { setText(label, "\(brightness)%") }
        if let slider = controls[211] { SendMessageW(slider, UINT(TBM_SETPOS), 1, LPARAM(brightness)) }
        if page == 0, let tile = controls[121] { setText(tile, tileText(1)); InvalidateRect(tile, nil, false) }
    }
    var observesBrightness: Bool {
        guard !preview, page == 0 || page == 1, let window else { return false }
        return IsWindowVisible(window) && !IsIconic(window)
    }
    func updateScrolling(vertical: Bool, horizontal: Bool, result: String) {
        keyboard.reverseVertical = vertical; keyboard.reverseHorizontal = horizontal
        if page == 5 {
            for (id, enabled) in [(422, vertical), (423, horizontal)] {
                if let control = controls[id] { SendMessageW(control, UINT(BM_SETCHECK), enabled ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0) }
            }
        }
        status(result)
    }
    func refreshLanguages(result: String) { captureDraft(); renderPage(); restoreDraft(); status(result) }
    func refreshBrightnessControl() {
        brightnessConfiguration = try? Settings()
        updateBrightnessMode()
        if let tile = controls[121] { setText(tile, tileText(1)); InvalidateRect(tile, nil, false) }
    }
    func updateAutomaticBrightness(_ enabled: Bool?, measured: Bool = false) {
        let mismatch = controls[252] != nil && checked(252) != (enabled == true)
        guard monitorAutomaticBrightness != enabled || measuredBrightness != measured || mismatch else { return }
        monitorAutomaticBrightness = enabled
        measuredBrightness = measured
        if let label = controls[209] {
            setText(label, localization.text(enabled == true
                ? (measured ? "Display brightness (automatic)" : "Brightness preference (automatic)") : "Display brightness"))
        }
        if let control = controls[252] {
            SendMessageW(control, UINT(BM_SETCHECK), enabled == true ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0)
        }
        brightnessControlBusy(modeBusy)
    }
    func displayCompleted(_ message: String) { if page == 1 { status(message) } }
    func brightnessControlBusy(_ busy: Bool) {
        modeBusy = busy
        if let control = controls[244] { EnableWindow(control, !busy) }
        if let control = controls[252] { EnableWindow(control, !busy && checked(244) && monitorAutomaticBrightness != nil) }
        for id in [245, 246] { if let control = controls[id] { EnableWindow(control, !busy && !checked(244)) } }
        for id in [262, 263, 264, 265] {
            if let control = controls[id] { EnableWindow(control, !busy && !colorProfiles.busy && colorOutput != nil) }
        }
    }
    private var colorOutput: DisplayOutput? {
        if let selected = brightnessConfiguration?.targetID { return displays.first { $0.id == selected } }
        return displays.count == 1 ? displays.first : nil
    }
    func refreshColorProfiles() {
        guard page == 1, !preview, let window, IsWindowVisible(window), let output = colorOutput else { return }
        if colorNotifications == nil, IsWindowVisible(window) {
            do { colorNotifications = try ColorProfileNotifications(destination: MessageDestination(window)) }
            catch { Diagnostics.write("color notifications: \(error)") }
        }
        if colorProfiles.busy { colorProfilesRefreshPending = true; return }
        colorProfilesRefreshPending = false
        colorProfiles.load(output: output, destination: MessageDestination(window))
        brightnessControlBusy(modeBusy)
    }
    private func updateColorProfiles() {
        guard page == 1, let combo = controls[262] else { return }
        guard let output = colorOutput else {
            if let label = controls[261] { setText(label, localization.text("Select one connected physical SDR display.")) }
            colorProfileNames = []
            SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
            brightnessControlBusy(modeBusy)
            return
        }
        guard let report = colorProfiles.report, report.displayID == output.id else { refreshColorProfiles(); return }
        colorProfileNames = []
        SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
        if let snapshot = report.snapshot {
            if let name = report.imported { importedColorProfile = (output.id, name) }
            if importedColorProfile?.displayID != output.id { importedColorProfile = nil }
            colorProfileNames = [""] + snapshot.installed.map(\.fileName)
            let choices = [localization.text("Use Windows system default")] + snapshot.installed.map(\.description)
            for choice in choices { _ = withWideString(choice) { SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
            let selected = importedColorProfile?.name ?? (snapshot.perUser ? snapshot.defaultProfile ?? snapshot.effective : "")
            let index = colorProfileNames.firstIndex { equalWindowsNames($0, selected) } ?? 0
            SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
            if let label = controls[261] {
                let description = snapshot.installed.first { equalWindowsNames($0.fileName, snapshot.effective) }?.description ?? snapshot.effective
                setText(label, localization.text("Windows profile: {0}", [description]) + "\n" + localization.text(snapshot.perUser ? "Scope: current user" : "Scope: Windows system default"))
            }
            if report.imported != nil { status("ICC profile installed. Choose Apply to use it for this display.") }
        } else if let label = controls[261] { setText(label, report.error ?? localization.text("Color profile information is unavailable.")) }
        brightnessControlBusy(modeBusy)
        if colorProfileNames.isEmpty, let apply = controls[263] { EnableWindow(apply, false) }
    }
    private func updateBrightnessMode() {
        let enabled = brightnessConfiguration?.ddcEnabled ?? false
        if let control = controls[244] { SendMessageW(control, UINT(BM_SETCHECK), enabled ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0) }
        for id in [245, 246] { if let control = controls[id] { EnableWindow(control, !enabled) } }
        let hintText = enabled ? "DDC/CI controls the monitor backlight, including the cursor. Turn off to use software dimming."
            : "Software dimming changes the image only. Monitor backlight stays unchanged; hardware cursors may remain brighter."
        if let hint = controls[248] { setText(hint, localization.text(hintText)) }
        brightnessControlBusy(modeBusy)
    }
    /// Tests this application's own native controls without sending desktop input.
    func validateLayout() throws {
        guard let window, let viewport else { throw WindowsError.unsupported("Missing settings window.") }
        guard let smallIcon, let largeIcon,
            SendMessageW(window, UINT(WM_GETICON), WPARAM(ICON_SMALL), 0) == LRESULT(Int(bitPattern: smallIcon.handle)),
            SendMessageW(window, UINT(WM_GETICON), WPARAM(ICON_BIG), 0) == LRESULT(Int(bitPattern: largeIcon.handle))
        else { throw WindowsError.unsupported("Application icons are missing from the native window.") }
        var client = RECT()
        GetClientRect(viewport, &client)
        let initialLanguage = localization.pack
        defer { try? localization.select(initialLanguage, persist: false) }
        for language in localization.available() {
        try localization.select(language, persist: false)
        for index in titles.indices {
            page = index
            renderPage()
            var extent = SCROLLINFO(); extent.cbSize = UINT(MemoryLayout<SCROLLINFO>.size); extent.fMask = UINT(SIF_RANGE)
            GetScrollInfo(viewport, Int32(SB_VERT), &extent)
            GetClientRect(viewport, &client)
            guard let back = controls[100], IsWindow(back), controls[101] == nil, !text(20).isEmpty else { throw WindowsError.unsupported("Missing tile navigation or sidebar unexpectedly present.") }
            if page == 0 { guard GetNextDlgTabItem(window, nil, false) == controls[121] else { throw WindowsError.unsupported("Tab cannot enter feature tiles.") } }
            if page == 1 { guard GetNextDlgTabItem(window, back, false) == controls[211] else { throw WindowsError.unsupported("Tab cannot enter detail controls.") } }
            for handle in content {
                var area = RECT()
                guard GetWindowRect(handle, &area) else {
                    throw WindowsError.api("Read own control bounds", GetLastError())
                }
                _ = withUnsafeMutablePointer(to: &area) {
                    $0.withMemoryRebound(to: POINT.self, capacity: 2) { MapWindowPoints(nil, viewport, $0, 2) }
                }
                guard area.right - area.left >= Int32(30 * scale), area.bottom - area.top >= Int32(18 * scale), area.left >= 0, area.top >= 0, area.right <= client.right,
                    area.bottom <= max(client.bottom, extent.nMax)
                else {
                    throw WindowsError.unsupported(
                        "Settings control clipped on page \(page): \(area.left),\(area.top),\(area.right),\(area.bottom); client \(client.right)×\(client.bottom), scale \(scale)."
                    )
                }
            }
            // Own-control regression: every native checkbox must toggle on a click and back.
            for id in [219, 244, 315, 346, 405, 422, 423] {
                guard let handle = controls[id] else { continue }
                let before = checked(id)
                SendMessageW(handle, UINT(BM_CLICK), 0, 0)
                guard checked(id) != before else { throw WindowsError.unsupported("Checkbox \(id) did not toggle.") }
                SendMessageW(handle, UINT(BM_CLICK), 0, 0)
                guard checked(id) == before else { throw WindowsError.unsupported("Checkbox \(id) did not restore.") }
            }
            if page == 1, let automatic = controls[252], let hardware = controls[244] {
                let previous = checked(244)
                SendMessageW(hardware, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
                updateAutomaticBrightness(false)
                guard IsWindowEnabled(automatic), !checked(252) else {
                    throw WindowsError.unsupported("Supported automatic brightness control is unavailable.")
                }
                SendMessageW(automatic, UINT(BM_CLICK), 0, 0)
                guard checked(252) else { throw WindowsError.unsupported("Automatic brightness checkbox did not toggle.") }
                updateAutomaticBrightness(false)
                guard !checked(252) else { throw WindowsError.unsupported("Automatic brightness checkbox did not roll back.") }
                updateAutomaticBrightness(nil)
                guard !IsWindowEnabled(automatic), !checked(252) else {
                    throw WindowsError.unsupported("Unsupported automatic brightness was enabled.")
                }
                SendMessageW(hardware, UINT(BM_SETCHECK), previous ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0)
                brightnessControlBusy(false)
            }
            if page == 7, let combo = controls[502], let install = controls[511] {
                // Selection events must disable WSL 1 and enable WSL 2 without starting Linux.
                wslVirtualizationBlocked = false
                distributions = [LinuxDistribution(name: "Legacy", version: 1), LinuxDistribution(name: "Ubuntu", version: 2)]
                SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
                for name in ["Legacy", "Ubuntu"] { _ = withWideString(name) { SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
                for (index, enabled) in [(0, false), (1, true), (0, false)] {
                    SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
                    SendMessageW(window, UINT(WM_COMMAND), WPARAM(502 | Int(CBN_SELCHANGE) << 16), LPARAM(Int(bitPattern: combo)))
                    guard IsWindowEnabled(install) == enabled else { throw WindowsError.unsupported("Homebrew selection readiness failed.") }
                }
                SendMessageW(combo, UINT(CB_SETCURSEL), 1, 0)
                wslVirtualizationBlocked = true
                updateHomebrewAvailability()
                guard !IsWindowEnabled(install) else { throw WindowsError.unsupported("Blocked virtualization enabled Homebrew.") }
                renderPage()
            }
            if page == 9, let combo = controls[823], let download = controls[812],
                let license = controls[821], let media = controls[839] {
                let selected = NativeSearchModelDescriptor.miniLM.repositoryID
                setText(combo, selected)
                updateSearchModel(.init(text: "Fixture ready", busy: false, downloaded: true,
                    repositoryID: selected, modelIDs: NativeSearchModelCatalog.builtIns.map(\.repositoryID)))
                guard text(823) == selected, SendMessageW(combo, UINT(CB_GETCOUNT), 0, 0) == 2,
                    !IsWindowEnabled(download), !IsWindowEnabled(media) else {
                    throw WindowsError.unsupported("Editable model catalog lost selection, media compatibility or license gating.")
                }
                setText(combo, NativeSearchModelDescriptor.recommended.repositoryID)
                updateSearchModel(.init(text: "Fixture ready", busy: false, downloaded: true,
                    repositoryID: NativeSearchModelDescriptor.recommended.repositoryID))
                SendMessageW(license, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
                SendMessageW(media, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
                updateSearchModel(searchModelStatus)
                guard IsWindowEnabled(download) else { throw WindowsError.unsupported("Missing media encoders could not be requested.") }
                SendMessageW(window, UINT(WM_COMMAND), WPARAM(823 | Int(CBN_EDITCHANGE) << 16), LPARAM(Int(bitPattern: combo)))
                guard !checked(821), !IsWindowEnabled(download) else { throw WindowsError.unsupported("Changing models retained license acceptance.") }
            }
        }
        }
        page = 1; renderPage(); update(brightness: 68)
        guard let slider = controls[211], SendMessageW(slider, UINT(TBM_GETPOS), 0, 0) == 68 else {
            throw WindowsError.unsupported("Brightness slider did not follow the resident value.")
        }
        page = 0
        renderPage()
        if let tile = controls[121] {
            SendMessageW(tile, UINT(BM_CLICK), 0, 0)
            guard page == 1 else { throw WindowsError.unsupported("Feature tile did not navigate.") }
        }
        try localization.select(initialLanguage, persist: false)
        page = 2; renderPage()
        if let source = controls[303] { setText(source, "Cmd+K") }
        navigate(to: 0); navigate(to: 2)
        guard text(303) == "Cmd+K", GetFocus() == controls[100] else { throw WindowsError.unsupported("Back navigation lost edits or focus.") }
        navigate(to: 0)
        guard GetFocus() == controls[122] else { throw WindowsError.unsupported("Overview did not restore tile focus.") }
        page = 0; renderPage()
    }
    private var scale: Double { window.map { Double(GetDpiForWindow($0)) / 96 } ?? 1 }
    private func updateIcons() throws {
        guard let window else { return }
        let dpi = GetDpiForWindow(window)
        let small = try ApplicationIcon(size: GetSystemMetricsForDpi(Int32(SM_CXSMICON), dpi))
        let large = try ApplicationIcon(size: GetSystemMetricsForDpi(Int32(SM_CXICON), dpi))
        let brand = try ApplicationIcon(size: Int32(64 * scale))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: small.handle)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: large.handle)))
        smallIcon = small; largeIcon = large; brandIcon = brand
    }
    private func makeTheme() {
        var contrast = HIGHCONTRASTW()
        contrast.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
        highContrast = SystemParametersInfoW(UINT(SPI_GETHIGHCONTRAST), contrast.cbSize, &contrast, 0) && contrast.dwFlags & DWORD(HCF_HIGHCONTRASTON) != 0
        if let background { DeleteObject(background) }
        if let white { DeleteObject(white) }
        background = CreateSolidBrush(backgroundColor)
        white = CreateSolidBrush(highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00FF_FFFF)
    }

    @discardableResult fileprivate func hover(_ control: HWND, entered: Bool) -> Bool {
        if entered, hovered != control { if let hovered { InvalidateRect(hovered, nil, false) }; hovered = control; InvalidateRect(control, nil, false); return true }
        if !entered, hovered == control { hovered = nil; InvalidateRect(control, nil, false); return true }
        return false
    }

    private func captureDraft() {
        draftText[page] = [218, 230, 231, 232, 233, 303, 305, 307, 317, 348, 351, 806, 823, 831, 846].reduce(into: [:]) { values, id in if controls[id] != nil { values[id] = text(id) } }
        draftChecks[page] = [219, 315, 346, 405, 422, 423, 801, 803, 822, 839].reduce(into: [:]) { values, id in if controls[id] != nil { values[id] = checked(id) } }
        draftSelections[page] = [216, 341, 343, 345, 355, 404, 459].reduce(into: [:]) { values, id in if let control = controls[id] { values[id] = Int(SendMessageW(control, UINT(CB_GETCURSEL), 0, 0)) } }
        pageOffsets[page] = scrollOffset
        if page == 2 { draftRuleSelection = selectedRule }
    }

    private func restoreDraft() {
        for (id, value) in draftText[page] ?? [:] { if let control = controls[id] { setText(control, value) } }
        for (id, value) in draftChecks[page] ?? [:] { if let control = controls[id] { SendMessageW(control, UINT(BM_SETCHECK), value ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0) } }
        for (id, value) in draftSelections[page] ?? [:] { if value >= 0, let control = controls[id] { SendMessageW(control, UINT(CB_SETCURSEL), WPARAM(value), 0) } }
        if page == 2, let selection = draftRuleSelection, keyboard.rules.indices.contains(selection), let list = controls[301] { selectedRule = selection; SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(selection), 0) }
        scrollOffset = pageOffsets[page] ?? 0
        arrange()
    }

    private func navigate(to destination: Int) {
        guard titles.indices.contains(destination) else { return }
        let previous = page
        captureDraft()
        page = destination
        renderPage()
        restoreDraft()
        if let focus = controls[page == 0 ? 120 + max(1, previous) : 100] { SetFocus(focus) }
    }
    private func makeFonts() {
        for font in fonts { DeleteObject(font) }
        fonts.removeAll()
        for (index, definition) in [(14, 400), (30, 600), (18, 600), (24, 400)].enumerated() {
            let (size, weight) = definition
            let font = withWideString(index == 3 ? "Segoe MDL2 Assets" : "Segoe UI") {
                CreateFontW(
                    -Int32(Double(size) * scale), 0, 0, 0, Int32(weight), 0, 0, 0, DWORD(DEFAULT_CHARSET),
                    DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), $0)
            }
            if let font { fonts.append(font) }
        }
    }
    @discardableResult private func control(
        _ type: String, _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int, style: DWORD = 0,
        fixed: Bool = false, font: Int = 0
    ) -> HWND? {
        guard let window else { return nil }
        let handle = withWideString(type) { name in
            withWideString(type == "STATIC" || type == "BUTTON" ? localization.text(text) : text) {
                CreateWindowExW(
                    type == "EDIT" || type == "LISTBOX" ? DWORD(WS_EX_CLIENTEDGE) : 0, name, $0,
                    DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS) | style, 0, 0, 1, 1, fixed ? window : viewport, HMENU(bitPattern: id),
                    GetModuleHandleW(nil), nil)
            }
        }
        if let handle {
            controls[id] = handle
            layout.append((handle, fixed ? x : x - 272, fixed ? y : y - 144, width, height))
            fontRoles[id] = font
            if !fixed { content.append(handle) }
            if type == "BUTTON", style & DWORD(BS_OWNERDRAW) != 0 { SetWindowSubclass(handle, settingsButtonProcedure, 1, DWORD_PTR(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))) }
            if font < fonts.count { SendMessageW(handle, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[font])), 1) }
            if type == "EDIT" { SendMessageW(handle, UINT(EM_SETLIMITTEXT), 512, 0) }
        }
        return handle
    }
    private func label(
        _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int, large: Bool = false,
        fixed: Bool = false
    ) { _ = control("STATIC", text, id, x, y, width, height, fixed: fixed, font: large ? 1 : 0) }
    private func button(
        _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int = 40, fixed: Bool = false
    ) {
        _ = control("BUTTON", text, id, x, y, width, height, style: DWORD(WS_TABSTOP | BS_OWNERDRAW), fixed: fixed)
    }
    private func edit(_ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int) {
        _ = control("EDIT", text, id, x, y, width, 32, style: DWORD(WS_TABSTOP | ES_AUTOHSCROLL))
    }
    private func check(_ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, on: Bool) {
        if let handle = control("BUTTON", text, id, x, y, width, 30, style: DWORD(WS_TABSTOP | BS_AUTOCHECKBOX)) {
            SendMessageW(handle, UINT(BM_SETCHECK), on ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0)
        }
    }
    private func combo(_ items: [String], _ id: Int, _ x: Int, _ y: Int, _ width: Int, editable: Bool = false) {
        if let handle = control(
            "COMBOBOX", "", id, x, y, width, 220,
            style: DWORD(WS_TABSTOP | WS_VSCROLL) | DWORD(editable ? CBS_DROPDOWN : CBS_DROPDOWNLIST))
        {
            if !editable { comboValues[id] = items }
            for item in items {
                _ = withWideString(editable ? item : localization.text(item)) { SendMessageW(handle, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
            }
            SendMessageW(handle, UINT(CB_SETCURSEL), 0, 0)
        }
    }
    private func text(_ id: Int) -> String {
        guard let handle = controls[id] else { return "" }
        if let values = comboValues[id] {
            let index = Int(SendMessageW(handle, UINT(CB_GETCURSEL), 0, 0))
            if values.indices.contains(index) { return values[index] }
        }
        let capacity=min(8192,max(0,Int(GetWindowTextLengthW(handle))))+1
        var buffer = Array(repeating: WCHAR(0), count: capacity)
        let count = GetWindowTextW(handle, &buffer, Int32(capacity))
        return String(decoding: buffer.prefix(Int(max(0, count))), as: UTF16.self)
    }
    private func checked(_ id: Int) -> Bool {
        controls[id].map { SendMessageW($0, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) } ?? false
    }
    private func setText(_ handle: HWND, _ text: String) { _ = withWideString(text) { SetWindowTextW(handle, $0) } }
    private func status(_ text: String) { if let handle = controls[99] { setText(handle, localization.text(text)) } }
    func showActionError(_ error: Error) {
        let message = String(describing: error)
        status(message)
        guard !preview, !presentingActionError else { return }
        if case WindowsError.api(_, DWORD(ERROR_CANCELLED)) = error { return }
        presentingActionError = true
        defer { presentingActionError = false }
        let focus = GetFocus()
        defer { if let focus, IsWindow(focus), IsWindowEnabled(focus) { SetFocus(focus) } }
        let whole = localization.text(message)
        let translated = whole == message ? message.split(whereSeparator: \.isNewline).map { localization.text(String($0)) }.joined(separator: "\n\n") : whole
        _ = withWideString(translated) { body in
            withWideString(localization.text("Action could not be completed")) { MessageBoxW(window, body, $0, UINT(MB_OK | MB_ICONERROR)) }
        }
    }
    private func updateHomebrewAvailability() {
        let index = controls[502].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
        if let control = controls[511] {
            EnableWindow(control, !wslVirtualizationBlocked && distributions.indices.contains(index) && distributions[index].canInstallHomebrew)
        }
    }
    func updateSearchModel(_ value: SearchModelStatus) {
        searchModelStatus = value
        searchModelStatus.modelIDs = []
        if !value.modelIDs.isEmpty, let field = controls[823] {
            let current = text(823)
            SendMessageW(field, UINT(CB_RESETCONTENT), 0, 0)
            for name in value.modelIDs {
                _ = withWideString(name) { SendMessageW(field, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
            }
            setText(field, current)
        }
        if let label = controls[808] { setText(label,localization.text(value.text)) }
        if let media = controls[839] {
            let compatible = text(823) == NativeSearchModelDescriptor.recommended.repositoryID
            if !compatible { SendMessageW(media, UINT(BM_SETCHECK), WPARAM(BST_UNCHECKED), 0) }
            EnableWindow(media, !value.busy && compatible)
        }
        let selectedReady = value.repositoryID == text(823) && value.downloaded
        if let button = controls[812] { EnableWindow(button,!value.busy && (!selectedReady || (checked(839) && !value.mediaDownloaded)) && checked(821)) }
        if let button = controls[813] { EnableWindow(button,value.busy) }
        if let button = controls[814] { EnableWindow(button,!value.busy) }
        if let button = controls[815] { EnableWindow(button,!value.busy) }
    }
    func updateSearchLibrary(_ text: String) {
        searchLibraryText = text
        if let label = controls[841] { setText(label, localization.text(text)) }
    }
    private func tileState(_ page: Int) -> String {
        switch page {
        case 1: return "\(level)%  ·  " + localization.text(brightnessConfiguration?.ddcEnabled == true ? "DDC/CI" : "Software")
        case 2: return keyboard.enabled ? "On" : "Paused"
        case 3: return keyboard.smartCaps ? "Caps Lock on" : "Ctrl + Space"
        case 4: return "On demand"
        case 5: return keyboard.reverseVertical || keyboard.reverseHorizontal ? "On" : "Off"
        case 6: return "USB + Bluetooth"
        case 7: return "Install in WSL 2"
        case 8: return "On demand"
        case 9: return searchPreferences.enabled ? "Cmd + Space" : "Off"
        default: return "principalwater"
        }
    }
    private func tileText(_ page: Int) -> String {
        localization.text("{0}. {1}. {2}. Open settings.", [localization.text(titles[page]), localization.text(tileDetails[page - 1]), localization.text(tileState(page))])
    }
    private func renderPage() {
        guard let window else { return }
        rendering = true
        if page != 1 { colorNotifications = nil }
        hovered = nil
        brightnessConfiguration = try? Settings()
        let visible = IsWindowVisible(window)
        if visible { SendMessageW(window, UINT(WM_SETREDRAW), 0, 0) }
        defer {
            rendering = false
            if visible { SendMessageW(window, UINT(WM_SETREDRAW), 1, 0) }
            RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE))
        }
        scrollOffset = 0
        for handle in content { DestroyWindow(handle) }
        layout.removeAll { content.contains($0.0) }
        controls = controls.filter { !content.contains($0.value) }
        content.removeAll()
        comboValues.removeAll()
        if let back = controls[100] { ShowWindow(back, Int32(page == 0 ? SW_HIDE : SW_SHOW)); setText(back, localization.text("←  Overview")) }
        if let title = controls[20] { setText(title, localization.text(page == 0 ? "SwiftyToys" : titles[page])) }
        let subtitles = [
            "Small tools for comfortable everyday work.",
            "Precise control of the selected display, preserving calibration.",
            "Customize keys, shortcuts, and actions to fit your habits.",
            "Switch layouts and set up Caps Lock like on Mac.",
            "Keep an important window in view and control sleep mode.", "Familiar scroll direction, like on Mac.",
            "Apple Magic Trackpad gestures via the native Windows engine.",
            "The familiar package manager, on Linux inside Windows.",
            "Native driver diagnostics for Apple hardware running Windows.",
            "Find, calculate and act from a familiar keyboard-first panel.",
            "Made for Mac users and those who've switched to Windows.",
        ]
        if let subtitle = controls[21] { setText(subtitle, localization.text(page == 0 ? "Mac habits. Windows capabilities." : subtitles[page])) }
        if let footer = controls[12] { setText(footer, localization.text("Think Different.  •  Swift. Native. Open source.")) }
        switch page {
        case 0:
            for feature in 1..<titles.count {
                let index = feature - 1
                button(tileText(feature), 120 + feature, 272, 144 + index * 172, 300, 154)
            }
        case 1:
            let settings = brightnessConfiguration
            label(monitorAutomaticBrightness == true
                ? (measuredBrightness ? "Display brightness (automatic)" : "Brightness preference (automatic)")
                : "Display brightness", 209, 300, 168, 650, 25)
            label("\(level)%", 210, 300, 202, 300, 42, large: true)
            if let slider = control("msctls_trackbar32", "Brightness", 211, 300, 254, 650, 40, style: DWORD(WS_TABSTOP | TBS_AUTOTICKS)) {
                SendMessageW(slider, UINT(TBM_SETRANGEMIN), 0, 0); SendMessageW(slider, UINT(TBM_SETRANGEMAX), 0, 100)
                SendMessageW(slider, UINT(TBM_SETPOS), 1, LPARAM(level))
            }
            check("Hardware brightness (DDC/CI)", 244, 300, 318, 650, on: settings?.ddcEnabled ?? false)
            check("Automatic brightness", 252, 300, 356, 650, on: monitorAutomaticBrightness == true)
            label("", 248, 300, 394, 650, 42)
            label("Software compatibility", 247, 300, 444, 650, 25)
            combo(["Automatic", "Windows color controls", "AMD display controls"], 246, 300, 479, 450)
            if let control = controls[246], let selected = Settings.softwareModes.firstIndex(of: settings?.softwareBackend ?? "auto") { SendMessageW(control, UINT(CB_SETCURSEL), WPARAM(selected), 0) }
            button("Apply software method", 245, 770, 477, 180)
            updateBrightnessMode()
            displays = displayReports.outputs ?? []
            if !preview { displayReports.load(destination: MessageDestination(window)) }
            label("Display", 212, 300, 547, 200, 25)
            combo(displays.map(\.name), 213, 300, 579, 444)
            if let selected = displays.firstIndex(where: { $0.id == settings?.targetID }), let combo = controls[213] { SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(selected), 0) }
            button("Select", 214, 764, 577, 170)
            label("Keys and indicator", 249, 300, 649, 650, 30, large: true)
            label("Brightness indicator", 215, 300, 697, 250, 25)
            combo(["SwiftyToys", "Windows"], 216, 300, 729, 210)
            if settings?.indicator == .system, let combo = controls[216] { SendMessageW(combo, UINT(CB_SETCURSEL), 1, 0) }
            label("Step, %", 217, 538, 697, 100, 25)
            edit(String(settings?.step ?? 5), 218, 538, 729, 90)
            check("F1 / F2 without Fn", 219, 660, 729, 274, on: settings?.grabFunctionKeys ?? false)
            let hotkeys = settings?.hotkeys ?? ["Ctrl+Alt+Up", "Ctrl+Alt+Down", "Ctrl+Alt+PageUp", "Ctrl+Alt+PageDown"]
            for index in 0..<4 {
                label(["Increase", "Decrease", "Maximum", "Minimum"][index], 220 + index, 300 + index * 166, 797, 156, 25)
                edit(hotkeys[index], 230 + index, 300 + index * 166, 829, 156)
            }
            button("Save settings", 240, 300, 895, 242)
            button("Reconnect display", 241, 566, 895, 250)
            label("Color profile", 260, 300, 977, 650, 30, large: true)
            label(preview ? "Windows profile: sRGB Color Space Profile.icm" : "Reading Windows color settings…", 261, 300, 1022, 650, 56)
            combo([], 262, 300, 1090, 450)
            button("Apply profile", 263, 770, 1088, 180)
            button("Import ICC…", 264, 300, 1150, 200)
            button("Refresh profiles", 265, 516, 1150, 210)
            button("Windows color settings", 266, 742, 1150, 208)
            label("Uses native Windows color settings for this display and user. Color-managed apps use the selected profile; games may ignore it. Calibration stays under Windows control. Importing requires administrator approval.", 267, 300, 1210, 650, 96)
            updateColorProfiles()
            if !preview { refreshColorProfiles() }
        case 2:
            check("Enable remapping", 315, 300, 152, 350, on: keyboard.enabled)
            if let list = control(
                "LISTBOX", "Remapping rules", 301, 300, 198, 664, 207,
                style: DWORD(WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT))
            {
                for rule in keyboard.rules {
                    let row =
                        "\(rule.source.description)   →   \(rule.destination)\(rule.application.isEmpty ? "" : "   [\(rule.application)]")"
                    _ = withWideString(row) { SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
                }
            }
            label("Source keys", 302, 300, 422, 210, 25)
            edit("", 303, 300, 452, 202)
            label("New shortcut or action", 304, 520, 422, 280, 25)
            combo(
                ["Switch language", "Pin window", "Minimize window", "Lock screen", "Sleep", "Open search", "Disable key", "Ctrl+C", "Alt+Tab"], 305, 520, 452, 238,
                editable: true)
            label("App (empty = all)", 306, 777, 422, 220, 25)
            edit("", 307, 777, 452, 187)
            button("Add / edit", 310, 300, 502, 230)
            button("New", 311, 545, 502, 112)
            button("Delete", 312, 672, 502, 122)
            label("Exclude apps (comma-separated)", 316, 300, 552, 500, 25)
            edit(keyboard.excluded.joined(separator: ","), 317, 300, 582, 390)
            if let handle=controls[317] { SendMessageW(handle,UINT(EM_SETLIMITTEXT),8192,0) }
            button("Save", 313, 710, 581, 122)
            button("Mac profile", 314, 847, 581, 117)
            selectedRule = nil
        case 3:
            label("How to switch language", 340, 300, 170, 630, 38, large: true)
            combo(["Cycle", "Latin ↔ non-Latin", "Selected pair"], 341, 300, 226, 390)
            if let mode = controls[341] {
                SendMessageW(
                    mode, UINT(CB_SETCURSEL),
                    WPARAM(keyboard.languageMode == "latin" ? 1 : keyboard.languageMode == "pair" ? 2 : 0), 0)
            }
            var seen = Set<UInt16>()
            languages = configuredLayouts().map { UInt16(truncatingIfNeeded: UInt(bitPattern: $0)) }.filter {
                seen.insert($0).inserted
            }
            label("First layout in pair", 342, 300, 288, 290, 25)
            combo(languages.map(languageName), 343, 300, 320, 290)
            label("Second layout in pair", 344, 620, 288, 320, 25)
            combo(languages.map(languageName), 345, 620, 320, 324)
            for (offset, id) in [343, 345].enumerated() {
                let language =
                    keyboard.languagePair.indices.contains(offset)
                    ? keyboard.languagePair[offset] : languages.indices.contains(offset) ? languages[offset] : 0
                if let index = languages.firstIndex(of: language), let combo = controls[id] {
                    SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
                }
            }
            check("Caps Lock: tap / hold", 346, 300, 392, 640, on: keyboard.smartCaps)
            label("Tap", 347, 300, 448, 300, 25)
            combo(["Switch language", "Pin window", "Disable key", "Ctrl+Space"], 348, 300, 480, 300, editable: true)
            if let combo = controls[348] { setText(combo, keyboard.capsAction) }
            label("Hold, ms (150–800)", 349, 636, 448, 320, 25)
            edit(String(keyboard.capsThreshold), 351, 636, 480, 130)
            label(
                "Holding turns Caps Lock on. When Caps is already on, a tap turns it off.\nShift + Caps Lock keeps the normal behavior. CJK IMEs are not intercepted.\nThe Ctrl + Space shortcut is changed in the “Keyboard” section.",
                352, 300, 537, 650, 82)
            button("Save switching", 350, 300, 611, 288)
            combo(["US (Apple)", "UK (Apple)"], 355, 608, 612, 112)
            if languages.contains(0x0809), let control = controls[355] { SendMessageW(control, UINT(CB_SETCURSEL), 1, 0) }
            button("Use Apple RU + EN", 356, 742, 611, 220)
        case 4:
            label("Always on top", 400, 300, 172, 550, 36, large: true)
            label(
                "⌘ + Ctrl + T pins the active window.\nPressing again restores the normal window order.", 401, 300,
                226, 620, 62)
            label("Stay awake", 402, 300, 344, 500, 36, large: true)
            label("Temporary mode: system power settings are preserved.", 403, 300, 397, 620, 48)
            combo(["30 minutes", "1 hour", "2 hours", "8 hours"], 404, 300, 466, 200)
            check("Keep screen on", 405, 526, 466, 380, on: false)
            button("Enable", 410, 300, 526, 180)
            button("Disable", 411, 500, 526, 180)
        case 5:
            let actual = preview ? nil : try? NativeMouseScrolling.current()
            if let actual {
                keyboard.reverseVertical = actual.vertical ?? false
                keyboard.reverseHorizontal = actual.horizontal ?? false
            }
            label("Natural scrolling", 420, 300, 176, 640, 40, large: true)
            label(
                "Change the wheel direction of a regular mouse.\nVertical and horizontal scrolling are set separately.",
                421, 300, 234, 640, 64)
            check("Invert vertical wheel", 422, 300, 338, 640, on: keyboard.reverseVertical)
            check("Invert horizontal wheel", 423, 300, 392, 640, on: keyboard.reverseHorizontal)
            label(
                "Windows changes physical wheel direction for connected HID mice.\nThis includes Ctrl / Shift + wheel in all apps and games.\nAdministrator approval is required; mice briefly reconnect.\nPrecision Touchpads keep their Windows scrolling settings.",
                424, 300, 460, 640, 112)
            button("Apply native scrolling", 430, 300, 591, 320)
            button("Windows mouse settings", 431, 642, 591, 300)
            label(actual?.summary ?? "", 428, 300, 630, 640, 36)
            if let actual {
                for (id, mixed) in [(422, actual.vertical == nil), (423, actual.horizontal == nil)] where mixed && !actual.devices.isEmpty {
                    if let control = controls[id] { SendMessageW(control, UINT(BM_SETCHECK), WPARAM(BST_INDETERMINATE), 0) }
                }
            }
        case 6:
            label("Apple Magic Trackpad", 450, 300, 170, 650, 40, large: true)
            label(deviceReports.text(6, locale: localization.pack.locale) ?? "Reading device information…", 451, 300, 212, 650, 82)
            if !preview { deviceReports.load(6, language: localization.pack, destination: MessageDestination(window)) }
            label("Driver source", 458, 300, 298, 350, 24)
            combo(["Apple Boot Camp (USB + Bluetooth)", "Open source: imbushuo (experimental Bluetooth)"], 459, 300, 326, 578)
            button("Install Precision driver", 452, 300, 380, 350)
            button("Refresh", 453, 678, 380, 200)
            button("Windows gestures and scrolling", 454, 300, 436, 350)
            button("Restore previous driver", 457, 678, 436, 268)
            button("Connect via Bluetooth", 455, 300, 491, 350)
            button("Repair Bluetooth pairing", 460, 678, 491, 268)
            label(
                "Two fingers: scroll, zoom, and right-click.\nThree / four: windows, desktops, and assignable shortcuts.\nSmoothness and recognition are provided by Windows Precision Touchpad.\nSet the direction in Windows: wheel inversion is for a regular mouse.\nOver Bluetooth, pairing in Windows and a free connection are required.\nForce Touch and app behavior may differ from macOS.",
                456, 300, 539, 650, 108)
        case 7:
            let setup: WSLSetup?
            var failure = ""
            do {
                var value = try WSLSetup.current(checkBoot: false)
                value.virtualizationBootFailure = wslBootDiagnostic.result
                setup = value
                if !preview { wslBootDiagnostic.start(destination: MessageDestination(window)) }
            } catch { setup = nil; failure = String(describing: error) }
            distributions = setup?.distributions ?? LinuxDistribution.installed()
            ubuntuInstalled = setup?.ubuntuInstalled ?? false
            wslVirtualizationBlocked = setup?.virtualizationBootFailure == true
            label(
                setup?.title ?? "WSL status unavailable", 500, 300, 170, 660,
                40, large: true)
            label(
                setup?.detail ?? failure,
                501, 300, 228, 650, 90)
            combo(distributions.map { $0.version == 0 ? "\($0.name) (\(localization.text("WSL version unavailable")))" : "\($0.name) (WSL \($0.version))" }, 502, 300, 326, 450)
            if let control = controls[502] { EnableWindow(control, !distributions.isEmpty) }
            button("Refresh list", 503, 772, 324, 192)
            button("Install WSL components", 510, 300, 393, 282)
            button("Install Ubuntu", 514, 604, 393, 278)
            button("Open Linux setup", 513, 300, 441, 282)
            button("Install Homebrew", 511, 604, 441, 278)
            if let control = controls[513] { EnableWindow(control, ubuntuInstalled || !distributions.isEmpty) }
            updateHomebrewAvailability()
            label(
                "WSL may require administrator rights and a restart.\nAfter the first Ubuntu launch, create a Linux user.\nHomebrew will open a terminal: you'll see the steps and enter your sudo password yourself.\nThen brew and the PATH setup for Bash will appear.",
                504, 300, 494, 650, 110)
            button("Official guide", 512, 300, 609, 282)
        case 8:
            label("Boot Camp drivers", 700, 300, 166, 650, 40, large: true)
            label("Installed versions are shown below. Update through Windows Update or Apple Software Update; compatibility must match your Mac model.", 704, 300, 218, 650, 64)
            if let report = control("EDIT", "", 701, 300, 294, 650, 282, style: DWORD(WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY)) {
                SendMessageW(report, UINT(EM_SETLIMITTEXT), 65536, 0)
                setText(report, deviceReports.text(8, locale: localization.pack.locale) ?? localization.text("Reading device information…"))
            }
            if !preview { deviceReports.load(8, language: localization.pack, destination: MessageDestination(window)) }
            button("Windows Update", 702, 300, 594, 214)
            button("Device Manager", 703, 534, 594, 214)
            button("Refresh drivers", 705, 768, 594, 182)
        case 9:
            label("SwiftyToys Search",800,300,166,650,42,large:true)
            check("Enable SwiftyToys Search",801,300,228,650,on:searchPreferences.enabled)
            label("Cmd + Space opens Search. Currency, units and number/time formats follow Windows regional settings; explicit conversion targets take priority.",802,300,274,650,60)
            button("Open Search",811,300,345,200)
            label("Quick Keys · one per line",844,300,410,650,30)
            label("Use alias = command name, such as calc = Calculator. Type the alias in Search, then press Enter. Leave empty to keep normal matching.",845,300,454,650,60)
            if let field = control("EDIT",searchPreferences.quickKeys.editorText,846,300,532,650,90,
                style:DWORD(WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL)) {
                SendMessageW(field, UINT(EM_SETLIMITTEXT), 8_192, 0)
            }
            label("Commands: " + SearchCommands.items.map(\.title).joined(separator: ", "),
                847,300,648,650,92)
            check("Enable local semantic search",803,300,760,650,on:searchPreferences.semantic)
            label("A persistent local library combines exact text and meaning. Your files stay on this PC. Use code:, pdf:, image:, audio: or video: to narrow results.",804,300,804,650,66)
            check("Automatically include all available local drives",822,300,885,650,on:searchPreferences.allLocalDrives)
            label("Additional folders · one per line",805,300,937,520,24)
            _ = control("EDIT",searchPreferences.folder,806,300,971,520,72,style:DWORD(WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL))
            button("Browse…",816,838,971,112)
            label("Excluded folders · one per line",830,300,1067,650,24)
            _ = control("EDIT",searchPreferences.exclusions,831,300,1101,650,72,style:DWORD(WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL))
            label("System, cache, linked, cloud-only and credential files are excluded. Heavy content analysis waits for idle time; indexing can pause and resume.",807,300,1199,650,66)
            label(searchLibraryText,841,300,1279,650,72)
            button(searchPreferences.indexPaused ? "Resume indexing" : "Pause indexing",840,300,1368,220)
            button("Index status",842,540,1368,180)
            button("Rebuild library",843,740,1368,210)
            label("Embedding model · Hugging Face repository ID",824,300,1437,650,24)
            combo(NativeSearchModelCatalog.builtIns.map(\.repositoryID),823,300,1471,650,editable:true)
            if let field = controls[823] { setText(field,searchPreferences.modelRepository) }
            button("Find models",826,300,1528,180)
            button("Check compatibility",827,500,1528,230)
            button("Model card",828,750,1528,200)
            label("Recommended: EmbeddingGemma 2. Other models need a supported native ONNX/tokenizer adapter; incompatible models receive an explanation.",829,300,1594,650,66)
            check("Include image, audio and video encoders · about 535 MB extra",839,300,1675,650,on:searchPreferences.media)
            label(searchModelStatus.text,808,300,1731,650,84)
            button("Runtime license",819,300,1834,240)
            button("Model license",820,560,1834,220)
            check("I accept the Microsoft runtime terms and the selected model license",821,300,1892,650,on:false)
            button("Download selected model",812,300,1956,280)
            button("Cancel download",813,600,1956,170)
            button("Remove model",814,790,1956,160)
            label("Models run in bounded native workers. The basic app stays small; weights are downloaded separately and remain optional.",809,300,2012,650,66)
            button("Save search settings",810,300,2088,280)
            button("Refresh model status",815,600,2088,260)
            button("Status details",817,300,2148,180)
            updateSearchModel(searchModelStatus)
            if !preview { _ = try? command(815,[]) }
        default:
            label("Think Different.", 600, 300, 166, 650, 46, large: true)
            label("On Windows.  •  SwiftyToys \(AppVersion.string)", 602, 300, 220, 650, 30)
            label(
                "Author: principalwater. Inspired by Apple's approach to computing.\nSwift + native Windows APIs. Local settings, no telemetry.\n\nBrightnessCtl code is built into SwiftyToys. The toolset and tiled\ninterface are inspired by Microsoft PowerToys — we extend them for Mac habits.\n\nMIT License. Independent project; not affiliated with Microsoft or Apple.",
                601, 300, 278, 650, 180)
            button("Author on GitHub", 612, 300, 480, 252)
            button("SwiftyToys source code", 613, 580, 480, 304)
            button("Microsoft PowerToys", 610, 300, 538, 252)
            button("BrightnessCtl", 611, 580, 538, 232)
            label("Display language", 620, 300, 598, 250, 25)
            languagePacks = localization.available()
            combo(languagePacks.map(\.name), 621, 580, 594, 304)
            if let control = controls[621], let selected = languagePacks.firstIndex(where: { $0.locale == localization.pack.locale }) {
                SendMessageW(control, UINT(CB_SETCURSEL), WPARAM(selected), 0)
            }
        }
        status(preview ? "Interface preview — changes are disabled." : "")
        arrange()
        InvalidateRect(window, nil, true)
    }
    private func arrange() {
        guard let window, let viewport else { return }
        var area = RECT(); GetClientRect(window, &area)
        let width = max(1, Int(Double(area.right) / scale))
        let height = max(1, Int(Double(area.bottom) / scale))
        let bodyWidth = page == 0 ? width - 64 : min(960, width - 64)
        let bodyTop = page == 0 ? 148 : 180
        let bodyHeight = max(1, height - bodyTop - 88)
        let bodyLeft = (width - bodyWidth) / 2
        MoveWindow(viewport, Int32(Double(bodyLeft) * scale), Int32(Double(bodyTop) * scale), Int32(Double(bodyWidth) * scale), Int32(Double(bodyHeight) * scale), false)
        let columns = bodyWidth >= 900 ? 3 : 2
        let tileWidth = (bodyWidth - (columns - 1) * 18 - 18) / columns
        let extent = page == 0 ? ((titles.count - 2) / columns + 1) * 172 - 18 : max(1, layout.filter { content.contains($0.0) }.map { $0.2 + $0.4 }.max() ?? 1) + 24
        var scroll = SCROLLINFO(); scroll.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        scroll.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS); scroll.nMax = Int32(Double(extent) * scale)
        scroll.nPage = UINT(Double(bodyHeight) * scale); scroll.nPos = scrollOffset
        SetScrollInfo(viewport, Int32(SB_VERT), &scroll, true)
        scrollOffset = GetScrollPos(viewport, Int32(SB_VERT))
        var viewportArea = RECT(); GetClientRect(viewport, &viewportArea)
        let usableWidth = Int(Double(viewportArea.right) / scale)
        var positions: [(HWND, Int32, Int32, Int32, Int32, Bool)] = []
        for (handle, originalX, originalY, originalWidth, originalHeight) in layout {
            let id = Int(GetDlgCtrlID(handle))
            var x = originalX, y = originalY, w = originalWidth, h = originalHeight
            let scrolling = content.contains(handle)
            if (121..<(120 + titles.count)).contains(id) {
                let index = id - 121
                x = (index % columns) * (tileWidth + 18); y = (index / columns) * 172; w = tileWidth; h = 154
            } else if scrolling, w >= 600 { w += max(0, usableWidth - 704) }
            if id == 13 { x = width - 182 }
            if id == 20 { x = page == 0 ? 104 : 32; y = page == 0 ? 28 : 76; w = width - (page == 0 ? 310 : 64) }
            if id == 21 { x = page == 0 ? 106 : 34; y = page == 0 ? 78 : 128; w = width - (page == 0 ? 140 : 68) }
            if id == 99 { y = height - 78; w = width - 64 }
            if id == 12 { y = height - 34; w = width - 64 }
            let top = Int32(Double(y) * scale) - (scrolling ? scrollOffset : 0)
            positions.append((handle, Int32(Double(x) * scale), top, Int32(Double(w) * scale), Int32(Double(h) * scale), scrolling))
        }
        // Win32 requires every HWND in a deferred batch to share one parent.
        for scrolling in [false, true] {
            let group = positions.filter { $0.5 == scrolling }
            guard !group.isEmpty else { continue }
            var batch = BeginDeferWindowPos(Int32(group.count))
            for (handle, x, y, w, h, _) in group {
                guard let current = batch else { break }
                batch = DeferWindowPos(current, handle, nil, x, y, w, h, UINT(SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_NOREDRAW))
            }
            let applied = batch.map { EndDeferWindowPos($0) } ?? false
            if !applied { for (handle, x, y, w, h, _) in group { MoveWindow(handle, x, y, w, h, false) } }
        }
        RedrawWindow(viewport, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN))
    }

    fileprivate func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        switch message {
        case displayListMessage:
            guard page == 1, let combo = controls[213], let updated = displayReports.outputs else { return 0 }
            let index = Int(SendMessageW(combo, UINT(CB_GETCURSEL), 0, 0))
            let selected = displays.indices.contains(index) ? displays[index].id : brightnessConfiguration?.targetID
            displays = updated
            SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
            for display in displays { _ = withWideString(display.name) { SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
            if let index = displays.firstIndex(where: { $0.id == selected }) {
                SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
            }
            updateColorProfiles()
            return 0
        case colorProfilesMessage:
            updateColorProfiles()
            if colorProfilesRefreshPending { refreshColorProfiles() }
            return 0
        case colorProfileChangedMessage:
            if value == 1 { status("Live color updates are unavailable. Use Refresh profiles or reopen this page.") }
            else { refreshColorProfiles() }
            return 0
        case UINT(WM_DISPLAYCHANGE), UINT(WM_DEVICECHANGE):
            if !preview { displayReports.load(destination: MessageDestination(window), refresh: true) }
            return DefWindowProcW(window, message, value, data)
        case deviceReportMessage:
            let reported = Int(value)
            if page == reported {
                if let text = deviceReports.text(page, locale: localization.pack.locale), let control = controls[page == 6 ? 451 : 701] { setText(control, text); status("Device information updated.") }
                else { deviceReports.load(page, language: localization.pack, destination: MessageDestination(window)) }
            }
            return 0
        case wslBootResultMessage:
            if page == 7, IsWindowVisible(window) {
                do {
                    var value = try WSLSetup.current(checkBoot: false)
                    value.virtualizationBootFailure = wslBootDiagnostic.result
                    wslVirtualizationBlocked = value.virtualizationBootFailure == true
                    if let control = controls[500] { setText(control, localization.text(value.title)) }
                    if let control = controls[501] { setText(control, localization.text(value.detail)) }
                    updateHomebrewAvailability()
                    if value.virtualizationBootFailure == nil { status("Boot diagnostics unavailable; package and distribution status is still shown.") }
                } catch { status(String(describing: error)) }
            }
            return 0
        case UINT(WM_CLOSE):
            colorNotifications = nil
            ShowWindow(window, Int32(SW_HIDE))
            if preview {
                DestroyWindow(window)
                PostQuitMessage(0)
            }
            return 0
        case UINT(WM_SIZE):
            arrange()
            RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN))
            return 0
        case UINT(WM_ACTIVATE):
            if value & 0xFFFF == WPARAM(WA_INACTIVE) { lastFocusedControl = GetFocus().map { Int(GetDlgCtrlID($0)) } }
            else if let id = lastFocusedControl, let control = controls[id], IsWindowVisible(control), IsWindowEnabled(control) { SetFocus(control) }
            if value & 0xFFFF != WPARAM(WA_INACTIVE) { refreshColorProfiles() }
            return 0
        case UINT(WM_GETMINMAXINFO):
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(data)) {
                info.pointee.ptMinTrackSize = POINT(x: Int32(780 * scale), y: Int32(620 * scale))
            }
            return 0
        case UINT(WM_VSCROLL):
            var info = SCROLLINFO()
            info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
            info.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS)
            GetScrollInfo(viewport, Int32(SB_VERT), &info)
            switch Int(value & 0xFFFF) {
            case Int(SB_LINEUP): scrollOffset -= Int32(32 * scale)
            case Int(SB_LINEDOWN): scrollOffset += Int32(32 * scale)
            case Int(SB_PAGEUP): scrollOffset -= Int32(info.nPage)
            case Int(SB_PAGEDOWN): scrollOffset += Int32(info.nPage)
            case Int(SB_THUMBTRACK): scrollOffset = info.nTrackPos
            default: break
            }
            scrollOffset = max(0, min(scrollOffset, info.nMax - Int32(info.nPage) + 1))
            arrange()
            InvalidateRect(viewport, nil, false)
            return 0
        case UINT(WM_MOUSEWHEEL):
            let delta=Int32(Int16(bitPattern:UInt16(truncatingIfNeeded:value >> 16)))
            let units = wheelRemainder + delta * Int32(40 * scale)
            scrollOffset = max(0, scrollOffset - units / 120); wheelRemainder = units % 120
            arrange(); InvalidateRect(viewport,nil,false); return 0
        case UINT(WM_DPICHANGED):
            let focus = GetFocus().map { Int(GetDlgCtrlID($0)) }
            captureDraft()
            if let area = UnsafePointer<RECT>(bitPattern: Int(data))?.pointee {
                SetWindowPos(
                    window, nil, area.left, area.top, area.right - area.left, area.bottom - area.top,
                    UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            do { try updateIcons() } catch { Diagnostics.write("UI: application icon resize failed") }
            makeFonts()
            for (id, handle) in controls {
                let role = fontRoles[id] ?? 0
                if fonts.indices.contains(role) { SendMessageW(handle, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[role])), 1) }
            }
            renderPage()
            restoreDraft()
            if let focus, let control = controls[focus] { SetFocus(control) }
            return 0
        case UINT(WM_SETTINGCHANGE), UINT(WM_SYSCOLORCHANGE), UINT(WM_THEMECHANGED):
            if message == UINT(WM_SETTINGCHANGE) { refreshColorProfiles() }
            makeTheme()
            RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN))
            return 0
        case UINT(WM_COMMAND):
            let id = Int(value & 0xFFFF)
            let notification = Int((value >> 16) & 0xFFFF)
            if [263, 264, 265, 266].contains(id), notification == Int(BN_CLICKED) {
                guard !preview else { return 0 }
                do {
                    if id == 266 { try shellOpen(try systemExecutable("colorcpl.exe"), owner: window) }
                    else if id == 265 { refreshColorProfiles() }
                    else if id == 264 {
                        if let output = colorOutput, let file = try SettingsColorProfiles.chooseProfile(owner: window, title: localization.text("Import ICC profile")) {
                            try colorProfiles.importProfile(file: file, output: output, destination: MessageDestination(window))
                            status("Installing ICC profile. Approve the Windows administrator prompt.")
                            brightnessControlBusy(modeBusy)
                        }
                    } else {
                        let index = Int(controls[262].map { SendMessageW($0, UINT(CB_GETCURSEL), 0, 0) } ?? -1)
                        guard let output = colorOutput, colorProfileNames.indices.contains(index) else {
                            throw WindowsError.unsupported("Select a color profile before applying.")
                        }
                        importedColorProfile = nil
                        colorProfiles.forgetImport()
                        status(try command(263, [output.id, colorProfileNames[index]]))
                    }
                } catch { showActionError(error) }
                return 0
            }
            if [453, 705].contains(id), notification == Int(BN_CLICKED), !preview {
                deviceReports.load(page, language: localization.pack, destination: MessageDestination(window), refresh: true)
                status("Reading device information…")
                return 0
            }
            if id == 502, notification == Int(CBN_SELCHANGE) { updateHomebrewAvailability(); return 0 }
            if (id == 821 || id == 839), notification == Int(BN_CLICKED) { updateSearchModel(searchModelStatus); return 0 }
            if id == 823, notification == Int(CBN_EDITCHANGE) || notification == Int(CBN_SELCHANGE) {
                if let check = controls[821] { SendMessageW(check, UINT(BM_SETCHECK), WPARAM(BST_UNCHECKED), 0) }
                updateSearchModel(searchModelStatus); return 0
            }
            if id == 244, notification == Int(BN_CLICKED) {
                brightnessControlBusy(false)
                if !preview {
                    let choice = checked(244) ? "hardware" : Settings.softwareModes[max(0, min(Settings.softwareModes.count - 1, Int(controls[246].map { SendMessageW($0, UINT(CB_GETCURSEL), 0, 0) } ?? 0)))]
                    do { status(try command(245, [choice])) } catch { refreshBrightnessControl(); showActionError(error) }
                }
                return 0
            }
            if id == 252, notification == Int(BN_CLICKED) {
                if !preview {
                    do { status(try command(252, [checked(252) ? "1" : "0"])) }
                    catch { updateAutomaticBrightness(monitorAutomaticBrightness); showActionError(error) }
                }
                return 0
            }
            if id == 621, notification == Int(CBN_SELCHANGE), let control = controls[621] {
                let index = Int(SendMessageW(control, UINT(CB_GETCURSEL), 0, 0))
                if languagePacks.indices.contains(index) {
                    do {
                        captureDraft(); try localization.select(languagePacks[index], persist: !preview); renderPage(); restoreDraft()
                        if let control = controls[621] { SetFocus(control) }
                    }
                    catch { showActionError(error) }
                }
                return 0
            }
            if id == 100, notification == Int(BN_CLICKED) {
                navigate(to: 0)
                return 0
            }
            if (121..<(120 + titles.count)).contains(id), notification == Int(BN_CLICKED) {
                navigate(to: id - 120)
                return 0
            }
            if id == 301, notification == Int(LBN_SELCHANGE), let list = controls[301] {
                let index = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
                if keyboard.rules.indices.contains(index) {
                    selectedRule = index
                    let rule = keyboard.rules[index]
                    if let from = controls[303] { setText(from, rule.source.description) }
                    if let to = controls[305] { setText(to, rule.destination) }
                    if let app = controls[307] { setText(app, rule.application) }
                }
                return 0
            }
            guard notification == Int(BN_CLICKED) else { break }
            if [219, 244, 315, 346, 405].contains(id) {
                status("Changed. Apply settings with the Save button.")
                return 0
            }
            if id == 422 || id == 423 { status("Changed. Click Apply native scrolling."); return 0 }
            if id == Int(IDCANCEL) { ShowWindow(window, Int32(SW_HIDE)); return 0 }
            if id == Int(IDOK) { return 0 }
            do {
                if id == 810 {
                    do { searchPreferences.quickKeys = try SearchQuickKeys(editorText: text(846)) }
                    catch { throw WindowsError.unsupported(String(describing: error)) }
                    searchPreferences.enabled = checked(801); searchPreferences.semantic = checked(803); searchPreferences.folder = text(806)
                    searchPreferences.allLocalDrives = checked(822); searchPreferences.exclusions = text(831)
                    searchPreferences.modelRepository = text(823); searchPreferences.media = checked(839)
                    status(try command(810,[searchPreferences.enabled ? "1" : "0",searchPreferences.semantic ? "1" : "0",searchPreferences.folder,
                        searchPreferences.allLocalDrives ? "1" : "0", searchPreferences.exclusions,
                        searchPreferences.modelRepository, searchPreferences.media ? "1" : "0",
                        searchPreferences.quickKeys.serialized]))
                    return 0
                }
                if (811...815).contains(id) {
                    if id == 812, !checked(821) { throw WindowsError.unsupported("Read and accept the component licenses before downloading.") }
                    status(try command(id,[text(823),checked(839) ? "1" : "0"])); return 0
                }
                if id == 816 { if let path = try NativeSearchFolderPicker.choose(owner:window), let field = controls[806] { let existing = text(806); setText(field,existing.isEmpty ? path : existing + "\r\n" + path) }; return 0 }
                if id == 826 || id == 827 { status(try command(id,[text(823)])); return 0 }
                if id == 828 || id == 820 {
                    let id = text(823)
                    guard NativeSearchModelCatalog.validRepositoryID(id) else { throw WindowsError.unsupported("Enter a model ID in owner/model form.") }
                    try shellOpen("https://huggingface.co/" + id); return 0
                }
                if id == 840 || id == 842 || id == 843 {
                    status(try command(id,[]))
                    if id == 840 {
                        searchPreferences.indexPaused.toggle()
                        if let control = controls[840] {
                            setText(control, searchPreferences.indexPaused ? "Resume indexing" : "Pause indexing")
                        }
                    }
                    return 0
                }
                if id == 817 { _ = withWideString(searchModelStatus.text) { value in withWideString("Optional search model") { MessageBoxW(window,value,$0,UINT(MB_OK | MB_ICONINFORMATION)) } }; return 0 }
                if id == 819 || id == 820 {
                    let root = executablePath().split(separator:"\\").dropLast().joined(separator:"\\")
                    try shellOpen(root + "\\Licenses\\" + (id == 819 ? "WindowsML.txt" : "EmbeddingGemma2.txt")); return 0
                }
                if id == 311 {
                    selectedRule = nil
                    if let handle = controls[303] {
                        setText(handle, "")
                        SetFocus(handle)
                    }
                    return 0
                }
                if id == 310 {
                    let rule = try RemapRule(from: text(303), to: text(305), application: text(307))
                    if let index = selectedRule {
                        keyboard.rules[index] = rule
                    } else {
                        guard keyboard.rules.count < 64 else { throw WindowsError.unsupported("Maximum 64 rules.") }
                        keyboard.rules.append(rule)
                        selectedRule = keyboard.rules.count - 1
                    }
                    captureDraft()
                    renderPage()
                    restoreDraft()
                    if let control = controls[303] { SetFocus(control) }
                    return 0
                }
                if id == 312, let index = selectedRule {
                    captureDraft()
                    keyboard.rules.remove(at: index)
                    for key in [303, 305, 307] { draftText[2]?.removeValue(forKey: key) }
                    draftRuleSelection = nil
                    renderPage()
                    restoreDraft()
                    return 0
                }
                if id == 314 {
                    captureDraft()
                    keyboard.rules = RemapRule.macPreset
                    for key in [303, 305, 307] { draftText[2]?.removeValue(forKey: key) }
                    draftRuleSelection = nil
                    renderPage()
                    restoreDraft()
                    status("Profile restored. Click “Save”.")
                    return 0
                }
                if id == 503 || id == 453 || id == 705 {
                    renderPage()
                    if let control = controls[id] { SetFocus(control) }
                    return 0
                }
                if id == 512 {
                    try shellOpen("https://docs.brew.sh/Installation")
                    return 0
                }
                if id == 702 || id == 703 {
                    try shellOpen(id == 702 ? "ms-settings:windowsupdate" : "devmgmt.msc")
                    return 0
                }
                if (610...613).contains(id) {
                    let links = ["https://github.com/microsoft/PowerToys", "https://github.com/principalwater/BrightnessCtl", "https://github.com/principalwater", "https://github.com/principalwater/SwiftyToys"]
                    try shellOpen(links[id - 610])
                    return 0
                }
                if id == 454 || id == 455 || id == 431 {
                    try shellOpen(id == 455 ? "ms-settings:bluetooth" : id == 454 ? "ms-settings:devices-touchpad" : "ms-settings:mousetouchpad")
                    return 0
                }
                guard !preview else {
                    status("Preview: run the regular version to apply.")
                    return 0
                }
                if id == 313 {
                    keyboard.enabled = checked(315)
                    keyboard.excluded = text(317).split(separator: ",").map { $0.trimmingWhitespace().lowercased() }
                    try keyboard.save()
                    status(try command(id, []))
                } else if id == 356 {
                    let english = controls[355].map { SendMessageW($0, UINT(CB_GETCURSEL), 0, 0) == 1 ? "uk" : "us" } ?? "us"
                    try shellOpen(executablePath(), arguments: "--apple-layouts " + english, owner: window)
                    status("Applying Apple input profiles.")
                } else if id == 510 {
                    try WSLSetup.install(owner: window)
                    status("Follow the Windows component installer instructions. Restart if requested, then install Ubuntu for this user.")
                } else if id == 514 {
                    try WSLSetup.installUbuntu(owner: window)
                    status("Ubuntu installs for this Windows user. When finished, open Linux setup and refresh.")
                } else if id == 513 {
                    let index = controls[502].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    if distributions.indices.contains(index) {
                        let distribution = distributions[index]
                        if distribution.name == "Ubuntu", ubuntuInstalled { try WSLSetup.openUbuntu() }
                        else { try shellOpen(systemExecutable("wsl.exe"), arguments: "--distribution \(distribution.name)") }
                    } else if ubuntuInstalled { try WSLSetup.openUbuntu() }
                    else { throw WindowsError.unsupported("Open your Linux distribution and create a non-root user first.") }
                    status("Complete Linux user setup in the terminal, then refresh this page.")
                } else if id == 511 {
                    let index = controls[502].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    guard distributions.indices.contains(index) else {
                        throw WindowsError.unsupported("Install and initialize a WSL 2 distribution first.")
                    }
                    try distributions[index].openHomebrewInstaller()
                    status("The official installer is open in the Linux terminal.")
                } else if id == 214 {
                    let index = controls[213].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    guard displays.indices.contains(index) else {
                        throw WindowsError.unsupported("No eligible physical SDR display.")
                    }
                    status(try command(id, [displays[index].id]))
                } else if id == 240 {
                    status(
                        try command(
                            id,
                            [text(216), text(218), checked(219) ? "1" : "0"] + (230...233).map { text($0) }))
                } else if id == 410 {
                    status(try command(id, [text(404), checked(405) ? "1" : "0"]))
                } else if id == 430 {
                    let vertical = checked(422); let horizontal = checked(423)
                    status(try command(430, [vertical ? "1" : "0", horizontal ? "1" : "0"]))
                } else if id == 452 || id == 457 || id == 460 {
                    if id == 460 {
                        let choice = withWideString(localization.text("Disconnect the trackpad USB cable first. This exports and removes only the pinned Apple Precision Bluetooth package. USB support is retained. Other connected Apple devices using the package block the action. Then restart Windows, pair Bluetooth without USB, verify pointer input, and install the Apple driver again. Continue?")) { message in
                            withWideString(localization.text("Repair Bluetooth pairing")) { MessageBoxW(window, message, $0, UINT(MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2)) }
                        }
                        guard choice == IDYES else { return 0 }
                    }
                    let source = id == 460 ? "Apple" : controls[459].map { SendMessageW($0, UINT(CB_GETCURSEL), 0, 0) == 1 ? "Imbushuo" : "Apple" } ?? "Apple"
                    try TrackpadStatus.openInstaller(owner: window, source: source, rollback: id == 457, repairBluetooth: id == 460)
                    status("Installer opened. After installing, refresh the device status.")
                } else if id == 350 {
                    let mode = controls[341].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? 0
                    let first = controls[343].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    let second = controls[345].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    let pair =
                        languages.indices.contains(first) && languages.indices.contains(second)
                        ? [languages[first], languages[second]] : []
                    keyboard.smartCaps = checked(346)
                    keyboard.capsThreshold = Int(text(351)) ?? 0
                    keyboard.capsAction = text(348)
                    keyboard.languageMode = mode == 1 ? "latin" : mode == 2 ? "pair" : "cycle"
                    keyboard.languagePair = pair
                    status(
                        try command(
                            id,
                            [
                                keyboard.smartCaps ? "1" : "0", String(keyboard.capsThreshold), keyboard.capsAction,
                                keyboard.languageMode, pair.map(String.init).joined(separator: ","),
                            ]))
                } else if id == 241 || id == 411 {
                    status(try command(id, []))
                } else if id == 245 {
                    let modes = Settings.softwareModes
                    let selected = controls[246].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    guard modes.indices.contains(selected) else { throw WindowsError.unsupported("Invalid brightness mode.") }
                    status(try command(id, [modes[selected]]))
                }
            } catch { showActionError(error) }
            return 0
        case UINT(WM_HSCROLL):
            if let slider = controls[211] {
                level = Int(SendMessageW(slider, UINT(TBM_GETPOS), 0, 0))
                if let label = controls[210] { setText(label, "\(level)%") }
                if pendingBrightness == nil { SetTimer(window, 24, 120, nil) }
                pendingBrightness = level
            }
            return 0
        case UINT(WM_TIMER):
            if value == 24 {
                KillTimer(window, 24)
                let desired = pendingBrightness
                pendingBrightness = nil
                if !preview, let desired {
                    do { status(try command(211, [String(desired)])) } catch { status(String(describing: error)) }
                }
            }
            return 0
        case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
            let dc = HDC(bitPattern: UInt(value))
            SetBkMode(dc, Int32(TRANSPARENT))
            let child = HWND(bitPattern: Int(data))
            let id = child.map { Int(GetDlgCtrlID($0)) } ?? 0
            let outside = child.map { GetParent($0) == self.window } ?? false
            SetTextColor(dc, [12, 21, 99, 248].contains(id) ? secondaryColor : textColor)
            SetBkColor(dc, outside ? backgroundColor : highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00FF_FFFF)
            return LRESULT(Int(bitPattern: outside || page == 0 ? background : white))
        case UINT(WM_DRAWITEM):
            if let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: Int(data))?.pointee { drawButton(item) }
            return 1
        case UINT(WM_ERASEBKGND), UINT(WM_PRINTCLIENT):
            if let dc = HDC(bitPattern: UInt(value)) { paintBackground(dc, window) }
            return 1
        case UINT(WM_PAINT):
            paint(window)
            return 0
        default: break
        }
        return DefWindowProcW(window, message, value, data)
    }
    private func paint(_ window: HWND) {
        var paint = PAINTSTRUCT()
        guard let dc = BeginPaint(window, &paint) else { return }
        defer { EndPaint(window, &paint) }
        paintBackground(dc, window)
    }
    private func paintBackground(_ dc: HDC, _ window: HWND) {
        var area = RECT(); GetClientRect(window, &area)
        FillRect(dc, &area, background)
        if let brandIcon {
            let size = Int32((page == 0 ? 56 : 32) * scale)
            DrawIconEx(dc, Int32(32 * scale), Int32((page == 0 ? 28 : 24) * scale), brandIcon.handle, size, size, 0, nil, UINT(DI_NORMAL))
        }
        if page != 0, let viewport {
            var panel = RECT(); GetWindowRect(viewport, &panel)
            _ = withUnsafeMutablePointer(to: &panel) { $0.withMemoryRebound(to: POINT.self, capacity: 2) { MapWindowPoints(nil, window, $0, 2) } }
            InflateRect(&panel, 1, 1)
            let brush = SelectObject(dc, white)
            let pen = CreatePen(Int32(PS_SOLID), 1, borderColor); let previous = SelectObject(dc, pen)
            RoundRect(dc, panel.left - Int32(8 * scale), panel.top - Int32(8 * scale), panel.right + Int32(8 * scale), panel.bottom + Int32(8 * scale), Int32(28 * scale), Int32(28 * scale))
            SelectObject(dc, previous); SelectObject(dc, brush); DeleteObject(pen)
        }
    }
    fileprivate func paintViewport(_ dc: HDC, _ window: HWND) {
        var area = RECT(); GetClientRect(window, &area)
        FillRect(dc, &area, page == 0 ? background : white)
    }
    private func drawButton(_ item: DRAWITEMSTRUCT) {
        guard let dc = item.hDC else { return }
        let id = Int(item.CtlID)
        let tile = (121..<(120 + titles.count)).contains(id)
        let badge = id == 13
        let pressed = item.itemState & UINT(ODS_SELECTED) != 0
        let hot = hovered == item.hwndItem
        let disabled = item.itemState & UINT(ODS_DISABLED) != 0
        var itemArea = item.rcItem
        FillRect(dc, &itemArea, page == 0 || id < 120 ? background : white)
        let primary = [240, 245, 313, 350, 410, 430, 510, 511].contains(id) && !tile && !badge
        let color: COLORREF = highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : primary && !disabled ? (pressed ? 0x0024_37B6 : 0x002B_41C8) : badge || pressed ? 0x00EF_F2FE : hot ? 0x00F9_FAFF : 0x00FF_FFFF
        let brush = CreateSolidBrush(color); let previousBrush = SelectObject(dc, brush)
        let pen = CreatePen(Int32(PS_SOLID), 1, hot && !disabled ? accentColor : borderColor); let previousPen = SelectObject(dc, pen)
        let radius = Int32((tile ? 28 : 20) * scale)
        RoundRect(dc, item.rcItem.left + 1, item.rcItem.top + 1, item.rcItem.right - 1, item.rcItem.bottom - 1, radius, radius)
        SelectObject(dc, previousBrush); SelectObject(dc, previousPen); DeleteObject(brush); DeleteObject(pen)
        SetBkMode(dc, Int32(TRANSPARENT))
        SetTextColor(dc, disabled ? GetSysColor(Int32(COLOR_GRAYTEXT)) : textColor)
        let previousFont = fonts.first.map { SelectObject(dc, $0) }
        defer { if let previousFont { SelectObject(dc, previousFont) } }
        var rect = item.rcItem
        if tile {
            let feature = id - 120
            let glyphBrush = CreateSolidBrush(highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00F0_F2FE)
            let glyphPrevious = SelectObject(dc, glyphBrush)
            let glyphPen = SelectObject(dc, GetStockObject(Int32(NULL_PEN)))
            RoundRect(dc, item.rcItem.left + Int32(14 * scale), item.rcItem.top + Int32(16 * scale), item.rcItem.left + Int32(54 * scale), item.rcItem.top + Int32(56 * scale), Int32(18 * scale), Int32(18 * scale))
            SelectObject(dc, glyphPen); SelectObject(dc, glyphPrevious); DeleteObject(glyphBrush)
            rect.left += Int32(20 * scale); rect.top += Int32(22 * scale); rect.bottom = rect.top + Int32(30 * scale)
            if fonts.count > 3 { SelectObject(dc, fonts[3]) }
            SetTextColor(dc, accentColor)
            _ = withWideString(tileGlyphs[feature - 1]) { DrawTextW(dc, $0, -1, &rect, UINT(DT_LEFT | DT_SINGLELINE)) }
            rect.left += Int32(42 * scale); rect.right -= Int32(18 * scale)
            if fonts.count > 2 { SelectObject(dc, fonts[2]) }
            SetTextColor(dc, textColor)
            _ = withWideString(localization.text(titles[feature])) { DrawTextW(dc, $0, -1, &rect, UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS)) }
            rect.left = item.rcItem.left + Int32(20 * scale); rect.top = item.rcItem.top + Int32(67 * scale); rect.right = item.rcItem.right - Int32(20 * scale); rect.bottom = item.rcItem.bottom - Int32(40 * scale)
            if !fonts.isEmpty { SelectObject(dc, fonts[0]) }
            SetTextColor(dc, secondaryColor)
            _ = withWideString(localization.text(tileDetails[feature - 1])) { DrawTextW(dc, $0, -1, &rect, UINT(DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS)) }
            rect.top = item.rcItem.bottom - Int32(32 * scale); rect.bottom = item.rcItem.bottom - Int32(9 * scale)
            let state = localization.text(tileState(feature))
            var stateSize = SIZE()
            _ = withWideString(state) { GetTextExtentPoint32W(dc, $0, Int32(state.utf16.count), &stateSize) }
            let pillRight = min(rect.right - Int32(28 * scale), rect.left + stateSize.cx + Int32(20 * scale))
            if !highContrast {
                let pillBrush = CreateSolidBrush(0x00EF_F2FE)
                let oldBrush = SelectObject(dc, pillBrush); let oldPen = SelectObject(dc, GetStockObject(Int32(NULL_PEN)))
                RoundRect(dc, rect.left, rect.top, pillRight, rect.bottom, Int32(22 * scale), Int32(22 * scale))
                SelectObject(dc, oldPen); SelectObject(dc, oldBrush); DeleteObject(pillBrush)
            }
            rect.left += Int32(10 * scale); rect.right = pillRight - Int32(8 * scale)
            SetTextColor(dc, accentColor)
            _ = withWideString(state) { DrawTextW(dc, $0, -1, &rect, UINT(DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS)) }
            var arrow = item.rcItem; arrow.left = arrow.right - Int32(38 * scale); arrow.top = rect.top
            _ = withWideString("→") { DrawTextW(dc, $0, -1, &arrow, UINT(DT_SINGLELINE)) }
        } else {
            InflateRect(&rect, -Int32(8 * scale), 0)
            SetTextColor(dc, disabled ? GetSysColor(Int32(COLOR_GRAYTEXT)) : primary && !highContrast ? 0x00FF_FFFF : id == 100 || badge ? accentColor : textColor)
            _ = withWideString(text(id)) { DrawTextW(dc, $0, -1, &rect, UINT(DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS)) }
        }
        if item.itemState & UINT(ODS_FOCUS) != 0, item.itemState & UINT(ODS_NOFOCUSRECT) == 0 { var focus = item.rcItem; InflateRect(&focus, -4, -4); DrawFocusRect(dc, &focus) }
    }
    deinit {
        if let window, IsWindow(window) { DestroyWindow(window) }
        for font in fonts { DeleteObject(font) }
        DeleteObject(background)
        DeleteObject(white)
    }
}
