// SPDX-License-Identifier: MIT

import BrightnessCore
import KeyboardCore
import Synchronization
import WinSDK
import WindowsDisplayABI

private let trayMessage: UINT = 0x8004
private let displayReplyMessage: UINT = 0x8035
private final class SleepGate: Sendable { let busy = Mutex(false) }
private func windowProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window else { return DefWindowProcW(window, message, value, data) }
    if message == UINT(WM_NCCREATE), let creation = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(data)),
        let context = creation.pointee.lpCreateParams
    {
        SetWindowLongPtrW(window, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: context)))
    }
    let address = GetWindowLongPtrW(window, Int32(GWLP_USERDATA))
    if address != 0, let context = UnsafeRawPointer(bitPattern: Int(address)) {
        return Unmanaged<TrayApplication>.fromOpaque(context).takeUnretainedValue().handle(window, message, value, data)
    }
    return DefWindowProcW(window, message, value, data)
}
/// Thread-affine Win32 UI. Only Sendable messages and values leave this thread.
final class TrayApplication {
    private let controller: DisplayController
    private var settings: Settings
    private var state: DisplayState
    private var window: HWND?
    private var osd: HWND?
    private var remapper: KeyboardRemapper?
    private var reloadingInput = false
    private var applyingMouseScroll = false
    private var dashboard: SettingsWindow?
    private let tools = DesktopTools()
    private let sleepGate = SleepGate()
    private var systemIndicator: SystemIndicator?
    private var tray = NOTIFYICONDATAW()
    private var trayAdded = false
    private var trayText = ""
    private var exiting = false
    private var pendingSteps = 0
    private var lastApply: UInt64 = 0
    private let displayMailbox = DisplayMailbox()
    private var displayQueue = DisplayRequestQueue(level: 100)
    private let taskbarCreated = withWideString("TaskbarCreated") { RegisterWindowMessageW($0) }

    init(settings: Settings) throws {
        self.settings = settings
        controller = try DisplayController(settings: settings)
        state = DisplayState(level: settings.brightness, device: "", backend: "unavailable", connected: false)
        displayQueue.level = settings.brightness.percent
        var initialized = false
        defer {
            if !initialized {
                shutdown()
                if let window { DestroyWindow(window) }
            }
        }
        try registerWindowClass("SwiftyToys.Control")
        try registerWindowClass("SwiftyToys.OSD")
        window = try createWindow(
            "SwiftyToys.Control", title: controlWindowTitle, style: 0, extended: DWORD(WS_EX_TOOLWINDOW))
        osd = try createWindow(
            "SwiftyToys.OSD", title: "SwiftyToys", style: DWORD(WS_POPUP),
            extended: DWORD(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TOPMOST))
        guard let window, let osd else { throw WindowsError.api("CreateWindow", GetLastError()) }
        WTSRegisterSessionNotification(window, DWORD(NOTIFY_FOR_THIS_SESSION))
        remapper = try KeyboardRemapper(
            destination: MessageDestination(window), configuration: KeyboardConfiguration(),
            brightnessKeys: settings.grabFunctionKeys, allowInjectedBrightness: settings.interceptInjectedKeys)
        SetLayeredWindowAttributes(osd, 0, 235, DWORD(LWA_ALPHA))
        tray.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        tray.hWnd = window
        tray.uID = 1
        tray.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        tray.uCallbackMessage = trayMessage
        tray.hIcon = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32516))
        updateTray()
        for (index, hotkey) in settings.hotkeys.enumerated() {
            if let combo = parseHotkey(hotkey),
                !RegisterHotKey(window, Int32(index + 1), combo.modifiers | UINT(MOD_NOREPEAT), combo.key)
            {
                Diagnostics.write("input: configured hotkey \(index + 1) is already registered")
            }
        }
        systemIndicator = try SystemIndicator(
            destination: MessageDestination(window), custom: settings.indicator == .custom,
            hardwareKeys: settings.grabFunctionKeys)
        SetTimer(window, 1, 3000, nil)
        requestDisplay(DisplayRequest(3))
        Diagnostics.write(
            "start: \(AppVersion.implementation) \(AppVersion.string); dedicated input active=\(remapper?.active ?? false)"
        )
        initialized = true
    }

    private func registerWindowClass(_ name: String) throws {
        var type = WNDCLASSEXW()
        type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = windowProcedure
        type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        let atom = withWideString(name) {
            type.lpszClassName = $0
            return RegisterClassExW(&type)
        }
        guard atom != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS) else {
            throw WindowsError.api("RegisterClass", GetLastError())
        }
    }

    private func createWindow(_ type: String, title: String, style: DWORD, extended: DWORD) throws -> HWND {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handle = withWideString(type) { className in
            withWideString(title) {
                CreateWindowExW(extended, className, $0, style, 0, 0, 280, 92, nil, nil, GetModuleHandleW(nil), context)
            }
        }
        guard let handle else { throw WindowsError.api("CreateWindow", GetLastError()) }
        return handle
    }

    func run() throws {
        var message = MSG()
        while true {
            let result = BC_GetMessageW(&message, nil, 0, 0)
            if result == 0 { break }
            if result < 0 { throw WindowsError.api("GetMessage", GetLastError()) }
            if dashboard?.dialogMessage(&message) == true { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }

    func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        if window == osd {
            if message == UINT(WM_PAINT) {
                paintOSD(window)
                return 0
            }
            if message == UINT(WM_TIMER) {
                KillTimer(window, 1)
                ShowWindow(window, Int32(SW_HIDE))
                return 0
            }
            return DefWindowProcW(window, message, value, data)
        }
        if message == taskbarCreated {
            trayAdded = false
            updateTray()
            return 0
        }
        switch message {
        case mouseScrollResultMessage:
            applyingMouseScroll = value == 4
            do {
                var configuration = try KeyboardConfiguration()
                let actual = try NativeMouseScrolling.current()
                if value == 0 || value == 2 {
                    configuration.reverseVertical = actual.vertical ?? (data & 1 != 0)
                    configuration.reverseHorizontal = actual.horizontal ?? (data & 2 != 0)
                    try configuration.save()
                }
                dashboard?.updateScrolling(vertical: actual.vertical ?? configuration.reverseVertical, horizontal: actual.horizontal ?? configuration.reverseHorizontal,
                    result: value == 0 ? "Native scrolling applied." : value == 2 ? "Direction saved. Reconnect the mouse to apply it." : value == 4 ? "Windows is still configuring the mouse. Waiting without blocking settings." : value == 1223 ? "Native scrolling was cancelled." : "Mouse configuration failed. Current device values are shown; verify the direction.")
            } catch {
                Diagnostics.write("native mouse preferences: \(error)")
                dashboard?.updateScrolling(vertical: data & 1 != 0, horizontal: data & 2 != 0, result: "Could not read or save the mouse state. Verify Windows mouse direction.")
            }
            return 0
        case sleepResultMessage:
            guard !exiting, value != 0 else { return 0 }
            let error = WindowsError.api("Put computer to sleep", DWORD(truncatingIfNeeded: value))
            Diagnostics.write("sleep: \(error)")
            do { try showDashboard(); dashboard?.showActionError(error) }
            catch { Diagnostics.write("show power error: \(error)") }
            return 0
        case toyActionMessage:
            guard !exiting else { return 0 }
            do {
                if value == 1 {
                    try switchLanguage(in: HWND(bitPattern: Int(data)))
                } else if value == 2 {
                    try tools.togglePin(HWND(bitPattern: Int(data)))
                } else if value == 3 {
                    guard Int(data) == remapper?.generation else { return 0 }
                    if remapper?.stop() != false { remapper = nil }
                    Diagnostics.write(
                        "remapping paused after failed SendInput; elevated windows require matching privileges")
                } else if value == 4 {
                    try showDashboard()
                } else if value == 5 {
                    try tools.minimize(HWND(bitPattern: Int(data)))
                } else if value == 6 {
                    guard data >= 0, data <= 3 else { throw WindowsError.unsupported("Invalid mouse direction request.") }
                    _ = try dashboardCommand(430, [data & 1 == 0 ? "0" : "1", data & 2 == 0 ? "0" : "1"])
                } else if value == 7 {
                    try reloadRemapper()
                    dashboard?.refreshLanguages(result: data == 1 ? "Apple input profiles updated." : "Windows could not update input profiles. Verify language settings.")
                } else if value == 8 {
                    try DesktopPower.lock()
                } else if value == 9 {
                    guard sleepGate.busy.withLock({ busy in if busy { return false }; busy = true; return true }) else { return 0 }
                    let destination = MessageDestination(window)
                    let gate = sleepGate
                    do {
                        _ = try NativeThread(name: "SwiftyToys sleep") {
                            defer { gate.busy.withLock { $0 = false } }
                            do { try DesktopPower.sleep() }
                            catch {
                                Diagnostics.write("sleep: \(error)")
                                let code: DWORD
                                if case WindowsError.api(_, let value) = error { code = value } else { code = DWORD(ERROR_GEN_FAILURE) }
                                _ = destination.post(sleepResultMessage, value: Int(code == 0 ? DWORD(ERROR_GEN_FAILURE) : code))
                            }
                        }
                    } catch { gate.busy.withLock { $0 = false }; throw error }
                }
            } catch {
                Diagnostics.write("desktop action: \(error)")
                if value == 8 || value == 9 {
                    do { try showDashboard(); dashboard?.showActionError(error) }
                    catch { Diagnostics.write("show power error: \(error)") }
                }
            }
            return 0
        case displayReplyMessage:
            guard !exiting, let request = displayQueue.active, let reply = displayMailbox.result.withLock({ value in defer { value = nil }; return value }) else { return 0 }
            var displayError: Error?
            do {
                state = try reply.get()
                lastApply = GetTickCount64()
                updateTray()
                dashboard?.update(brightness: displayQueue.hasBrightness ? displayQueue.level : state.level.percent)
                if request.command == 1 { dashboard?.displayCompleted("Brightness updated.") }
                if request.show { showOSD() }
            } catch {
                Diagnostics.write("display: \(error)")
                if request.mode != nil { displayError = error }
            }
            if request.mode != nil {
                if let latest = try? Settings() { settings = latest }
                dashboard?.refreshBrightnessControl()
                dashboard?.brightnessControlBusy(false)
                if case .success = reply { dashboard?.displayCompleted(settings.ddcEnabled ? "DDC/CI enabled. Brightness controls the monitor backlight, including the cursor." : "DDC/CI disabled. Brightness uses software dimming; the monitor backlight stays unchanged.") }
            }
            if let next = displayQueue.finish(level: state.level.percent) { requestDisplay(next) }
            if let displayError, let dashboard, let window = dashboard.window, IsWindowVisible(window) { dashboard.showActionError(displayError) }
            return 0
        case brightnessMessage:
            guard !exiting else { return 0 }
            if value == 6 {
                let modes = ["auto", "native", "amd", "hardware"]
                guard displayQueue.active == nil, modes.indices.contains(Int(data)) else { return 0 }
                do {
                    state = try displayCommand(controller, command: 3, mode: modes[Int(data)])
                    settings = try Settings(); displayQueue.level = state.level.percent
                    dashboard?.refreshBrightnessControl(); dashboard?.update(brightness: state.level.percent); updateTray()
                    return LRESULT(state.level.percent + 1)
                }
                catch { Diagnostics.write("brightness mode: \(error)"); return 0 }
            }
            if value == 5 {
                do {
                    settings.indicator = try Settings().indicator
                    systemIndicator?.setCustom(settings.indicator == .custom)
                    if let osd { ShowWindow(osd, Int32(SW_HIDE)) }
                    return LRESULT(state.level.percent + 1)
                } catch {
                    Diagnostics.write("indicator: \(error)")
                    return 0
                }
            }
            if value == 4 {
                PostMessageW(window, UINT(WM_CLOSE), 0, 0)
                return 1
            }
            return apply(command: Int(value), value: Int(data), show: value == 1 || value == 2)
                ? LRESULT(state.level.percent + 1) : 0
        case keyStepMessage:
            if !exiting { queue(Int(Int64(bitPattern: value))) }
            return 0
        case UINT(WM_HOTKEY):
            if value == 1 {
                queue(1)
            } else if value == 2 {
                queue(-1)
            } else if value == 3 {
                requestDisplay(DisplayRequest(1, value: 100, show: true))
            } else if value == 4 {
                requestDisplay(DisplayRequest(1, value: 0, show: true))
            }
            return 0
        case UINT(WM_TIMER):
            guard !exiting else { return 0 }
            if value == 2 {
                flushSteps()
            } else {
                tools.tick()
                requestDisplay(DisplayRequest(4))
            }
            return 0
        case UINT(WM_DISPLAYCHANGE):
            if !exiting {
                requestDisplay(DisplayRequest(5))
            }
            return 0
        case UINT(WM_POWERBROADCAST):
            if value == WPARAM(PBT_APMRESUMEAUTOMATIC) || value == WPARAM(PBT_APMRESUMESUSPEND) {
                requestDisplay(DisplayRequest(settings.restoreOnResume ? 5 : 1, value: 100))
            }
            return 1
        case trayMessage:
            if UINT(truncatingIfNeeded: data) == UINT(WM_RBUTTONUP) {
                showMenu()
            } else if UINT(truncatingIfNeeded: data) == UINT(WM_LBUTTONUP) {
                do { try showDashboard() } catch { Diagnostics.write("settings: \(error)") }
            }
            return 0
        case UINT(WM_QUERYENDSESSION): return 1
        case UINT(WM_WTSSESSION_CHANGE):
            if value == WPARAM(WTS_SESSION_LOCK) {
                if remapper?.stop() != false { remapper = nil }
            } else if value == WPARAM(WTS_SESSION_UNLOCK) {
                do { try reloadRemapper() } catch { Diagnostics.write("unlock input: \(error)") }
            }
            return 0
        case UINT(WM_ENDSESSION):
            if value != 0 {
                shutdown()
                DestroyWindow(window)
            }
            return 0
        case UINT(WM_CLOSE):
            shutdown()
            DestroyWindow(window)
            return 0
        case UINT(WM_DESTROY):
            PostQuitMessage(0)
            return 0
        default: break
        }
        return DefWindowProcW(window, message, value, data)
    }

    private func apply(command: Int, value: Int = 0, show: Bool) -> Bool {
        guard !exiting, displayQueue.active == nil else { return false }
        do {
            state = try displayCommand(controller, command: command, value: value)
            displayQueue.level = state.level.percent
            lastApply = GetTickCount64()
            if command == 3 {
                settings.indicator = try Settings().indicator
                systemIndicator?.setCustom(settings.indicator == .custom)
            }
            updateTray()
            dashboard?.update(brightness: state.level.percent)
            if show { showOSD() }
            return true
        } catch {
            Diagnostics.write("software: \(error)")
            return false
        }
    }

    /// Keep one actor request in flight; retain only the latest slider/key intent.
    private func requestDisplay(_ request: DisplayRequest) {
        guard !exiting, let window else { return }
        let start = displayQueue.enqueue(request)
        if request.mode != nil { dashboard?.brightnessControlBusy(true) }
        guard start else { return }
        let mailbox = displayMailbox, controller = controller, destination = MessageDestination(window)
        Task {
            let reply: Result<DisplayState, WindowsError>
            do { reply = .success(try await performDisplayCommand(controller, command: request.command, value: request.value, mode: request.mode)) }
            catch { reply = .failure((error as? WindowsError) ?? .unsupported(String(describing: error))) }
            mailbox.result.withLock { $0 = reply }
            _ = destination.post(displayReplyMessage)
        }
    }

    private func queue(_ steps: Int) {
        pendingSteps = max(-20, min(20, pendingSteps + max(-20, min(20, steps))))
        if GetTickCount64() - lastApply >= 130 { flushSteps() } else if let window { SetTimer(window, 2, 130, nil) }
    }

    private func reloadRemapper() throws {
        guard !exiting, !reloadingInput else { throw WindowsError.unsupported("Input settings are already changing.") }
        reloadingInput = true
        defer { reloadingInput = false }
        let configuration = try KeyboardConfiguration()
        guard remapper?.stop() != false else {
            throw WindowsError.unsupported("Input worker did not stop within 5 seconds. Previous worker retained; try again after it finishes.")
        }
        remapper = nil
        guard !exiting else { throw WindowsError.unsupported("Application is closing.") }
        remapper = try KeyboardRemapper(
            destination: MessageDestination(window!), configuration: configuration,
            brightnessKeys: settings.grabFunctionKeys, allowInjectedBrightness: settings.interceptInjectedKeys)
    }

    private func showDashboard() throws {
        if dashboard == nil {
            dashboard = try SettingsWindow(
                brightness: state.level.percent, keyboard: KeyboardConfiguration(),
                command: { [weak self] id, values in
                    guard let self else { throw WindowsError.unsupported("Application is closing.") }
                    return try self.dashboardCommand(id, values)
                })
        }
        dashboard?.show()
    }

    private func dashboardCommand(_ id: Int, _ values: [String]) throws -> String {
        switch id {
        case 211:
            guard let value = values.first.flatMap(Int.init), (0...100).contains(value) else { throw WindowsError.unsupported("Brightness must be 0–100%.") }
            requestDisplay(DisplayRequest(1, value: value))
            return "Applying brightness…"
        case 214:
            try settings.select(values[0])
            requestDisplay(DisplayRequest(3))
            return "Reconnecting display…"
        case 240:
            guard values.count == 7, let step = Int(values[1]), (1...25).contains(step) else {
                throw WindowsError.unsupported("Brightness step must be 1–25%.")
            }
            let keys = Array(values[3...6])
            let parsed=keys.compactMap(parseHotkey)
            guard Set(parsed.map { "\($0.modifiers):\($0.key)" }).count == parsed.count,
                keys.allSatisfy({ $0.isEmpty || parseHotkey($0) != nil }) else {
                throw WindowsError.unsupported("Use four valid, distinct brightness shortcuts.")
            }
            if let window {
                let previous = settings.hotkeys
                for id in 1...4 { UnregisterHotKey(window, Int32(id)) }
                var success = true
                for (index, key) in keys.enumerated() {
                    guard let combo = parseHotkey(key) else { continue }
                    if !RegisterHotKey(window, Int32(index + 1), combo.modifiers | UINT(MOD_NOREPEAT), combo.key) {
                        success = false
                        break
                    }
                }
                if !success {
                    for id in 1...4 { UnregisterHotKey(window, Int32(id)) }
                    for (index, key) in previous.enumerated() {
                        if let combo = parseHotkey(key) {
                            RegisterHotKey(window, Int32(index + 1), combo.modifiers | UINT(MOD_NOREPEAT), combo.key)
                        }
                    }
                    throw WindowsError.unsupported(
                        "A shortcut is used by another application. Previous settings restored.")
                }
            }
            for (key, value) in zip(
                ["osd", "step", "grabF1F2", "up", "down", "max", "min"],
                [values[0] == "Windows" ? "system" : "custom", String(step), values[2]] + keys)
            { try settings.setValue(value, forKey: key) }
            settings = try Settings()
            try reloadRemapper()
            systemIndicator = nil
            systemIndicator = try SystemIndicator(
                destination: MessageDestination(window!), custom: settings.indicator == .custom,
                hardwareKeys: settings.grabFunctionKeys)
        case 241: requestDisplay(DisplayRequest(3)); return "Reconnecting display…"
        case 245:
            guard values.count == 1, ["auto", "native", "amd", "hardware"].contains(values[0]) else { throw WindowsError.unsupported("Invalid brightness mode.") }
            requestDisplay(DisplayRequest(3, mode: values[0]))
            return "Applying brightness method…"
        case 313: try reloadRemapper()
        case 410:
            let minutes =
                values[0].hasPrefix("30") ? 30 : values[0].hasPrefix("1") ? 60 : values[0].hasPrefix("2") ? 120 : 480
            try tools.awake(minutes: minutes, display: values[1] == "1")
            return "Mode enabled for \(minutes) minutes."
        case 411:
            try tools.awake(minutes: 0, display: false)
            return "Normal power mode restored."
        case 430:
            guard !applyingMouseScroll else { throw WindowsError.unsupported("Native mouse configuration is already running.") }
            guard values.count == 2, values.allSatisfy({ $0 == "0" || $0 == "1" }) else { throw WindowsError.unsupported("Invalid mouse direction request.") }
            if try NativeMouseScrolling.current().matches(vertical: values[0] == "1", horizontal: values[1] == "1") { return "Native scrolling is already applied." }
            applyingMouseScroll = true
            do { try NativeMouseScrolling.apply(owner: window!, vertical: values[0] == "1", horizontal: values[1] == "1") }
            catch { applyingMouseScroll = false; throw error }
            return "Applying native scrolling. Confirm the Windows administrator prompt."
        case 350:
            var configuration = try KeyboardConfiguration()
            configuration.smartCaps = values[0] == "1"
            configuration.capsThreshold = Int(values[1]) ?? 0
            configuration.capsAction = values[2]
            configuration.languageMode = values[3]
            configuration.languagePair = values[4].split(separator: ",").compactMap { UInt16($0) }
            guard
                configuration.languageMode != "pair"
                    || (configuration.languagePair.count == 2 && Set(configuration.languagePair).count == 2)
            else { throw WindowsError.unsupported("Choose two different installed languages.") }
            try configuration.save()
            try reloadRemapper()
        default: break
        }
        return "Done. Settings applied."
    }
    private func flushSteps() {
        if let window { KillTimer(window, 2) }
        let steps = pendingSteps
        pendingSteps = 0
        if steps != 0 { requestDisplay(DisplayRequest(1, value: max(0, min(100, displayQueue.level + steps * settings.step)), show: true)) }
    }

    private func updateTray() {
        let text = "SwiftyToys — \(state.level.percent)%\(state.connected ? "" : " (disconnected)")"
        guard !trayAdded || text != trayText else { return }
        setWideString(text, in: &tray.szTip)
        if trayAdded {
            if Shell_NotifyIconW(DWORD(NIM_MODIFY), &tray) { trayText = text }
        } else {
            trayAdded = Shell_NotifyIconW(DWORD(NIM_ADD), &tray)
            if trayAdded { trayText = text }
        }
    }

    private func showMenu() {
        guard let window, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        let localization = Localization()
        for (id, label) in [
            (2500, "Open SwiftyToys"), (2501, "Pause / resume keyboard remapping"),
            (0, localization.text("Brightness: {0}%", [String(state.level.percent)])), (1, localization.text("Increase by {0}%", [String(settings.step)])),
            (2, localization.text("Decrease by {0}%", [String(settings.step)])),
            (100, "100%"), (75, "75%"), (50, "50%"), (25, "25%"), (10, "10%"), (3, "Reconnect display"),
        ] {
            _ = withWideString(localization.text(label)) {
                AppendMenuW(menu, UINT(MF_STRING | (id == 0 ? MF_DISABLED : 0)), UINT_PTR(id), $0)
            }
        }
        for (id, mode, label) in [
            (2001, IndicatorMode.custom, "Indicator: SwiftyToys"),
            (2002, IndicatorMode.system, "Indicator: Windows"),
        ] {
            _ = withWideString(localization.text(label)) {
                AppendMenuW(menu, UINT(MF_STRING | (settings.indicator == mode ? MF_CHECKED : 0)), UINT_PTR(id), $0)
            }
        }
        CheckMenuRadioItem(menu, 2001, 2002, settings.indicator == .custom ? 2001 : 2002, UINT(MF_BYCOMMAND))
        _ = withWideString(localization.text("Quit")) { AppendMenuW(menu, UINT(MF_STRING), 4, $0) }
        var point = POINT()
        GetCursorPos(&point)
        SetForegroundWindow(window)
        let selected = BC_TrackPopupMenu(menu, UINT(TPM_RETURNCMD | TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
        if selected == 2500 {
            do { try showDashboard() } catch { Diagnostics.write("settings: \(error)") }
        } else if selected == 2501 {
            do {
                var config = try KeyboardConfiguration()
                config.enabled.toggle()
                try config.save()
                try reloadRemapper()
            } catch { Diagnostics.write("keyboard: \(error)") }
        } else if selected == 1 {
            queue(1)
        } else if selected == 2 {
            queue(-1)
        } else if selected == 3 {
            requestDisplay(DisplayRequest(3))
        } else if selected == 4 {
            PostMessageW(window, UINT(WM_CLOSE), 0, 0)
        } else if selected == 2001 || selected == 2002 {
            do {
                try settings.setIndicator(selected == 2001 ? .custom : .system)
                systemIndicator?.setCustom(settings.indicator == .custom)
                if let osd { ShowWindow(osd, Int32(SW_HIDE)) }
            } catch { Diagnostics.write("indicator: \(error)") }
        } else if [10, 25, 50, 75, 100].contains(selected) {
            requestDisplay(DisplayRequest(1, value: Int(selected), show: true))
        }
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    private func showOSD() {
        guard settings.indicator == .custom else { return }
        guard let osd, let monitor = monitorForDevice(state.device) else { return }
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(monitor, &info) else { return }
        // Repeated updates stay at the final position. Only a monitor change
        // needs an initial DPI move, and that move must happen while hidden.
        if MonitorFromWindow(osd, DWORD(MONITOR_DEFAULTTONEAREST)) != monitor {
            SetWindowPos(
                osd, nil, info.rcWork.left, info.rcWork.top, 0, 0,
                UINT(SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE | SWP_HIDEWINDOW))
        }
        let scale = Double(GetDpiForWindow(osd)) / 96
        let width = Int32(280 * scale)
        let height = Int32(92 * scale)
        let area = info.rcWork
        SetWindowPos(
            osd, HWND(bitPattern: -1), area.left + (area.right - area.left - width) / 2,
            area.bottom - height - Int32(110 * scale), width, height, UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW))
        InvalidateRect(osd, nil, false)
        SetTimer(osd, 1, 1100, nil)
    }

    private func paintOSD(_ window: HWND) {
        var paint = PAINTSTRUCT()
        guard let dc = BeginPaint(window, &paint) else { return }
        defer { EndPaint(window, &paint) }
        var area = RECT()
        GetClientRect(window, &area)
        let scale = Double(GetDpiForWindow(window)) / 96
        func fill(_ rectangle: RECT, _ color: COLORREF) {
            let brush = CreateSolidBrush(color)
            defer { DeleteObject(brush) }
            var rectangle = rectangle
            FillRect(dc, &rectangle, brush)
        }
        fill(area, 0x001B_1818)
        SetBkMode(dc, Int32(TRANSPARENT))
        SetTextColor(dc, 0x00F5_F0F0)
        let font = withWideString("Segoe UI") {
            CreateFontW(
                -Int32(24 * scale), 0, 0, 0, 600, 0, 0, 0, DWORD(DEFAULT_CHARSET),
                DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH),
                $0)
        }
        let previous = SelectObject(dc, font)
        defer {
            SelectObject(dc, previous)
            DeleteObject(font)
        }
        var text = RECT(
            left: Int32(20 * scale), top: Int32(14 * scale), right: area.right - Int32(20 * scale),
            bottom: Int32(52 * scale))
        _ = withWideString("☀  \(state.level.percent)%") {
            DrawTextW(dc, $0, -1, &text, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
        }
        var bar = RECT(
            left: Int32(20 * scale), top: Int32(64 * scale), right: area.right - Int32(20 * scale),
            bottom: Int32(72 * scale))
        fill(bar, 0x0040_3A3A)
        bar.right = bar.left + (bar.right - bar.left) * Int32(state.level.percent) / 100
        fill(bar, 0x005A_B2F5)
    }

    func shutdown() {
        guard !exiting else { return }
        exiting = true
        dashboard = nil
        remapper?.stop()
        remapper = nil
        tools.stop()
        systemIndicator = nil
        if let window {
            WTSUnRegisterSessionNotification(window)
            KillTimer(window, 1)
            KillTimer(window, 2)
            for id in 1...4 { UnregisterHotKey(window, Int32(id)) }
        }
        stopDisplay(controller)
        Shell_NotifyIconW(DWORD(NIM_DELETE), &tray)
        if let osd { DestroyWindow(osd) }
        Diagnostics.write("exit: output restored")
    }

    deinit { shutdown() }
}
private func parseHotkey(_ text: String) -> (modifiers: UINT, key: UINT)? {
    guard let chord=try? KeyChord(text), !chord.isReserved, KeyChord.modifier(for:chord.key) == 0 else { return nil }
    return (UINT(chord.modifiers),UINT(chord.key))
}
