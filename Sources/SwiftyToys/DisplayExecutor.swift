// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK

/// Dedicated thread for blocking display APIs, with a mutex-protected job queue.
final class DisplayExecutor: SerialExecutor, @unchecked Sendable {
    private struct State {
        var jobs: [UnownedJob] = []
        var stopping = false
    }
    private let state = Mutex(State())
    private let wake: OwnedHandle
    private var thread: NativeThread?

    init() throws {
        wake = try OwnedHandle(CreateEventW(nil, false, false, nil))
        thread = try NativeThread(name: "SwiftyToys display APIs") { [weak self] in self?.run() }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        state.withLock { $0.jobs.append(job) }
        SetEvent(wake.raw)
    }

    private func run() {
        // Windows composition controls live on this same executor, not a second
        // renderer thread. Bound each message batch so actor jobs stay responsive.
        while true {
            var message = MSG()
            for _ in 0..<32 {
                guard PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) else { break }
                if message.message != UINT(WM_QUIT) { TranslateMessage(&message); DispatchMessageW(&message) }
            }
            let next = state.withLock { state -> (UnownedJob?, Bool) in
                if !state.jobs.isEmpty { return (state.jobs.removeFirst(), false) }
                return (nil, state.stopping)
            }
            if let job = next.0 {
                job.runSynchronously(on: asUnownedSerialExecutor())
            } else if next.1 {
                return
            } else {
                var handle: HANDLE? = wake.raw
                _ = MsgWaitForMultipleObjectsEx(1, &handle, DWORD(INFINITE), DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
            }
        }
    }

    /// Stop after the controller has restored its output and accepted no jobs.
    func stop() {
        state.withLock { $0.stopping = true }
        SetEvent(wake.raw)
    }
}
