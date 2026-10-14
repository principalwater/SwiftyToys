// SPDX-License-Identifier: MIT
import SearchCore
import Synchronization
import WinSDK

let searchUIActionMessage: UINT = 0x806b
let searchUIStatusMessage: UINT = 0x806c
private let searchUIWorkerClaimed = Mutex(false)
private let searchUIProbeMessage: UINT = 0x806d

// Only immutable kernel handles/destination and Mutex values cross threads. The controller,
// HWNDs and COM objects stay local to run(). Remove unchecked when OwnedHandle is Sendable.
private final class SearchUIState: @unchecked Sendable {
    struct Values {
        var started = false
        var stopped = false
        var toggle = false
        var preferences: SearchPreferences?
        var reset: UInt64 = 0
        var acknowledged: UInt64 = 0
        var error: String?
        var errorQueued = false
    }
    let values = Mutex(Values())
    let destination: MessageDestination
    let wake: OwnedHandle
    let resetDone: OwnedHandle
    let finished: OwnedHandle
    let fixture: SearchUIFixture?

    init(destination: MessageDestination, fixture: SearchUIFixture? = nil) throws {
        self.destination = destination
        self.fixture = fixture
        wake = try OwnedHandle(CreateEventW(nil, false, false, nil))
        resetDone = try OwnedHandle(CreateEventW(nil, true, false, nil))
        finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
    }

    func requestStop() {
        values.withLock {
            $0.stopped = true
            $0.toggle = false
            $0.preferences = nil
            $0.error = nil
            if !$0.started { SetEvent(finished.raw) }
            SetEvent(resetDone.raw)
        }
        SetEvent(wake.raw)
    }

    func report(_ error: any Error, generation: UInt64) {
        let text = String(decoding: String(describing: error).utf16.prefix(4096), as: UTF16.self)
        values.withLock {
            guard !$0.stopped, $0.reset == generation else { return }
            $0.error = text
            if !$0.errorQueued { $0.errorQueued = destination.post(searchUIStatusMessage) }
        }
    }

    func action(_ id: String, generation: UInt64) throws {
        guard let index = SearchCommands.items.firstIndex(where: { $0.id == "action:" + id }) else {
            throw WindowsError.unsupported("Unknown Search action.")
        }
        try values.withLock {
            guard !$0.stopped, $0.reset == generation else { return }
            guard destination.post(searchUIActionMessage, value: index, data: Int(generation)) else {
                throw WindowsError.api("Post Search action", GetLastError())
            }
        }
    }

    func run() {
        var controller: NativeSearchController?
        var generation = values.withLock { $0.acknowledged }
        var fixturePanels: [HWND] = []
        defer {
            controller?.stop()
            controller = nil
            NativeSearchBackdrop.shutdown()
            if let fixture {
                fixture.values.withLock {
                    $0.released = fixturePanels.allSatisfy { !IsWindow($0) }
                }
            }
            SetEvent(resetDone.raw)
            SetEvent(finished.raw)
        }
        var message = MSG()
        PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE))
        while !values.withLock({ $0.stopped }) {
            let request = values.withLock { value -> (UInt64, Bool, SearchPreferences?) in
                let request = (value.reset, value.toggle, value.preferences)
                value.toggle = false
                value.preferences = nil
                return request
            }
            if request.0 != generation {
                controller?.stop()
                controller = nil
                generation = request.0
                fixture?.reset(destination: destination,
                    released: fixturePanels.allSatisfy { !IsWindow($0) })
                values.withLock {
                    $0.acknowledged = generation
                    SetEvent(resetDone.raw)
                }
            }
            if let preferences = request.2 {
                do {
                    if request.1, controller == nil {
                        try fixture?.beforePrepare()
                        guard !values.withLock({ $0.stopped }) else { break }
                        guard values.withLock({ $0.reset == generation }) else { continue }
                        controller = NativeSearchController(preferences: preferences, action: {
                            [self, generation] id in try action(id, generation: generation)
                        })
                        let window = try controller?.prepare()
                        if let fixture, let window {
                            fixturePanels.append(window)
                            // Construction must succeed; production's opaque fallback cannot satisfy this check.
                            _ = try NativeSearchBackdrop(parent: window)
                            fixture.prepared(hidden: !IsWindowVisible(window)
                                && GetWindowThreadProcessId(window, nil) == GetCurrentThreadId())
                        }
                    }
                    let pending = values.withLock { value -> (Bool, SearchPreferences?)? in
                        guard !value.stopped, value.reset == generation else { return nil }
                        guard controller != nil else { return nil }
                        let pending = (request.1 != value.toggle, value.preferences ?? request.2)
                        value.toggle = false
                        value.preferences = nil
                        return pending
                    }
                    if let pending {
                        if let preferences = pending.1 { controller?.preferences = preferences }
                        if pending.0 {
                            if let fixture { fixture.toggle() }
                            else { try controller?.toggle() }
                        }
                        fixture?.updated(semantic: controller?.preferences.semantic ?? false)
                    }
                } catch { report(error, generation: generation) }
            }
            // Bound each drain so queued input cannot starve reset or shutdown requests.
            for _ in 0..<256 {
                guard !values.withLock({ $0.stopped }),
                    PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) else { break }
                if message.message == UINT(WM_QUIT) { requestStop(); break }
                if !(controller?.dialogMessage(&message) ?? false) {
                    TranslateMessage(&message)
                    DispatchMessageW(&message)
                }
            }
            if values.withLock({ $0.stopped }) { break }
            var handle: HANDLE? = wake.raw
            let result = MsgWaitForMultipleObjectsEx(1, &handle, DWORD(INFINITE),
                DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
            if result == DWORD(WAIT_FAILED) {
                report(WindowsError.api("Wait for Search UI", GetLastError()), generation: generation)
                values.withLock { $0.stopped = true; $0.toggle = false; $0.preferences = nil }
            }
        }
    }
}

/// One lazily started native UI thread; resets keep its Windows XAML manager alive.
final class NativeSearchUI {
    private let state: SearchUIState
    private var thread: NativeThread?

    init(destination: MessageDestination) throws {
        state = try SearchUIState(destination: destination)
    }

    private init(destination: MessageDestination, fixture: SearchUIFixture) throws {
        state = try SearchUIState(destination: destination, fixture: fixture)
    }

    /// Called by the main control thread; no Search HWND or COM initialization occurs here.
    func toggle(preferences: SearchPreferences) throws {
        let start = try state.values.withLock { value -> Bool in
            guard !value.stopped else { throw WindowsError.unsupported("Search UI is stopping.") }
            value.toggle.toggle()
            value.preferences = preferences
            return !value.started
        }
        NativeSearchLibraryActivity.touch()
        if start {
            guard searchUIWorkerClaimed.withLock({ claimed in
                guard !claimed else { return false }
                claimed = true
                return true
            }) else { throw WindowsError.unsupported("The Search UI thread has already been started.") }
            do {
                state.values.withLock { $0.started = true }
                let state = state
                thread = try NativeThread(name: "SwiftyToys Search UI") { state.run() }
            } catch {
                state.values.withLock { $0.started = false; $0.toggle = false; $0.preferences = nil }
                searchUIWorkerClaimed.withLock { $0 = false }
                throw error
            }
        }
        SetEvent(state.wake.raw)
    }

    /// Acknowledges controller destruction before preferences/model maintenance proceeds.
    func reset() throws {
        let generation = try state.values.withLock { value -> UInt64 in
            guard !value.stopped else { throw WindowsError.unsupported("Search UI is stopping.") }
            guard value.reset < UInt64(Int.max) else {
                throw WindowsError.unsupported("Search UI reset generation is exhausted.")
            }
            value.reset += 1
            value.toggle = false
            value.preferences = nil
            value.error = nil
            ResetEvent(state.resetDone.raw)
            if !value.started { value.acknowledged = value.reset; SetEvent(state.resetDone.raw) }
            return value.reset
        }
        SetEvent(state.wake.raw)
        let deadline = GetTickCount64() + 5000
        while try !state.values.withLock({ value -> Bool in
            if value.acknowledged >= generation { return true }
            guard !value.stopped else { throw WindowsError.unsupported("Search UI is stopping.") }
            ResetEvent(state.resetDone.raw)
            return false
        }) {
            let now = GetTickCount64()
            guard now < deadline,
                waitForWindowEvent(state.resetDone.raw, timeout: DWORD(deadline - now))
                    == DWORD(WAIT_OBJECT_0) else {
                throw WindowsError.unsupported("Search UI did not reset. Retry after it finishes.")
            }
        }
    }

    /// Refreshes an existing panel; unopened Search stays lazy.
    func update(preferences: SearchPreferences) throws {
        let queued = try state.values.withLock { value -> Bool in
            guard !value.stopped else { throw WindowsError.unsupported("Search UI is stopping.") }
            guard value.started else { return false }
            value.preferences = preferences
            return true
        }
        if queued { SetEvent(state.wake.raw) }
    }

    func takeError() -> String? {
        state.values.withLock {
            let error = $0.error
            $0.error = nil
            $0.errorQueued = false
            return error
        }
    }

    /// Rejects actions queued before a reset or shutdown; the caller validates the built-in index.
    func acceptsAction(generation: LPARAM) -> Bool {
        guard generation >= 0 else { return false }
        return state.values.withLock { !$0.stopped && $0.reset == UInt64(generation) }
    }

    @discardableResult func stop() -> Bool {
        state.requestStop()
        return waitForWindowEvent(state.finished.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0)
    }

    deinit { state.requestStop() }
}

// Hidden owned fixtures use the production mailbox/thread; only actual show is replaced.
// Like SearchUIState, kernel handles are immutable and every shared test value is locked.
private final class SearchUIFixture: @unchecked Sendable {
    struct Values {
        var blockNext = true
        var prepared = 0
        var visible = false
        var threadID: DWORD = 0
        var replies = 0
        var hidden = true
        var released = false
        var semantic = false
        var resetReleased = true
    }
    let values = Mutex(Values())
    let entered: OwnedHandle
    let release: OwnedHandle
    let changed: OwnedHandle
    init() throws {
        entered = try OwnedHandle(CreateEventW(nil, true, false, nil))
        release = try OwnedHandle(CreateEventW(nil, true, false, nil))
        changed = try OwnedHandle(CreateEventW(nil, false, false, nil))
    }
    func beforePrepare() throws {
        guard values.withLock({ value in
            let block = value.blockNext
            value.blockNext = false
            return block
        }) else { return }
        SetEvent(entered.raw)
        guard WaitForSingleObject(release.raw, 5000) == DWORD(WAIT_OBJECT_0) else {
            throw WindowsError.unsupported("Search UI fixture gate timed out.")
        }
    }
    func prepared(hidden: Bool) {
        values.withLock {
            $0.prepared += 1
            $0.threadID = GetCurrentThreadId()
            $0.hidden = $0.hidden && hidden
        }
    }
    func toggle() { values.withLock { $0.visible.toggle() } }
    func updated(semantic: Bool) {
        values.withLock { $0.semantic = semantic }
        SetEvent(changed.raw)
    }
    func reset(destination: MessageDestination, released: Bool) {
        var reply: DWORD_PTR = 0
        let sent = SendMessageTimeoutW(destination.window, searchUIProbeMessage, 0, 0,
            UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 1000, &reply)
        values.withLock {
            $0.visible = false
            $0.resetReleased = $0.resetReleased && released
            if sent != 0, reply == 109 { $0.replies += 1 }
        }
    }
}

private func searchUIFixtureProcedure(_ window: HWND?, _ message: UINT,
    _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    if message == searchUIProbeMessage { return 109 }
    return DefWindowProcW(window, message, value, data)
}

extension NativeSearchUI {
    static func selfCheck() throws {
        func expect(_ valid: Bool, _ detail: String) throws {
            if !valid { throw WindowsError.unsupported("Search UI worker check failed: " + detail) }
        }
        var type = WNDCLASSEXW()
        type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = searchUIFixtureProcedure
        type.hInstance = GetModuleHandleW(nil)
        let name = "SwiftyToys.SearchUIFixture"
        guard withWideString(name, { type.lpszClassName = $0; return RegisterClassExW(&type) }) != 0 else {
            throw WindowsError.api("Register Search UI fixture", GetLastError())
        }
        defer { _ = withWideString(name) { UnregisterClassW($0, type.hInstance) } }
        guard let window = withWideString(name, {
            CreateWindowExW(0, $0, nil, 0, 0, 0, 1, 1, nil, nil, type.hInstance, nil)
        }) else { throw WindowsError.api("Create Search UI destination fixture", GetLastError()) }
        defer { DestroyWindow(window) }
        let fixture = try SearchUIFixture()
        let ui = try NativeSearchUI(destination: MessageDestination(window), fixture: fixture)
        defer { SetEvent(fixture.release.raw); ui.stop() }
        let preferences = SearchPreferences(contents: "enabled=1\nsemantic=0")
        try ui.update(preferences: preferences)
        try ui.reset()
        try expect(!ui.state.values.withLock({ $0.started }), "reset preserves lazy startup")
        try ui.toggle(preferences: preferences)
        try expect(waitForWindowEvent(fixture.entered.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0),
            "toggle returns while owner preparation is blocked")
        for _ in 0..<199 { try ui.toggle(preferences: preferences) }
        SetEvent(fixture.release.raw)
        try expect(waitForWindowEvent(fixture.changed.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0),
            "bounded coalesced toggles complete")
        let threadID = fixture.values.withLock { $0.threadID }
        try expect(threadID != 0 && threadID != GetCurrentThreadId()
            && fixture.values.withLock({ !$0.visible && $0.prepared == 1 && $0.hidden }),
            "even rapid toggle parity and ownership")
        try ui.toggle(preferences: preferences)
        try expect(waitForWindowEvent(fixture.changed.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0)
            && fixture.values.withLock({ $0.visible }), "subsequent odd toggle opens")
        var updatedPreferences = preferences
        updatedPreferences.semantic = true
        try ui.update(preferences: updatedPreferences)
        try expect(waitForWindowEvent(fixture.changed.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0)
            && fixture.values.withLock({ $0.visible && $0.semantic && $0.prepared == 1 }),
            "maintenance completion updates the existing panel without toggling")
        for _ in 0..<4 {
            try ui.reset()
            try ui.toggle(preferences: preferences)
            try expect(waitForWindowEvent(fixture.changed.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0),
                "controller recreates without framework shutdown")
            try expect(fixture.values.withLock({ $0.threadID == threadID && $0.visible }),
                "resets preserve native owner thread")
        }
        try ui.reset()
        try expect(fixture.values.withLock({ $0.replies == 5 && !$0.visible && $0.resetReleased }),
            "reset wait services cross-thread native sent messages")
        let generation = ui.state.values.withLock { $0.reset }
        try ui.state.action("settings", generation: generation)
        var action = MSG()
        try expect(PeekMessageW(&action, window, searchUIActionMessage, searchUIActionMessage,
            UINT(PM_REMOVE)) && action.wParam == 0 && ui.acceptsAction(generation: action.lParam),
            "validated built-in action reaches main destination")
        try ui.state.action("settings", generation: generation)
        try ui.reset()
        try expect(PeekMessageW(&action, window, searchUIActionMessage, searchUIActionMessage,
            UINT(PM_REMOVE)) && !ui.acceptsAction(generation: action.lParam),
            "reset rejects a previously queued action")
        let currentGeneration = ui.state.values.withLock { $0.reset }
        ui.state.report(WindowsError.unsupported("first"), generation: currentGeneration)
        ui.state.report(WindowsError.unsupported("latest"), generation: currentGeneration)
        var status = MSG()
        try expect(PeekMessageW(&status, window, searchUIStatusMessage, searchUIStatusMessage,
            UINT(PM_REMOVE)) && !PeekMessageW(&status, window, searchUIStatusMessage,
                searchUIStatusMessage, UINT(PM_REMOVE)) && ui.takeError() == "latest",
            "bounded coalesced error mailbox")
        ResetEvent(fixture.entered.raw)
        ResetEvent(fixture.release.raw)
        fixture.values.withLock { $0.blockNext = true }
        try ui.toggle(preferences: preferences)
        try expect(waitForWindowEvent(fixture.entered.raw, timeout: 5000) == DWORD(WAIT_OBJECT_0),
            "shutdown fixture enters preparation")
        ui.state.requestStop()
        SetEvent(fixture.release.raw)
        try expect(ui.stop() && ui.stop(), "shutdown joins owner and is idempotent")
        try expect(fixture.values.withLock({ $0.hidden && $0.released }),
            "fixture HWNDs remain hidden and are released on their owning thread")
        ui.state.report(WindowsError.unsupported("late"), generation: generation)
        try ui.state.action("settings", generation: generation)
        try expect(ui.takeError() == nil && !PeekMessageW(&action, window, searchUIActionMessage,
            searchUIActionMessage, UINT(PM_REMOVE)), "stopped producer cannot post actions or errors")
        var rejected = false
        do { try ui.toggle(preferences: preferences) } catch { rejected = true }
        try expect(rejected, "toggle rejects stopped worker")
        Console.writeLine("PASS: hidden Search UI owner, lazy nonblocking toggle/parity, repeated reset and native sent replies, bounded action/error delivery and shutdown")
    }
}
