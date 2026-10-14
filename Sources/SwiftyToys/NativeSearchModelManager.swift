// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK

let searchModelMessage: UINT = 0x8061
struct SearchModelStatus: Sendable {
    let text: String
    let busy: Bool
    let downloaded: Bool
    var repositoryID: String = "onnx-community/embeddinggemma-2-ONNX"
    var mediaDownloaded = false
    var modelIDs: [String] = []
    var catalogQuery: String? = nil
}

/// Settings never load a model or DLL. Explicit acquisition uses a cancellable cold worker.
final class NativeSearchModelManager: Sendable {
    private struct State: Sendable { var busy = false; var cancelled = false; var posted = false; var pending: SearchModelStatus? }
    private let state = Mutex(State())
    private let destination: MessageDestination
    var busy: Bool { state.withLock { $0.busy } }
    init(destination: MessageDestination) { self.destination = destination }
    func take() -> SearchModelStatus? { state.withLock { state in let value = state.pending; state.pending = nil; state.posted = false; return value } }
    private func publish(_ text: String, busy: Bool, downloaded: Bool = false,
        repositoryID: String = "", mediaDownloaded: Bool = false,
        modelIDs: [String] = [], catalogQuery: String? = nil) {
        state.withLock { state in
            state.pending = SearchModelStatus(text: text, busy: busy, downloaded: downloaded,
                repositoryID: repositoryID, mediaDownloaded: mediaDownloaded,
                modelIDs: modelIDs, catalogQuery: catalogQuery)
            if !state.posted { state.posted = destination.post(searchModelMessage) }
        }
    }
    func cancel() { state.withLock { $0.cancelled = true } }
    private func isCancelled() -> Bool { state.withLock { $0.cancelled } }
    func start(_ operation: String, repositoryID: String? = nil, includeMedia: Bool? = nil,
        prepare: @escaping @Sendable () -> Void = {}) throws {
        guard ["status", "download", "remove", "catalog", "resolve"].contains(operation), state.withLock({ state in
            guard !state.busy else { return false }; state.busy = true; state.cancelled = false; return true
        }) else { throw WindowsError.unsupported("The optional model is busy. Wait or cancel its download first.") }
        do {
            _ = try NativeThread(name:"SwiftyToys optional model") {
                defer { self.state.withLock { $0.busy = false } }
                _ = SetThreadPriority(GetCurrentThread(),Int32(-1))
                prepare()
                do {
                    let preferences = SearchPreferences()
                    let selectedID = repositoryID ?? preferences.modelRepository
                    let media = includeMedia ?? preferences.media
                    if operation == "catalog" {
                        self.publish("Finding public embedding models on Hugging Face…", busy: true)
                        let candidates = try NativeSearchModelCatalog.search(selectedID,
                            cancelled: { self.isCancelled() })
                        let ids = NativeSearchModelCatalog.builtIns.map(\.repositoryID)
                            + candidates.map(\.repositoryID)
                        var seen = Set<String>()
                        self.publish("Model catalog refreshed. Choose a model, then check compatibility.",
                            busy: false, modelIDs: ids.filter { seen.insert($0).inserted }, catalogQuery: selectedID)
                        return
                    }
                    let model: NativeSearchModelDescriptor
                    if operation == "download" || operation == "resolve" {
                        self.publish("Checking model compatibility…", busy: true)
                        model = try NativeSearchModelCatalog.resolve(repositoryID: selectedID,
                            cancelled: { self.isCancelled() })
                    } else { model = try NativeSearchModelCatalog.descriptor(repositoryID: selectedID) }
                    if operation == "download" {
                        self.publish("Downloading optional model…",busy:true)
                        let throttle = Mutex((stage:"",tick:UInt64(0),percent:UInt64(0)))
                        try NativeEmbeddingAssets.download(model: model, includeMedia: media, progress:{ progress in
                            let now = GetTickCount64(), percent = progress.total == 0 ? 0 : progress.completed * 100 / progress.total
                            let changed = throttle.withLock { state in
                                guard state.stage != progress.stage || (now - state.tick >= 250 && percent != state.percent) else { return false }
                                state = (progress.stage,now,percent); return true
                            }
                            if changed { self.publish(progress.stage + " · " + String(percent) + "%",busy:true) }
                        },cancelled:{ self.isCancelled() })
                    } else if operation == "remove" {
                        self.publish("Removing selected model…",busy:true); try NativeEmbeddingAssets.remove(model: model)
                    }
                    switch try NativeEmbeddingAssets.status(model: model) {
                    case .downloaded:
                        let available = preferences.allLocalDrives || !preferences.folders.isEmpty
                        let mediaReady = try NativeEmbeddingAssets.mediaStatus(model: model) == .downloaded
                        self.publish(preferences.semanticSetupMessage(folderAvailable: available, documentCount: 1)
                            + (model.adapter != .gemmaBPE ? " This model supports text only; choose EmbeddingGemma 2 for media content." : media && !mediaReady ? " Download the media encoders to search image, audio and video content." : ""),
                            busy: false, downloaded: true, repositoryID: model.repositoryID, mediaDownloaded: mediaReady)
                    case .missing: self.publish("Selected model is compatible but not downloaded. Basic search works without it.",busy:false,repositoryID:model.repositoryID)
                    case .unsupported: self.publish("The optional components need a compatible Windows x64 CPU. Basic search remains available.",busy:false,repositoryID:model.repositoryID)
                    }
                } catch { self.publish(self.isCancelled() ? "Download cancelled. Basic search remains available." : "Optional model could not complete: " + String(describing:error),busy:false) }
            }
        } catch { state.withLock { $0.busy = false }; throw error }
    }
}
