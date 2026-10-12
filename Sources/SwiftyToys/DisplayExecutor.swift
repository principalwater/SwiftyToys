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
        while true {
            let next = state.withLock { state -> (UnownedJob?, Bool) in
                if !state.jobs.isEmpty { return (state.jobs.removeFirst(), false) }
                return (nil, state.stopping)
            }
            if let job = next.0 {
                job.runSynchronously(on: asUnownedSerialExecutor())
            } else if next.1 {
                return
            } else {
                WaitForSingleObject(wake.raw, DWORD(INFINITE))
            }
        }
    }

    /// Stop after the controller has restored its output and accepted no jobs.
    func stop() {
        state.withLock { $0.stopping = true }
        SetEvent(wake.raw)
    }
}
