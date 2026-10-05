// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK

/// Interactive input regression test. No display controller is constructed.
func testKeyboardInput() throws {
    let window = withWideString("STATIC") {
        CreateWindowExW(0, $0, nil, 0, 0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil)
    }
    guard let window else { throw WindowsError.api("Create input-test window", GetLastError()) }
    defer { DestroyWindow(window) }
    let input = try KeyboardInput(destination: MessageDestination(window), enabled: true, allowInjected: true)
    defer { input.stop() }
    func tap() throws {
        var events = [INPUT(), INPUT()]
        events[0].type = DWORD(INPUT_KEYBOARD)
        events[0].ki.wVk = 113
        events[1].type = DWORD(INPUT_KEYBOARD)
        events[1].ki.wVk = 113
        events[1].ki.dwFlags = DWORD(KEYEVENTF_KEYUP)
        guard SendInput(2, &events, Int32(MemoryLayout<INPUT>.size)) == 2 else {
            throw WindowsError.api("SendInput", GetLastError())
        }
    }
    func drain() -> Int {
        var message = MSG()
        var count = 0
        while PeekMessageW(&message, window, keyStepMessage, keyStepMessage, UINT(PM_REMOVE)) {
            if message.wParam == 1 { count += 1 }
        }
        return count
    }
    try tap()
    Sleep(100)
    guard drain() == 1 else { throw WindowsError.unsupported("Input test: initial F2 was not captured.") }
    let completion = try OwnedHandle(CreateEventW(nil, true, false, nil))
    let completionAddress = UInt(bitPattern: completion.raw)
    let sendResult = Mutex(false)
    _ = try NativeThread(name: "SwiftyToys input test") {
        Sleep(300)
        var events = [INPUT(), INPUT()]
        events[0].type = DWORD(INPUT_KEYBOARD)
        events[0].ki.wVk = 113
        events[1].type = DWORD(INPUT_KEYBOARD)
        events[1].ki.wVk = 113
        events[1].ki.dwFlags = DWORD(KEYEVENTF_KEYUP)
        sendResult.withLock { $0 = SendInput(2, &events, Int32(MemoryLayout<INPUT>.size)) == 2 }
        SetEvent(HANDLE(bitPattern: completionAddress))
    }
    // A hook installed on this UI thread would time out while it is blocked.
    Sleep(2400)
    guard WaitForSingleObject(completion.raw, 5000) == DWORD(WAIT_OBJECT_0), sendResult.withLock({ $0 }), drain() == 1
    else {
        throw WindowsError.unsupported("Input test: F2 failed during a blocked UI thread.")
    }
    try tap()
    Sleep(100)
    guard drain() == 1, input.active else {
        throw WindowsError.unsupported("Input test: hook did not survive the blocked UI.")
    }
    Console.writeLine("PASS: F2 before, during and after a 2.4-second UI stall; display brightness unchanged")
}
