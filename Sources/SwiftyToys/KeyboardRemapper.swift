// SPDX-License-Identifier: MIT
import KeyboardCore
import Synchronization
import WinSDK
import WindowsDisplayABI

let toyActionMessage: UINT = 0x8020
private let injectionTag: ULONG_PTR = 0x5357_5459
private struct RemappingState {
    var engine: RemapEngine
    var caps: SmartCapsLock
    var layouts: [HKL]
    let configuration: KeyboardConfiguration
    let destination: MessageDestination
    var hook: HHOOK?
    var failed = false
    var lastPID: DWORD = 0
    var application = ""
    let brightnessKeys: Bool
    let allowInjectedBrightness: Bool
    var brightnessSwallowed: UInt8 = 0
    var mouseHook: HHOOK?
    var mouseFailed = false
    var capsTimer: UINT_PTR = 0
    var lastForeground: HWND?
}
nonisolated(unsafe) private var remappingState: UnsafeMutablePointer<RemappingState>?

@discardableResult private func emitTransitions(_ transitions: [KeyTransition]) -> Bool {
    guard !transitions.isEmpty else { return true }
    var inputs = transitions.map { event -> INPUT in
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki.wVk = WORD(event.key)
        input.ki.dwExtraInfo = injectionTag
        input.ki.dwFlags = event.isDown ? 0 : DWORD(KEYEVENTF_KEYUP)
        if [33, 34, 35, 36, 37, 38, 39, 40, 45, 46, 91, 92, 163, 165].contains(event.key) {
            input.ki.dwFlags |= DWORD(KEYEVENTF_EXTENDEDKEY)
        }
        return input
    }
    return SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.size)) == inputs.count
}
private func cacheForegroundApplication() {
    guard let context = remappingState else { return }
    let window = GetForegroundWindow()
    if window != context.pointee.lastForeground {
        context.pointee.caps.cancel()
        context.pointee.lastForeground = window
    }
    var pid: DWORD = 0
    GetWindowThreadProcessId(window, &pid)
    guard pid != context.pointee.lastPID else { return }
    context.pointee.lastPID = pid
    context.pointee.application = ""
    if let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) {
        defer { CloseHandle(process) }
        var buffer = Array(repeating: WCHAR(0), count: 1024)
        var count = DWORD(buffer.count)
        if QueryFullProcessImageNameW(process, 0, &buffer, &count) {
            context.pointee.application =
                String(decoding: buffer.prefix(Int(count)), as: UTF16.self).split(separator: "\\").last.map {
                    String($0).lowercased()
                } ?? ""
        }
    }
}
private func foregroundChanged(
    _ hook: HWINEVENTHOOK?, _ event: DWORD, _ window: HWND?, _ object: LONG, _ child: LONG, _ thread: DWORD,
    _ time: DWORD
) { cacheForegroundApplication() }
private func deliverAction(_ action: String, context: UnsafeMutablePointer<RemappingState>) -> Bool {
    let foreground = GetForegroundWindow()
    if action == "switch language" {
        do {
            try requestLanguage(
                in: foreground, layouts: context.pointee.layouts, mode: context.pointee.configuration.languageMode,
                pair: context.pointee.configuration.languagePair)
            return true
        } catch { return false }
    }
    return context.pointee.destination.post(
        toyActionMessage, value: 2, data: foreground.map { Int(bitPattern: $0) } ?? 0)
}
private func deliverCaps(_ decision: CapsDecision, context: UnsafeMutablePointer<RemappingState>) -> Bool {
    if decision.toggleCaps { return emitTransitions([KeyTransition(20, down: true), KeyTransition(20, down: false)]) }
    if decision.tap {
        let down = context.pointee.engine.process(key: 20, down: true, application: context.pointee.application)
        let up = context.pointee.engine.process(key: 20, down: false, application: context.pointee.application)
        guard emitTransitions(down.events + up.events) else { return false }
        if let action = down.action { return deliverAction(action, context: context) }
    }
    return true
}
private func syncCapsTimer(_ context: UnsafeMutablePointer<RemappingState>) {
    if context.pointee.caps.pendingHold, context.pointee.capsTimer == 0 {
        context.pointee.capsTimer = SetTimer(nil, 0, UINT(context.pointee.configuration.capsThreshold), nil)
    } else if !context.pointee.caps.pendingHold, context.pointee.capsTimer != 0 {
        KillTimer(nil, context.pointee.capsTimer)
        context.pointee.capsTimer = 0
    }
}
private func scrollingCallback(_ code: Int32, _ message: WPARAM, _ data: LPARAM) -> LRESULT {
    guard code >= 0, let context = remappingState, !context.pointee.mouseFailed,
        let event = UnsafePointer<MSLLHOOKSTRUCT>(bitPattern: Int(data))?.pointee,
        event.dwExtraInfo != injectionTag, event.flags & DWORD(LLMHF_INJECTED) == 0,
        (message == WPARAM(WM_MOUSEWHEEL) && context.pointee.configuration.reverseVertical)
            || (message == WPARAM(WM_MOUSEHWHEEL) && context.pointee.configuration.reverseHorizontal),
        !context.pointee.configuration.excluded.contains(context.pointee.application),
        ![17, 18, 16, 91, 92].contains(where: { GetAsyncKeyState(Int32($0)) < 0 })
    else { return CallNextHookEx(nil, code, message, data) }
    var pid: DWORD = 0
    GetWindowThreadProcessId(GetForegroundWindow(), &pid)
    guard pid == context.pointee.lastPID else { return CallNextHookEx(nil, code, message, data) }
    var inputs = reversedWheelDeltas(UInt16(truncatingIfNeeded: event.mouseData >> 16)).map { delta -> INPUT in
        var input = INPUT()
        input.type = DWORD(INPUT_MOUSE)
        input.mi.dwExtraInfo = injectionTag
        input.mi.dwFlags = message == WPARAM(WM_MOUSEWHEEL) ? DWORD(MOUSEEVENTF_WHEEL) : DWORD(MOUSEEVENTF_HWHEEL)
        input.mi.mouseData = DWORD(bitPattern: delta)
        return input
    }
    if SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.size)) == inputs.count { return 1 }
    context.pointee.mouseFailed = true
    _ = context.pointee.destination.post(toyActionMessage, value: 5)
    return CallNextHookEx(nil, code, message, data)
}
private func remappingCallback(_ code: Int32, _ message: WPARAM, _ data: LPARAM) -> LRESULT {
    guard code >= 0, let context = remappingState,
        let event = UnsafePointer<KBDLLHOOKSTRUCT>(bitPattern: Int(data))?.pointee,
        event.dwExtraInfo != injectionTag,
        !context.pointee.failed
    else { return CallNextHookEx(nil, code, message, data) }
    let down = message == WPARAM(WM_KEYDOWN) || message == WPARAM(WM_SYSKEYDOWN)
    guard down || message == WPARAM(WM_KEYUP) || message == WPARAM(WM_SYSKEYUP) else {
        return CallNextHookEx(nil, code, message, data)
    }
    if context.pointee.brightnessKeys, event.vkCode == 112 || event.vkCode == 113,
        context.pointee.allowInjectedBrightness || event.flags & DWORD(LLKHF_INJECTED) == 0
    {
        let bit: UInt8 = event.vkCode == 112 ? 1 : 2
        let held = context.pointee.brightnessSwallowed & bit != 0
        if !down, held {
            context.pointee.brightnessSwallowed &= ~bit
            return 1
        }
        if down, held || context.pointee.engine.physicalModifiers == 0 {
            if context.pointee.destination.post(keyStepMessage, value: event.vkCode == 113 ? 1 : -1) || held {
                context.pointee.brightnessSwallowed |= bit
                return 1
            }
        }
    }
    guard event.flags & DWORD(LLKHF_INJECTED) == 0 else { return CallNextHookEx(nil, code, message, data) }
    // Foreground executable is cached by a WinEvent callback outside this keyboard callback.
    var pid: DWORD = 0
    GetWindowThreadProcessId(GetForegroundWindow(), &pid)
    let enabled =
        context.pointee.configuration.enabled && pid == context.pointee.lastPID
        && !context.pointee.configuration.excluded.contains(context.pointee.application)
    let language =
        GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), nil)).map {
            UInt16(truncatingIfNeeded: UInt(bitPattern: $0)) & 0x03FF
        } ?? 0
    let capsEnabled = enabled && context.pointee.configuration.smartCaps && ![UInt16(4), 17, 18].contains(language)
    let caps = context.pointee.caps.process(
        key: UInt16(event.vkCode), down: down, time: GetTickCount64(),
        modifiers: context.pointee.engine.physicalModifiers, capsOn: GetKeyState(20) & 1 != 0, enabled: capsEnabled)
    syncCapsTimer(context)
    if !deliverCaps(caps, context: context) {
        context.pointee.failed = true
        _ = context.pointee.destination.post(toyActionMessage, value: 3)
        return CallNextHookEx(nil, code, message, data)
    }
    if caps.suppress { return 1 }
    if context.pointee.configuration.smartCaps, event.vkCode == 20 { return CallNextHookEx(nil, code, message, data) }
    let result = context.pointee.engine.process(
        key: UInt16(event.vkCode), down: down, application: context.pointee.application, enabled: enabled)
    if !emitTransitions(result.events) {
        _ = emitTransitions(context.pointee.engine.release())
        context.pointee.failed = true
        _ = context.pointee.destination.post(toyActionMessage, value: 3)
        return CallNextHookEx(nil, code, message, data)
    }
    if let action = result.action {
        if !deliverAction(action, context: context) {
            return CallNextHookEx(nil, code, message, data)
        }
    }
    return result.suppress ? 1 : CallNextHookEx(nil, code, message, data)
}

/// The dedicated hook thread owns the engine and all injection. UI updates restart this small worker.
final class KeyboardRemapper: @unchecked Sendable {
    private struct Status {
        var threadID: DWORD = 0
        var active = false
        var mouseActive = false
        var stopped = false
        var error: DWORD = 0
    }
    private let status = Mutex(Status())
    private let ready: OwnedHandle
    private let finished: OwnedHandle
    private let destination: MessageDestination
    private let configuration: KeyboardConfiguration
    private let brightnessKeys: Bool
    private let allowInjectedBrightness: Bool
    private var thread: NativeThread?
    var active: Bool { status.withLock { $0.active } }
    init(
        destination: MessageDestination, configuration: KeyboardConfiguration, brightnessKeys: Bool = false,
        allowInjectedBrightness: Bool = false
    ) throws {
        self.destination = destination
        self.configuration = configuration
        self.brightnessKeys = brightnessKeys
        self.allowInjectedBrightness = allowInjectedBrightness
        ready = try OwnedHandle(CreateEventW(nil, true, false, nil))
        finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
        thread = try NativeThread(name: "SwiftyToys remapping") { [weak self] in self?.run() }
        guard WaitForSingleObject(ready.raw, 5000) == DWORD(WAIT_OBJECT_0),
            active || !(configuration.enabled || brightnessKeys)
        else {
            stop()
            throw WindowsError.unsupported("Keyboard remapping could not start.")
        }
        if configuration.reverseVertical || configuration.reverseHorizontal, !status.withLock({ $0.mouseActive }) {
            stop()
            throw WindowsError.unsupported("Natural scrolling could not start.")
        }
    }
    private func run() {
        var message = MSG()
        PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE))
        defer {
            status.withLock {
                $0.threadID = 0
                $0.active = false
            }
            SetEvent(finished.raw)
        }
        guard
            status.withLock({ state in
                guard !state.stopped else { return false }
                state.threadID = GetCurrentThreadId()
                return true
            })
        else {
            SetEvent(ready.raw)
            return
        }
        var rules = configuration.rules
        if configuration.smartCaps, let rule = try? RemapRule(from: "CapsLock", to: configuration.capsAction) {
            rules.append(rule)
        }
        var context = RemappingState(
            engine: RemapEngine(rules: rules), caps: SmartCapsLock(threshold: configuration.capsThreshold),
            layouts: configuredLayouts(), configuration: configuration, destination: destination,
            brightnessKeys: brightnessKeys, allowInjectedBrightness: allowInjectedBrightness)
        context.engine.seedHeldModifiers(
            [160, 161, 162, 163, 164, 165, 91, 92].filter { GetAsyncKeyState(Int32($0)) < 0 })
        withUnsafeMutablePointer(to: &context) { pointer in
            remappingState = pointer
            cacheForegroundApplication()
            let focusHook = SetWinEventHook(
                DWORD(EVENT_SYSTEM_FOREGROUND), DWORD(EVENT_SYSTEM_FOREGROUND), nil, foregroundChanged, 0, 0,
                DWORD(WINEVENT_OUTOFCONTEXT))
            defer {
                if let focusHook { UnhookWinEvent(focusHook) }
                _ = emitTransitions(pointer.pointee.engine.release())
                if let hook = pointer.pointee.hook { UnhookWindowsHookEx(hook) }
                if let hook = pointer.pointee.mouseHook { UnhookWindowsHookEx(hook) }
                remappingState = nil
            }
            func rearm() {
                if configuration.reverseVertical || configuration.reverseHorizontal, !pointer.pointee.mouseFailed,
                    let replacement = SetWindowsHookExW(Int32(WH_MOUSE_LL), scrollingCallback, GetModuleHandleW(nil), 0)
                {
                    let old = pointer.pointee.mouseHook
                    pointer.pointee.mouseHook = replacement
                    if let old { UnhookWindowsHookEx(old) }
                    status.withLock { $0.mouseActive = true }
                }
                guard configuration.enabled || brightnessKeys, !pointer.pointee.failed, status.withLock({ !$0.stopped })
                else { return }
                if let replacement = SetWindowsHookExW(
                    Int32(WH_KEYBOARD_LL), remappingCallback, GetModuleHandleW(nil), 0)
                {
                    let old = pointer.pointee.hook
                    pointer.pointee.hook = replacement
                    if let old { UnhookWindowsHookEx(old) }
                    status.withLock { $0.active = true }
                } else {
                    status.withLock { $0.error = GetLastError() }
                }
            }
            rearm()
            let timer = SetTimer(nil, 0, 60000, nil)
            defer {
                if timer != 0 { KillTimer(nil, timer) }
                if pointer.pointee.capsTimer != 0 { KillTimer(nil, pointer.pointee.capsTimer) }
            }
            SetEvent(ready.raw)
            while BC_GetMessageW(&message, nil, 0, 0) > 0 {
                if message.message == UINT(WM_TIMER) {
                    if message.wParam == pointer.pointee.capsTimer {
                        var pid: DWORD = 0
                        GetWindowThreadProcessId(GetForegroundWindow(), &pid)
                        let enabled =
                            configuration.enabled && pid == pointer.pointee.lastPID
                            && !configuration.excluded.contains(pointer.pointee.application)
                        if !deliverCaps(
                            pointer.pointee.caps.tick(time: GetTickCount64(), enabled: enabled), context: pointer)
                        {
                            pointer.pointee.failed = true
                            _ = destination.post(toyActionMessage, value: 3)
                        }
                        syncCapsTimer(pointer)
                        if pointer.pointee.capsTimer != 0 {
                            pointer.pointee.capsTimer = SetTimer(nil, pointer.pointee.capsTimer, 15, nil)
                        }
                    } else {
                        cacheForegroundApplication()
                        pointer.pointee.layouts = configuredLayouts()
                        rearm()
                    }
                } else {
                    TranslateMessage(&message)
                    DispatchMessageW(&message)
                }
            }
        }
    }
    func stop() {
        let posted = status.withLock { state in
            state.stopped = true
            guard state.threadID != 0 else { return false }
            PostThreadMessageW(state.threadID, UINT(WM_QUIT), 0, 0)
            return true
        }
        if posted { WaitForSingleObject(finished.raw, INFINITE) }
    }
    deinit { stop() }
}
