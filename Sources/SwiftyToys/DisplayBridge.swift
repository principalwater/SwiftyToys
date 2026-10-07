// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK

/// Kernel events are thread-safe; ownership lasts through any delayed completion.
private final class ReplyEvent: @unchecked Sendable {
    let handle: OwnedHandle
    let reply = Mutex<Result<DisplayState, WindowsError>?>(nil)
    init() throws { handle = try OwnedHandle(CreateEventW(nil, true, false, nil)) }
}
/// Win32's message loop owns UI state. It does not run Swift's MainActor queue.
func displayCommand(_ controller: DisplayController, command: Int, value: Int = 0, mode: String? = nil) throws -> DisplayState {
    let event = try ReplyEvent()
    Task {
        let result: Result<DisplayState, WindowsError>
        do { result = .success(try await performDisplayCommand(controller, command: command, value: value, mode: mode)) } catch let error as WindowsError {
            result = .failure(error)
        } catch { result = .failure(.unsupported(String(describing: error))) }
        event.reply.withLock { $0 = result }
        SetEvent(event.handle.raw)
    }
    guard WaitForSingleObject(event.handle.raw, 15000) == DWORD(WAIT_OBJECT_0),
        let reply = event.reply.withLock({ $0 })
    else { throw WindowsError.unsupported("Display driver did not finish within 15 seconds.") }
    return try reply.get()
}

/// One serialized request; the Win32 UI receives completion through a message.
struct DisplayRequest: Sendable {
    let command: Int
    let value: Int
    let show: Bool
    let mode: String?
    init(_ command: Int, value: Int = 0, show: Bool = false, mode: String? = nil) {
        self.command = command; self.value = value; self.show = show; self.mode = mode
    }
}
/// UI-owned, bounded queue. Polls never accumulate behind driver work.
struct DisplayRequestQueue {
    private(set) var active: DisplayRequest?
    private var brightness: DisplayRequest?
    private var mode: String?
    private var refresh: Int?
    var level: Int
    init(level: Int) { self.level = level }
    var hasBrightness: Bool { brightness != nil }
    mutating func enqueue(_ request: DisplayRequest) -> Bool {
        if request.command == 1 { level = request.value }
        guard active != nil else { active = request; return true }
        if let requested = request.mode { mode = requested }
        else if request.command == 3 || request.command == 5 { if refresh != 3 { refresh = request.command } }
        else if request.command != 4 { brightness = request }
        return false
    }
    mutating func finish(level applied: Int) -> DisplayRequest? {
        active = nil
        if let requested = mode { mode = nil; return DisplayRequest(3, mode: requested) }
        if let requested = refresh { refresh = nil; return DisplayRequest(requested) }
        if let requested = brightness { brightness = nil; return requested }
        level = applied
        return nil
    }
    static func selfCheck() throws {
        var queue = DisplayRequestQueue(level: 50)
        guard queue.enqueue(DisplayRequest(4)), !queue.enqueue(DisplayRequest(1, value: 60)),
            !queue.enqueue(DisplayRequest(1, value: 70)), !queue.enqueue(DisplayRequest(3, mode: "hardware")),
            !queue.enqueue(DisplayRequest(5)), !queue.enqueue(DisplayRequest(4)), queue.level == 70,
            let mode = queue.finish(level: 50), mode.mode == "hardware", queue.enqueue(mode),
            let refresh = queue.finish(level: 50), refresh.command == 5, queue.enqueue(refresh),
            let latest = queue.finish(level: 50), latest.value == 70, queue.enqueue(latest),
            queue.finish(level: 70) == nil, queue.active == nil, queue.level == 70
        else { throw WindowsError.unsupported("Display request ordering/coalescing check failed.") }
        Console.writeLine("PASS: one request, latest brightness retained, mode/refresh ordered, idle polls dropped")
    }
}
final class DisplayMailbox: Sendable {
    let result = Mutex<Result<DisplayState, WindowsError>?>(nil)
}

func performDisplayCommand(_ controller: DisplayController, command: Int, value: Int, mode: String?) async throws -> DisplayState {
    guard let mode else { return try await controller.command(command, value: value) }
    let previous = try Settings()
    try previous.setBackend(mode)
    do {
        let state = try await controller.command(3)
        guard mode != "hardware" || state.connected else { throw WindowsError.unsupported("Connect one supported physical SDR display before enabling DDC/CI.") }
        return state
    } catch {
        let explanation = String(describing: error)
        if !(previous.ddcEnabled && mode != "hardware") {
            try Settings().setBackend(previous.backend)
            let restored: DisplayState
            do { restored = try await controller.command(3) }
            catch {
                throw WindowsError.unsupported(explanation + "\n\nThe previous brightness preference was saved, but display recovery did not finish. Use Reconnect display.\n" + String(describing: error))
            }
            throw WindowsError.unsupported(explanation + (restored.connected ? "\n\nThe previous brightness method was restored." : "\n\nThe previous brightness preference was saved. Reconnect the display to finish recovery."))
        }
        // A failed restore keeps its lease and the explicit OFF preference.
        let pendingHardware = (try? ColorLease.read())?.backend == "hardware"
        throw WindowsError.unsupported(explanation + (pendingHardware ? "\n\nDDC/CI is off. Backlight recovery is pending; reconnect the monitor and use Reconnect display. Its recovery file is preserved." : "\n\nDDC/CI remains off. The software brightness method is unavailable; select Automatic or reconnect the display."))
    }
}
func stopDisplay(_ controller: DisplayController) {
    guard let event = try? ReplyEvent() else { return }
    Task {
        await controller.shutdown()
        SetEvent(event.handle.raw)
    }
    _ = WaitForSingleObject(event.handle.raw, 15000)
    // The actor's deinit stops the executor after all outstanding jobs finish.
}
