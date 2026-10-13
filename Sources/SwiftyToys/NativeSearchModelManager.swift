// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK

let searchModelMessage: UINT = 0x8061
struct SearchModelStatus: Sendable { let text: String; let busy: Bool; let downloaded: Bool }

/// Settings never load a model or DLL. Explicit acquisition uses a cancellable cold worker.
final class NativeSearchModelManager: Sendable {
    private struct State: Sendable { var busy = false; var cancelled = false; var posted = false; var pending: SearchModelStatus? }
    private let state = Mutex(State())
    private let destination: MessageDestination
    init(destination: MessageDestination) { self.destination = destination }
    func take() -> SearchModelStatus? { state.withLock { state in let value = state.pending; state.pending = nil; state.posted = false; return value } }
    private func publish(_ text: String, busy: Bool, downloaded: Bool = false) {
        state.withLock { state in
            state.pending = SearchModelStatus(text:text,busy:busy,downloaded:downloaded)
            if !state.posted { state.posted = destination.post(searchModelMessage) }
        }
    }
    func cancel() { state.withLock { $0.cancelled = true } }
    private func isCancelled() -> Bool { state.withLock { $0.cancelled } }
    func start(_ operation: String) throws {
        guard ["status", "download", "remove"].contains(operation), state.withLock({ state in
            guard !state.busy else { return false }; state.busy = true; state.cancelled = false; return true
        }) else { throw WindowsError.unsupported("The optional model is busy. Wait or cancel its download first.") }
        do {
            _ = try NativeThread(name:"SwiftyToys optional model") {
                defer { self.state.withLock { $0.busy = false } }
                _ = SetThreadPriority(GetCurrentThread(),Int32(-1))
                do {
                    if operation == "download" {
                        self.publish("Downloading optional model…",busy:true)
                        let throttle = Mutex((stage:"",tick:UInt64(0),percent:UInt64(0)))
                        try NativeEmbeddingAssets.download(progress:{ progress in
                            let now = GetTickCount64(), percent = progress.total == 0 ? 0 : progress.completed * 100 / progress.total
                            let changed = throttle.withLock { state in
                                guard state.stage != progress.stage || (now - state.tick >= 250 && percent != state.percent) else { return false }
                                state = (progress.stage,now,percent); return true
                            }
                            if changed { self.publish(progress.stage + " · " + String(percent) + "%",busy:true) }
                        },cancelled:{ self.isCancelled() })
                    } else if operation == "remove" {
                        self.publish("Removing optional model…",busy:true); try NativeEmbeddingAssets.remove()
                    }
                    switch try NativeEmbeddingAssets.status() {
                    case .downloaded: self.publish("Optional model downloaded. It loads only when semantic search is enabled and used.",busy:false,downloaded:true)
                    case .missing: self.publish("Optional model is not downloaded. Basic search works without it.",busy:false)
                    case .unsupported: self.publish("The optional model needs a compatible Windows x64 CPU. Basic search remains available.",busy:false)
                    }
                } catch { self.publish(self.isCancelled() ? "Download cancelled. Basic search remains available." : "Optional model could not complete: " + String(describing:error),busy:false) }
            }
        } catch { state.withLock { $0.busy = false }; throw error }
    }
}
