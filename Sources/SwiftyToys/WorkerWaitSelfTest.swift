// SPDX-License-Identifier: MIT
import KeyboardCore
import Synchronization
import WinSDK

private let sentProbe: UINT = 0x8044
private let queuedProbe: UINT = 0x8045
private func replyProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    if message == sentProbe { return 109 }
    if message == queuedProbe { SetWindowLongPtrW(window, Int32(GWLP_USERDATA), 99); return 0 }
    return DefWindowProcW(window, message, value, data)
}
/// A real cross-thread sent-message handshake must finish while queued UI changes stay queued.
func testWorkerWait() throws {
    var type = WNDCLASSEXW()
    type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    type.lpfnWndProc = replyProcedure
    type.hInstance = GetModuleHandleW(nil)
    let name = "SwiftyToys.WorkerWaitTest"
    let atom = withWideString(name) { type.lpszClassName = $0; return RegisterClassExW(&type) }
    guard atom != 0 else { throw WindowsError.api("Register worker-wait test", GetLastError()) }
    defer { _ = withWideString(name) { UnregisterClassW($0, type.hInstance) } }
    guard let window = withWideString(name, { CreateWindowExW(0, $0, nil, 0, 0, 0, 1, 1, nil, nil, type.hInstance, nil) }) else {
        throw WindowsError.api("Create worker-wait test", GetLastError())
    }
    defer { DestroyWindow(window) }
    let destination = MessageDestination(window)
    let blocked = try OwnedHandle(CreateEventW(nil, true, false, nil))
    let blockedAddress = UInt(bitPattern: blocked.raw)
    let blockedReply = Mutex(false)
    _ = try NativeThread(name: "SwiftyToys old-wait control") {
        var result: DWORD_PTR = 0
        let sent = SendMessageTimeoutW(destination.window, sentProbe, 0, 0, UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 100, &result)
        blockedReply.withLock { $0 = sent != 0 }
        SetEvent(HANDLE(bitPattern: blockedAddress))
    }
    guard WaitForSingleObject(blocked.raw, 1000) == DWORD(WAIT_OBJECT_0), !blockedReply.withLock({ $0 }) else {
        throw WindowsError.unsupported("Blocking-wait control did not reproduce the missing sent reply.")
    }
    for _ in 0..<12 {
        let finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
        let address = UInt(bitPattern: finished.raw)
        let reply = Mutex(false)
        _ = try NativeThread(name: "SwiftyToys wait regression") {
            let posted = destination.post(queuedProbe)
            var result: DWORD_PTR = 0
            let sent = SendMessageTimeoutW(destination.window, sentProbe, 0, 0, UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 1000, &result)
            reply.withLock { $0 = posted && sent != 0 && result == 109 }
            SetEvent(HANDLE(bitPattern: address))
        }
        guard waitForWindowEvent(finished.raw, timeout: 2000) == DWORD(WAIT_OBJECT_0), reply.withLock({ $0 }),
            GetWindowLongPtrW(window, Int32(GWLP_USERDATA)) == 0 else {
            throw WindowsError.unsupported("Worker join blocked a sent reply or dispatched a queued UI change.")
        }
        var queued = MSG()
        guard PeekMessageW(&queued, window, queuedProbe, queuedProbe, UINT(PM_REMOVE)) else {
            throw WindowsError.unsupported("Worker wait consumed the queued UI command.")
        }
    }
    let never = try OwnedHandle(CreateEventW(nil, true, false, nil))
    guard waitForWindowEvent(never.raw, timeout: 20) == DWORD(WAIT_TIMEOUT) else {
        throw WindowsError.unsupported("Worker wait ignored its deadline.")
    }
    var configuration = try KeyboardConfiguration()
    configuration.enabled = false
    configuration.reverseVertical = false
    configuration.reverseHorizontal = false
    var previousGeneration = 0
    for index in 0..<12 {
        let input = try KeyboardRemapper(destination: destination, configuration: configuration)
        guard input.generation != previousGeneration else { throw WindowsError.unsupported("Input worker generation was reused.") }
        previousGeneration = input.generation
        if index == 0 {
            var rejected = false
            do { let duplicate = try KeyboardRemapper(destination: destination, configuration: configuration); duplicate.stop() }
            catch { rejected = String(describing: error).containsText("previous input worker") }
            guard rejected else { throw WindowsError.unsupported("Overlapping input workers were allowed.") }
        }
        guard input.stop(), input.stop() else { throw WindowsError.unsupported("Input worker did not stop cleanly.") }
    }
    Console.writeLine("PASS: sent replies during worker join, queued UI changes preserved, bounded wait and repeated real input-worker shutdown")
}
