// SPDX-License-Identifier: MIT
import KeyboardCore
import Synchronization
import WinSDK

private let foregroundWorkerOwned = Mutex(false)

private final class ForegroundProcess: @unchecked Sendable {
    let handle: OwnedHandle
    init(_ handle: consuming OwnedHandle) { self.handle = handle }
    var alive: Bool { WaitForSingleObject(handle.raw, 0) == DWORD(WAIT_TIMEOUT) }
}

private final class ForegroundQueryGate: @unchecked Sendable {
    let started: OwnedHandle
    let release: OwnedHandle
    init() throws {
        started = try OwnedHandle(CreateEventW(nil, true, false, nil))
        release = try OwnedHandle(CreateEventW(nil, true, false, nil))
    }
}

/// Slow queries never hold the mailbox lock or run on the keyboard-hook owner.
final class ForegroundResolver: @unchecked Sendable {
    private static let sharedResolver = Mutex((resolver: Optional<ForegroundResolver>.none, stopped: false))

    /// Reuse one resolver across settings reloads, including when a native query is stalled.
    static func shared() throws -> ForegroundResolver {
        let snapshot = sharedResolver.withLock { $0 }
        guard !snapshot.stopped else {
            throw WindowsError.unsupported("Application is closing.")
        }
        if let resolver = snapshot.resolver { return resolver }
        let created = try ForegroundResolver()
        let accepted = sharedResolver.withLock { value in
            guard !value.stopped else { return false }
            value.resolver = created
            return true
        }
        guard accepted else { created.stop(); throw WindowsError.unsupported("Application is closing.") }
        return created
    }

    static func stopShared() {
        let resolver = sharedResolver.withLock { value in
            let previous = value.resolver
            value.stopped = true
            value.resolver = nil
            return previous
        }
        resolver?.stop()
    }

    private struct Cached {
        let pid: DWORD
        let process: ForegroundProcess?
        let foreground: ForegroundApplication
        let retryAt: UInt64
    }
    private struct Request: Equatable { let pid: DWORD; let window: UInt }
    private struct Values {
        var stopped = false
        var pending: Request?
        var working: Request?
        var cache: [Cached] = []
        var layouts: [UInt] = []
        var refreshLayouts = true
    }
    private final class State: @unchecked Sendable {
        let values = Mutex(Values())
        let wake: OwnedHandle
        let ready: OwnedHandle
        let finished: OwnedHandle
        init() throws {
            wake = try OwnedHandle(CreateEventW(nil, false, false, nil))
            ready = try OwnedHandle(CreateEventW(nil, true, false, nil))
            finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
        }
    }
    private let state: State
    private let thread: NativeThread

    init(lookup: @escaping @Sendable (HANDLE) -> String? = processApplication) throws {
        let state = try State()
        self.state = state
        guard foregroundWorkerOwned.withLock({ owned in
            guard !owned else { return false }
            owned = true
            return true
        }) else {
            throw WindowsError.unsupported("The previous foreground resolver is still stopping. Try again after it finishes.")
        }
        if let window = GetForegroundWindow() {
            var pid: DWORD = 0
            GetWindowThreadProcessId(window, &pid)
            state.values.withLock { $0.pending = Request(pid: pid, window: UInt(bitPattern: window)) }
        }
        do { thread = try NativeThread(name: "SwiftyToys foreground resolver") {
            defer {
                foregroundWorkerOwned.withLock { $0 = false }
                SetEvent(state.ready.raw)
                SetEvent(state.finished.raw)
            }
            while true {
                let work = state.values.withLock { values -> (Bool, Request?, Cached?, Bool) in
                    guard !values.stopped else { return (true, nil, nil, false) }
                    let request = values.pending
                    values.pending = nil
                    values.working = request
                    let cached = request.flatMap { request in values.cache.first { $0.pid == request.pid } }
                    let layouts = values.refreshLayouts
                    values.refreshLayouts = false
                    return (false, request, cached, layouts)
                }
                if work.0 { return }
                // Registry reads and process queries may stall; input only reads the published cache.
                let layouts = work.3 ? configuredLayouts(resolveNames: true).map { UInt(bitPattern: $0) } : nil
                var resolved: Cached?
                if let request = work.1, request.pid != 0, request.window != 0 {
                    let existing = work.2.flatMap { $0.process?.alive == true ? $0 : nil }
                    if let existing {
                        resolved = existing
                    } else {
                        var foreground = work.2?.foreground ?? ForegroundApplication()
                        // A terminated process's ID can be reused; never reuse its old executable name.
                        if work.2?.process != nil { foreground = ForegroundApplication() }
                        var process: ForegroundProcess?
                        let application = foreground.resolve(
                            processID: request.pid, windowID: request.window, time: GetTickCount64()
                        ) { pid in
                            guard let raw = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE), false, pid),
                                let owned = try? OwnedHandle(raw) else { return nil }
                            let lifetime = ForegroundProcess(owned)
                            let name = lookup(lifetime.handle.raw)
                            guard lifetime.alive, name != nil else { return nil }
                            process = lifetime
                            return name
                        }
                        resolved = Cached(pid: request.pid, process: process, foreground: foreground,
                            retryAt: application == nil ? GetTickCount64() &+ 1000 : 0)
                    }
                }
                let publication = state.values.withLock { values -> (Bool, [Cached]) in
                    guard !values.stopped else { return (true, []) }
                    var retired: [Cached] = []
                    if let layouts { values.layouts = layouts }
                    if let resolved {
                        retired = values.cache.filter { $0.pid == resolved.pid }
                        values.cache.removeAll { $0.pid == resolved.pid }
                        if values.cache.count == 64 { retired.append(values.cache.removeFirst()) }
                        values.cache.append(resolved)
                    }
                    values.working = nil
                    return (false, retired)
                }
                // Keep evicted process handles alive until after unlocking; CloseHandle cannot hold up input.
                withExtendedLifetime(publication.1) {}
                SetEvent(state.ready.raw)
                if publication.0 { return }
                if WaitForSingleObject(state.wake.raw, 60000) == DWORD(WAIT_TIMEOUT) {
                    state.values.withLock { $0.refreshLayouts = true }
                }
            }
        } } catch { foregroundWorkerOwned.withLock { $0 = false }; throw error }
    }

    /// A zero-time process-lifetime check rejects PID reuse; no process lookup or layout loading occurs here.
    func consume(processID: DWORD, window: HWND?) -> String? {
        guard processID != 0, let window else {
            state.values.withLock { $0.pending = nil }
            return nil
        }
        let request = Request(pid: processID, window: UInt(bitPattern: window))
        let snapshot = state.values.withLock { values in
            (values.stopped, values.cache.first { $0.pid == processID })
        }
        guard !snapshot.0 else { return nil }
        if let cached = snapshot.1, cached.process?.alive == true {
            state.values.withLock { $0.pending = nil }
            return cached.foreground.consume(processID: processID)
        }
        if let cached = snapshot.1, cached.process == nil, GetTickCount64() < cached.retryAt {
            state.values.withLock { $0.pending = nil }
            return nil
        }
        var wake = false
        state.values.withLock { values in
            guard !values.stopped else { return }
            if values.working?.pid == processID {
                values.pending = nil
            } else if values.pending != request {
                values.pending = request // One coalesced request: the latest foreground wins.
                wake = true
            }
        }
        if wake { SetEvent(state.wake.raw) }
        return nil
    }

    var layouts: [HKL] {
        let snapshot = state.values.withLock { $0.layouts }
        return snapshot.compactMap { HKL(bitPattern: $0) }
    }

    func refreshLayouts() {
        state.values.withLock { if !$0.stopped { $0.refreshLayouts = true } }
        SetEvent(state.wake.raw)
    }

    func stop() {
        state.values.withLock { $0.stopped = true; $0.pending = nil }
        SetEvent(state.wake.raw)
        // A blocked native query retains State and its handles; hook/UI shutdown never joins it.
    }
    deinit { stop() }

    static func selfCheck() throws {
        let foreground = GetForegroundWindow()
        let foregroundThread = GetWindowThreadProcessId(foreground, nil)
        let foregroundLayout = GetKeyboardLayout(foregroundThread)
        let resolver = try ForegroundResolver()
        defer { resolver.stop() }
        guard WaitForSingleObject(resolver.state.ready.raw, 5000) == DWORD(WAIT_OBJECT_0) else {
            throw WindowsError.unsupported("Foreground resolver did not publish its initial snapshot.")
        }
        let window = HWND(bitPattern: 1)!
        _ = resolver.consume(processID: GetCurrentProcessId(), window: window)
        let deadline = GetTickCount64() + 5000
        while resolver.consume(processID: GetCurrentProcessId(), window: window) == nil, GetTickCount64() < deadline {
            Sleep(1)
        }
        guard resolver.consume(processID: GetCurrentProcessId(), window: window) == "swiftytoys.exe",
            resolver.consume(processID: 0, window: window) == nil,
            resolver.consume(processID: GetCurrentProcessId(), window: HWND(bitPattern: 2)) == "swiftytoys.exe" else {
            throw WindowsError.unsupported("Foreground resolver cache validation failed.")
        }
        resolver.stop()
        guard resolver.consume(processID: GetCurrentProcessId(), window: window) == nil,
            WaitForSingleObject(resolver.state.finished.raw, 5000) == DWORD(WAIT_OBJECT_0) else {
            throw WindowsError.unsupported("Foreground resolver did not stop cleanly.")
        }
        // Retain both events through the delayed worker even if an assertion throws.
        let gate = try ForegroundQueryGate()
        let probe = try ForegroundResolver { process in
            SetEvent(gate.started.raw)
            _ = WaitForSingleObject(gate.release.raw, DWORD(INFINITE))
            return processApplication(process)
        }
        defer { SetEvent(gate.release.raw); probe.stop() }
        _ = probe.consume(processID: GetCurrentProcessId(), window: window)
        guard WaitForSingleObject(gate.started.raw, 5000) == DWORD(WAIT_OBJECT_0) else {
            throw WindowsError.unsupported("Delayed foreground lookup did not start.")
        }
        let before = GetTickCount64()
        for _ in 0..<1000 {
            guard probe.consume(processID: DWORD.max, window: window) == nil else {
                throw WindowsError.unsupported("A delayed lookup applied to a different process.")
            }
        }
        probe.stop()
        guard GetTickCount64() - before < 1000,
            WaitForSingleObject(probe.state.finished.raw, 0) == DWORD(WAIT_TIMEOUT) else {
            throw WindowsError.unsupported("Foreground consume or stop waited for the blocked query.")
        }
        var duplicateRejected = false
        do { let duplicate = try ForegroundResolver(); duplicate.stop() }
        catch { duplicateRejected = true }
        guard duplicateRejected else {
            throw WindowsError.unsupported("A second resolver was started while the previous query was blocked.")
        }
        SetEvent(gate.release.raw)
        guard WaitForSingleObject(probe.state.finished.raw, 5000) == DWORD(WAIT_OBJECT_0),
            probe.consume(processID: GetCurrentProcessId(), window: window) == nil else {
            throw WindowsError.unsupported("Delayed foreground worker did not stop or published after stop.")
        }
        guard GetForegroundWindow() == foreground, GetKeyboardLayout(foregroundThread) == foregroundLayout else {
            throw WindowsError.unsupported("Foreground layout changed during independent resolution.")
        }
        Console.writeLine("PASS: independent foreground lookup, same-process window cache and resolver shutdown")
    }
}

private func processApplication(_ process: HANDLE) -> String? {
    withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: 1024) { buffer -> String? in
        var count = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, buffer.baseAddress, &count), count > 0, count < buffer.count else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self).split(separator: "\\").last.map {
            String($0).lowercased()
        }
    }
}
