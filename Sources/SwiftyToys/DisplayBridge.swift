// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK

/// Admission survives a caller's timeout until the actual operation completes.
final class DisplayCommandAdmission: Sendable {
    private let busy = Mutex(false)
    var isBusy: Bool { busy.withLock { $0 } }
    func acquire() -> Bool {
        busy.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
    func release() { busy.withLock { $0 = false } }
}

func decodeBrightnessReply(_ reply: DWORD_PTR) throws(WindowsError) -> Int {
    if reply == DWORD_PTR(brightnessBusyReply) {
        throw .unsupported("SwiftyToys is applying another brightness change. Retry in a moment.")
    }
    guard (1...101).contains(reply) else {
        throw .unsupported("Resident did not apply the requested brightness.")
    }
    return Int(reply) - 1
}

/// Kernel events are thread-safe; ownership lasts through any delayed completion.
private final class ReplyEvent: @unchecked Sendable {
    let handle: OwnedHandle
    let reply = Mutex<Result<DisplayState, WindowsError>?>(nil)
    init() throws { handle = try OwnedHandle(CreateEventW(nil, true, false, nil)) }
}
/// Win32's message loop owns UI state. It does not run Swift's MainActor queue.
func displayCommand(_ controller: DisplayController, command: Int, value: Int = 0, mode: String? = nil) throws -> DisplayState {
    let event = try ReplyEvent()
    guard controller.commandAdmission.acquire() else {
        throw WindowsError.unsupported("SwiftyToys is applying another brightness change. Retry in a moment.")
    }
    Task {
        let result: Result<DisplayState, WindowsError>
        do { result = .success(try await executeDisplayCommand(controller, command: command, value: value, mode: mode)) } catch let error as WindowsError {
            result = .failure(error)
        } catch { result = .failure(.unsupported(String(describing: error))) }
        event.reply.withLock { $0 = result }
        controller.commandAdmission.release()
        SetEvent(event.handle.raw)
    }
    guard waitForWindowEvent(event.handle.raw, timeout: 15000) == DWORD(WAIT_OBJECT_0),
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
    let profile: String?
    let profileDisplayID: String?
    init(_ command: Int, value: Int = 0, show: Bool = false, mode: String? = nil, profile: String? = nil, profileDisplayID: String? = nil) {
        self.command = command; self.value = value; self.show = show; self.mode = mode
        self.profile = profile
        self.profileDisplayID = profileDisplayID
    }
}
/// UI-owned, bounded queue. Polls never accumulate behind driver work.
struct DisplayRequestQueue {
    private(set) var active: DisplayRequest?
    private var brightness: DisplayRequest?
    private var mode: String?
    private var profile: DisplayRequest?
    private var automaticBrightness: Int?
    private var refresh: Int?
    var level: Int
    init(level: Int) { self.level = level }
    var hasBrightness: Bool { brightness != nil }
    mutating func enqueue(_ request: DisplayRequest) -> Bool {
        if request.command == 1 { level = request.value }
        guard active != nil else { active = request; return true }
        if let requested = request.mode { mode = requested }
        else if request.profile != nil { profile = request }
        else if request.command == 7 { automaticBrightness = request.value }
        else if [3, 5, 8].contains(request.command) {
            if refresh != 3 && (refresh != 5 || request.command != 8) { refresh = request.command }
        }
        else if request.command != 4 { brightness = request }
        return false
    }
    mutating func finish(level applied: Int) -> DisplayRequest? {
        active = nil
        if let requested = mode { mode = nil; return DisplayRequest(3, mode: requested) }
        if let requested = profile { profile = nil; return requested }
        if let requested = refresh { refresh = nil; return DisplayRequest(requested) }
        if let requested = automaticBrightness { automaticBrightness = nil; return DisplayRequest(7, value: requested) }
        if let requested = brightness { brightness = nil; return requested }
        level = applied
        return nil
    }
    static func selfCheck() throws {
        let admission = DisplayCommandAdmission()
        guard !admission.isBusy, admission.acquire(), admission.isBusy,
            !admission.acquire(), !admission.acquire() else {
            throw WindowsError.unsupported("Display admission did not retain a pending operation.")
        }
        admission.release()
        guard !admission.isBusy, admission.acquire(), !admission.acquire() else {
            throw WindowsError.unsupported("Display admission did not reopen after completion.")
        }
        admission.release()
        guard try decodeBrightnessReply(1) == 0, try decodeBrightnessReply(101) == 100 else {
            throw WindowsError.unsupported("Brightness reply range check failed.")
        }
        for invalid in [DWORD_PTR(0), DWORD_PTR(brightnessBusyReply), DWORD_PTR.max] {
            var rejected = false
            do { _ = try decodeBrightnessReply(invalid) } catch { rejected = true }
            guard rejected else { throw WindowsError.unsupported("Invalid brightness reply was accepted.") }
        }
        var queue = DisplayRequestQueue(level: 50)
        guard queue.enqueue(DisplayRequest(4)), !queue.enqueue(DisplayRequest(1, value: 60)),
            !queue.enqueue(DisplayRequest(1, value: 70)), !queue.enqueue(DisplayRequest(3, mode: "hardware")),
            !queue.enqueue(DisplayRequest(5)), !queue.enqueue(DisplayRequest(4)), queue.level == 70,
            let mode = queue.finish(level: 50), mode.mode == "hardware", queue.enqueue(mode),
            let refresh = queue.finish(level: 50), refresh.command == 5, queue.enqueue(refresh),
            let latest = queue.finish(level: 50), latest.value == 70, queue.enqueue(latest),
            queue.finish(level: 70) == nil, queue.active == nil, queue.level == 70
        else { throw WindowsError.unsupported("Display request ordering/coalescing check failed.") }
        var automaticQueue = DisplayRequestQueue(level: 80)
        guard automaticQueue.enqueue(DisplayRequest(4)),
            !automaticQueue.enqueue(DisplayRequest(7, value: 1)),
            !automaticQueue.enqueue(DisplayRequest(1, value: 75)),
            !automaticQueue.enqueue(DisplayRequest(7, value: 0)),
            let automatic = automaticQueue.finish(level: 80), automatic.command == 7, automatic.value == 0,
            automaticQueue.enqueue(automatic),
            let brightness = automaticQueue.finish(level: 80), brightness.command == 1, brightness.value == 75,
            automaticQueue.enqueue(brightness), automaticQueue.finish(level: 75) == nil else {
            throw WindowsError.unsupported("Automatic brightness coalescing lost the manual brightness request.")
        }
        var topologyQueue = DisplayRequestQueue(level: 80)
        guard topologyQueue.enqueue(DisplayRequest(4)),
            !topologyQueue.enqueue(DisplayRequest(8)),
            !topologyQueue.enqueue(DisplayRequest(5)),
            !topologyQueue.enqueue(DisplayRequest(8)),
            let resume = topologyQueue.finish(level: 80), resume.command == 5,
            topologyQueue.enqueue(resume), topologyQueue.finish(level: 80) == nil else {
            throw WindowsError.unsupported("A resolution notification suppressed forced resume recovery.")
        }
        var profileQueue = DisplayRequestQueue(level: 80)
        guard profileQueue.enqueue(DisplayRequest(4)),
            !profileQueue.enqueue(DisplayRequest(9, profile: "first.icc")),
            !profileQueue.enqueue(DisplayRequest(1, value: 70)),
            !profileQueue.enqueue(DisplayRequest(9, profile: "")),
            let profile = profileQueue.finish(level: 80), profile.profile == "",
            profileQueue.enqueue(profile),
            let manual = profileQueue.finish(level: 80), manual.value == 70,
            profileQueue.enqueue(manual), profileQueue.finish(level: 70) == nil else {
            throw WindowsError.unsupported("Profile coalescing lost a pending brightness change.")
        }
        Console.writeLine("PASS: one request, latest brightness retained, mode/refresh ordered, idle polls dropped")
    }
}
final class DisplayMailbox: Sendable {
    let result = Mutex<Result<DisplayState, WindowsError>?>(nil)
}

func performDisplayCommand(_ controller: DisplayController, command: Int, value: Int, mode: String?, profile: String? = nil, profileDisplayID: String? = nil) async throws -> DisplayState {
    guard controller.commandAdmission.acquire() else {
        throw WindowsError.unsupported("SwiftyToys is applying another brightness change. Retry in a moment.")
    }
    defer { controller.commandAdmission.release() }
    if let profile {
        guard let profileDisplayID else { throw WindowsError.unsupported("Select one connected physical SDR display.") }
        return try await controller.setColorProfile(fileName: profile.isEmpty ? nil : profile, displayID: profileDisplayID)
    }
    return try await executeDisplayCommand(controller, command: command, value: value, mode: mode)
}

private func executeDisplayCommand(_ controller: DisplayController, command: Int, value: Int, mode: String?) async throws -> DisplayState {
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
func stopDisplay(_ controller: DisplayController) -> Bool {
    guard let event = try? ReplyEvent() else { return false }
    let restored = Mutex(false)
    Task {
        let completed = await controller.shutdown()
        restored.withLock { $0 = completed }
        SetEvent(event.handle.raw)
    }
    guard waitForWindowEvent(event.handle.raw, timeout: 15000) == DWORD(WAIT_OBJECT_0) else { return false }
    // The actor's deinit stops the executor after all outstanding jobs finish.
    return restored.withLock { $0 }
}
