// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK
import WindowsDisplayABI

private let indicatorModeMessage: UINT = 0x8005

// Set/used/cleared only on the observer thread. OUTOFCONTEXT callbacks run
// on the thread that installed the hook, without another UI-queue hop.
nonisolated(unsafe) private var activeIndicator: Unmanaged<IndicatorWatcher>?
private func indicatorShown(
    _ hook: HWINEVENTHOOK?, _ event: DWORD, _ window: HWND?, _ object: LONG,
    _ child: LONG, _ thread: DWORD, _ timestamp: DWORD
) {
    guard let window, object == 0, child == 0 else { return }
    activeIndicator?.takeUnretainedValue().event(event, window: window, timestamp: timestamp)
}
private func indicatorForegroundChanged(
    _ hook: HWINEVENTHOOK?, _ event: DWORD, _ window: HWND?, _ object: LONG,
    _ child: LONG, _ thread: DWORD, _ timestamp: DWORD
) {
    activeIndicator?.takeUnretainedValue().cancelBrightnessKeys()
}

// Mutex protects every shared value. Event handles stay alive through the
// worker's retained reference, including startup/shutdown timeouts.
private final class IndicatorState: @unchecked Sendable {
    struct Values {
        var custom: Bool
        var threadID: DWORD = 0
        var stopped = false
        var error: WindowsError?
    }
    let values: Mutex<Values>
    let destination: MessageDestination
    let hardwareKeys: Bool
    let ready: OwnedHandle
    let finished: OwnedHandle

    init(destination: MessageDestination, custom: Bool, hardwareKeys: Bool) throws {
        self.destination = destination
        self.hardwareKeys = hardwareKeys
        values = Mutex(Values(custom: custom))
        ready = try OwnedHandle(CreateEventW(nil, true, false, nil))
        finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
    }
}

/// Owns an observer independent of UI, input and display-driver work.
/// Only mutex-protected state crosses threads; the worker owns its HWNDs.
final class SystemIndicator {
    private let state: IndicatorState
    private let thread: NativeThread

    init(destination: MessageDestination, custom: Bool, hardwareKeys: Bool) throws {
        let state = try IndicatorState(destination: destination, custom: custom, hardwareKeys: hardwareKeys)
        self.state = state
        thread = try NativeThread(name: "SwiftyToys system indicator") {
            defer {
                state.values.withLock { $0.threadID = 0 }
                SetEvent(state.ready.raw)
                SetEvent(state.finished.raw)
            }
            var message = MSG()
            PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE))
            guard
                state.values.withLock({ values in
                    guard !values.stopped else { return false }
                    values.threadID = GetCurrentThreadId()
                    return true
                })
            else { return }
            do {
                let watcher = try IndicatorWatcher(state: state)
                defer { watcher.stop() }
                SetEvent(state.ready.raw)
                while true {
                    let result = BC_GetMessageW(&message, nil, 0, 0)
                    if result == 0 { break }
                    if result < 0 { throw WindowsError.api("Indicator GetMessage", GetLastError()) }
                    if message.message == indicatorModeMessage {
                        watcher.modeChanged()
                    } else if message.hwnd == watcher.window {
                        watcher.handle(message)
                    } else {
                        TranslateMessage(&message)
                        DispatchMessageW(&message)
                    }
                }
            } catch let error as WindowsError {
                state.values.withLock { $0.error = error }
            } catch {
                state.values.withLock { $0.error = .unsupported("System indicator observer failed.") }
            }
        }
        guard WaitForSingleObject(state.ready.raw, 5000) == DWORD(WAIT_OBJECT_0) else {
            stop()
            throw WindowsError.unsupported("System indicator observer did not start.")
        }
        if let error = state.values.withLock({ $0.error }) {
            stop()
            throw error
        }
    }

    func setCustom(_ custom: Bool) {
        state.values.withLock {
            $0.custom = custom
            if $0.threadID != 0 { PostThreadMessageW($0.threadID, indicatorModeMessage, 0, 0) }
        }
    }

    func stop() {
        state.values.withLock {
            $0.stopped = true
            if $0.threadID != 0 {
                // The worker clears its ID under this lock before exiting.
                PostThreadMessageW($0.threadID, UINT(WM_QUIT), 0, 0)
                $0.threadID = 0
            }
        }
        WaitForSingleObject(state.finished.raw, 2000)
    }

    deinit { stop() }
}

/// All state and callbacks below belong exclusively to the observer thread.
private final class IndicatorWatcher {
    let window: HWND
    private let state: IndicatorState
    private let shellMessage = withWideString("SHELLHOOK") { RegisterWindowMessageW($0) }
    private let taskbarCreated = withWideString("TaskbarCreated") { RegisterWindowMessageW($0) }
    private var hook: HWINEVENTHOOK?
    private var focusHook: HWINEVENTHOOK?
    private var brightnessSources: [Int: UInt8] = [:]
    private var shellPID: DWORD = 0
    private var mediaTimestamp: DWORD?
    private var mediaShown = false
    private let owner = GetCurrentProcessId()
    private let started: UInt64

    init(state: IndicatorState) throws {
        self.state = state
        started = try processStartTicks(GetCurrentProcess())
        // Establish crash recovery before changing another process's window.
        try startWatchdog()
        let handle = withWideString("STATIC") { className in
            withWideString("SwiftyToys.Indicator") {
                CreateWindowExW(
                    DWORD(WS_EX_TOOLWINDOW), className, $0, 0, 0, 0, 1, 1,
                    nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let handle else { throw WindowsError.api("Create indicator observer", GetLastError()) }
        window = handle
        guard RegisterShellHookWindow(window) else {
            DestroyWindow(window)
            throw WindowsError.unsupported("Could not register the Shell indicator observer.")
        }
        if state.hardwareKeys {
            var raw = RAWINPUTDEVICE(usUsagePage: 0x0C, usUsage: 1,
                dwFlags: DWORD(RIDEV_INPUTSINK | RIDEV_DEVNOTIFY), hwndTarget: window)
            if !RegisterRawInputDevices(&raw, 1, UINT(MemoryLayout<RAWINPUTDEVICE>.size)) {
                let error = GetLastError()
                DeregisterShellHookWindow(window)
                DestroyWindow(window)
                throw WindowsError.api("Register brightness HID", error)
            }
        }
        activeIndicator = .passUnretained(self)
        focusHook = SetWinEventHook(
            DWORD(EVENT_SYSTEM_FOREGROUND), DWORD(EVENT_SYSTEM_FOREGROUND), nil, indicatorForegroundChanged,
            0, 0, DWORD(WINEVENT_OUTOFCONTEXT))
        refreshShell()
        SetTimer(window, 1, 3000, nil)
    }

    func handle(_ message: MSG) {
        if message.message == UINT(WM_INPUT) {
            let actions = brightnessActions(HRAWINPUT(bitPattern: Int(message.lParam)))
            if actions.media {
                mediaTimestamp = message.time
                mediaShown = false
                NativeFlyout.restore(owner: owner, started: started)
            }
            for keys in actions.states {
                let previous = brightnessSources[actions.source] ?? 0
                guard keys != previous else { continue }
                if keys == 0 { brightnessSources.removeValue(forKey: actions.source) }
                else {
                    guard brightnessSources[actions.source] != nil || brightnessSources.count < 64 else { continue }
                    brightnessSources[actions.source] = keys
                }
                _ = state.destination.post(brightnessKeyStateMessage, value: Int(keys), data: actions.source)
                guard keys != 0 else { continue }
                if state.values.withLock({ $0.custom }) {
                    mediaTimestamp = nil
                    prepareFlyout()
                }
            }
            _ = DefWindowProcW(window, message.message, message.wParam, message.lParam)
        } else if message.message == UINT(WM_INPUT_DEVICE_CHANGE), message.wParam == WPARAM(GIDC_REMOVAL) {
            let source = Int(message.lParam)
            brightnessSources.removeValue(forKey: source)
            _ = state.destination.post(brightnessKeyStateMessage, data: source)
        } else if message.message == shellMessage {
            if message.wParam == 55 && state.values.withLock({ $0.custom }) {
                mediaTimestamp = nil
                hideKnownFlyout()
            } else if message.wParam == 12 || message.wParam == 56 {
                mediaTimestamp = message.time
                mediaShown = false
                NativeFlyout.restore(owner: owner, started: started)
            } else if !state.values.withLock({ $0.custom }) {
                modeChanged()
            }
        } else if message.message == taskbarCreated || message.message == UINT(WM_TIMER) {
            refreshShell()
        } else {
            var message = message
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }

    func modeChanged() {
        mediaTimestamp = nil
        mediaShown = false
        if state.values.withLock({ $0.custom }) {
            prepareFlyout()
        } else {
            NativeFlyout.restore(owner: owner, started: started)
        }
    }

    func cancelBrightnessKeys() {
        _ = state.destination.post(brightnessKeyCancelMessage)
    }

    private func prepareFlyout() {
        guard state.values.withLock({ $0.custom }), mediaTimestamp == nil else { return }
        for window in NativeFlyout.windows() { NativeFlyout.clip(window, owner: owner, started: started) }
    }

    /// Rebinds after Explorer restarts without injecting code into its process.
    private func refreshShell() {
        var pid: DWORD = 0
        if let shell = GetShellWindow() { GetWindowThreadProcessId(shell, &pid) }
        guard pid != shellPID || (pid != 0 && hook == nil) else {
            prepareFlyout()
            return
        }
        if let hook { UnhookWinEvent(hook) }
        hook = nil
        shellPID = pid
        mediaTimestamp = nil
        if pid != 0 {
            hook = SetWinEventHook(
                DWORD(EVENT_OBJECT_CREATE), DWORD(EVENT_OBJECT_HIDE), nil, indicatorShown, pid, 0,
                DWORD(WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS))
        }
        prepareFlyout()
    }

    func event(_ event: DWORD, window: HWND, timestamp: DWORD) {
        guard state.values.withLock({ $0.custom }), NativeFlyout.isKnown(window) else { return }
        if event == DWORD(EVENT_OBJECT_SHOW), mediaTimestamp != nil, IsWindowVisible(window) {
            mediaShown = true
        } else if event == DWORD(EVENT_OBJECT_HIDE), mediaShown, !IsWindowVisible(window), let mediaTimestamp,
            timestamp &- mediaTimestamp > 0, timestamp &- mediaTimestamp < DWORD.max / 2
        {
            self.mediaTimestamp = nil
            mediaShown = false
            prepareFlyout()
        } else if mediaTimestamp == nil {
            NativeFlyout.clip(window, owner: owner, started: started)
            if event == DWORD(EVENT_OBJECT_SHOW) { hide(window) }
        }
    }

    private func hideKnownFlyout() {
        prepareFlyout()
        for window in NativeFlyout.windows() { hide(window) }
    }

    private func hide(_ window: HWND) {
        guard NativeFlyout.isKnown(window), IsWindowVisible(window) else { return }
        // Apply on the independent observer, without another async queue delay.
        ShowWindow(window, Int32(SW_HIDE))
    }

    func stop() {
        for source in brightnessSources.keys {
            _ = state.destination.post(brightnessKeyStateMessage, data: source)
        }
        brightnessSources.removeAll()
        activeIndicator = nil
        if let focusHook { UnhookWinEvent(focusHook) }
        if let hook { UnhookWinEvent(hook) }
        NativeFlyout.restore(owner: owner, started: started)
        KillTimer(window, 1)
        DeregisterShellHookWindow(window)
        DestroyWindow(window)
    }
}
private func brightnessActions(_ handle: HRAWINPUT?) -> (states: [UInt8], source: Int, media: Bool) {
    var states: [UInt8] = []
    var media = false
    guard let handle else { return ([], 0, false) }
    var size: UINT = 0
    let headerSize = UINT(MemoryLayout<RAWINPUTHEADER>.size)
    guard GetRawInputData(handle, UINT(RID_INPUT), nil, &size, headerSize) == 0, size > headerSize + 8,
        size <= 65536
    else { return ([], 0, false) }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<RAWINPUT>.alignment)
    defer { buffer.deallocate() }
    guard GetRawInputData(handle, UINT(RID_INPUT), buffer, &size, headerSize) == size else { return ([], 0, false) }
    let header = buffer.load(as: RAWINPUTHEADER.self)
    guard header.dwType == DWORD(RIM_TYPEHID), let device = header.hDevice else { return ([], 0, false) }
    let reportSize = Int(buffer.advanced(by: Int(headerSize)).load(as: DWORD.self))
    let count = Int(buffer.advanced(by: Int(headerSize) + 4).load(as: DWORD.self))
    guard reportSize > 0, count > 0, count <= 1024, reportSize <= (Int(size) - Int(headerSize) - 8) / count else {
        return ([], 0, false)
    }
    var preparsedSize: UINT = 0
    guard GetRawInputDeviceInfoW(header.hDevice, UINT(RIDI_PREPARSEDDATA), nil, &preparsedSize) != UINT.max,
        preparsedSize > 0, preparsedSize <= 65536
    else { return ([], 0, false) }
    let preparsed = UnsafeMutableRawPointer.allocate(byteCount: Int(preparsedSize), alignment: 8)
    defer { preparsed.deallocate() }
    guard GetRawInputDeviceInfoW(header.hDevice, UINT(RIDI_PREPARSEDDATA), preparsed, &preparsedSize) != UINT.max
    else { return ([], 0, false) }
    for index in 0..<count {
        var usages = Array(repeating: USAGE(0), count: 64)
        var usageCount = ULONG(usages.count)
        let status = HidP_GetUsages(
            HidP_Input, 0x0C, 0, &usages, &usageCount, OpaquePointer(preparsed),
            buffer.advanced(by: Int(headerSize) + 8 + index * reportSize).assumingMemoryBound(to: CChar.self),
            ULONG(reportSize))
        if status >= 0 {
            var keys: UInt8 = 0
            for usage in usages.prefix(min(Int(usageCount), usages.count)) {
                if usage == 0x6F {
                    keys |= 2
                } else if usage == 0x70 {
                    keys |= 1
                } else if [0xE2, 0xE9, 0xEA, 0xB0, 0xB1, 0xB5, 0xB6, 0xB7, 0xCD].contains(usage) {
                    media = true
                }
            }
            states.append(keys) // An empty usage list is the key-release report.
        }
    }
    return (states, Int(bitPattern: device), media)
}
