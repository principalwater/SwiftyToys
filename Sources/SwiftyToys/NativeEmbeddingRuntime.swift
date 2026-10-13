// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import EmbeddingABI

/// This object exists only in the isolated embedding child, never in UI or input callbacks.
final class NativeEmbeddingEngine {
    private let runtimeFile: NativeEmbeddingFile
    private let graphFile: NativeEmbeddingFile
    private let weightFile: NativeEmbeddingFile
    private let directory: OwnedHandle
    private let library: HMODULE
    private let api: OrtApi
    private let tokenizer: GemmaBPETokenizer
    private var environment: OpaquePointer?, options: OpaquePointer?, session: OpaquePointer?, memory: OpaquePointer?
    private var documents: [String: [Float]] = [:]
    private var order: [String] = []
    private var lastQuery: (text: String, vector: [Float])?

    init(assetDirectory: String? = nil) throws {
        guard NativeEmbeddingAssets.supported() else { throw WindowsError.unsupported("Local semantic search requires Windows10 version1903 or newer.") }
        let root = try assetDirectory ?? NativeEmbeddingAssets.directory()
        try NativeEmbeddingAssets.inspect(root, directory: true)
        directory = try OwnedHandle(withWideString(try NativeFiles.windowsPath(root)) { CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil) })
        runtimeFile = try NativeEmbeddingFile(root + "\\" + NativeEmbeddingAssets.runtime.name, asset: NativeEmbeddingAssets.runtime)
        graphFile = try NativeEmbeddingFile(root + "\\" + NativeEmbeddingAssets.graph.name, asset: NativeEmbeddingAssets.graph)
        weightFile = try NativeEmbeddingFile(root + "\\" + NativeEmbeddingAssets.weights.name, asset: NativeEmbeddingAssets.weights)
        let runtimePath = root + "\\" + NativeEmbeddingAssets.runtime.name
        try NativeDriverTrust.verifySignature(runtimePath, signer: .microsoftWindows, fileHandle: runtimeFile.raw)
        tokenizer = try GemmaBPETokenizer(path: root + "\\" + NativeEmbeddingAssets.tokenizer.name)
        guard let loaded = withWideString(try NativeFiles.windowsPath(runtimePath), { LoadLibraryExW($0, nil, DWORD(LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32)) }) else { throw WindowsError.api("Load signed local search component", GetLastError()) }
        library = loaded
        guard let address = "OrtGetApiBase".withCString({ GetProcAddress(loaded, $0) }) else { FreeLibrary(loaded); throw WindowsError.unsupported("The local search component is incompatible. Download it again.") }
        typealias GetBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
        guard let base = unsafeBitCast(address, to: GetBase.self)(), let table = base.pointee.GetApi(27) else { FreeLibrary(loaded); throw WindowsError.unsupported("The local search component is incompatible. Download it again.") }
        api = table.pointee
        do {
            try "SwiftyToys local search".withCString { try check(api.CreateEnv(ORT_LOGGING_LEVEL_FATAL, $0, &environment)) }
            // Local documents are not telemetry; disable vendor events before any user content is processed.
            try check(api.DisableTelemetryEvents(environment))
            try check(api.CreateSessionOptions(&options))
            try check(api.SetSessionExecutionMode(options, ORT_SEQUENTIAL))
            try check(api.SetIntraOpNumThreads(options, 1)); try check(api.SetInterOpNumThreads(options, 1))
            try check(api.SetSessionLogSeverityLevel(options, 4))
            for key in ["session.intra_op.allow_spinning", "session.inter_op.allow_spinning"] {
                try key.withCString { key in try "0".withCString { try check(api.AddSessionConfigEntry(options, key, $0)) } }
            }
            try check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
            try check(api.CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memory))
            try withWideString(NativeFiles.windowsPath(root + "\\" + NativeEmbeddingAssets.graph.name)) { try check(api.CreateSession(environment, $0, options, &session)) }
        }
    }
    private func check(_ status: OpaquePointer?) throws {
        if let status {
            let code = api.GetErrorCode(status)
            api.ReleaseStatus(status)
            // Native runtime diagnostics can contain local document paths; the UI gets a bounded generic reason.
            throw WindowsError.unsupported("Local semantic search could not process this request (component status \(code.rawValue)). Text search remains available.")
        }
    }
    private func dispose() {
        if let session { api.ReleaseSession(session); self.session = nil }
        if let memory { api.ReleaseMemoryInfo(memory); self.memory = nil }
        if let options { api.ReleaseSessionOptions(options); self.options = nil }
        if let environment { api.ReleaseEnv(environment); self.environment = nil }
    }
    private func vector(_ text: String) throws -> [Float] {
        let ids = try tokenizer.encode(text: text, maxTokens: 128)
        guard (2...128).contains(ids.count), ids.first == 2, ids.last == 1,
            ids.allSatisfy({ $0 >= 0 && $0 < 262144 && !GemmaBPETokenizer.mediaIDs.contains($0) }) else { throw WindowsError.unsupported("This text cannot be processed by the text-only local model.") }
        let data = UnsafeMutableRawPointer.allocate(byteCount: ids.count * 16 + 16, alignment: MemoryLayout<Int64>.alignment)
        defer { data.deallocate() }
        let tokens = data.assumingMemoryBound(to: Int64.self), mask = tokens.advanced(by: ids.count)
        for index in ids.indices { tokens[index] = ids[index]; mask[index] = 1 }
        var tokenValue: OpaquePointer?, maskValue: OpaquePointer?, mediaValue: OpaquePointer?
        defer { for value in [tokenValue, maskValue, mediaValue] { if let value { api.ReleaseValue(value) } } }
        let shape: [Int64] = [1, Int64(ids.count)], empty: [Int64] = [0,512]
        try shape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, tokens, ids.count * 8, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tokenValue)) }
        try shape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, mask, ids.count * 8, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &maskValue)) }
        try empty.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, data.advanced(by: ids.count * 16), 0, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &mediaValue)) }
        let names = ["input_ids", "attention_mask", "image_features", "video_features", "audio_features"]
        var namePointers: [UnsafePointer<CChar>?] = [], nameMemory: [UnsafeMutableRawPointer] = []
        defer { nameMemory.forEach { $0.deallocate() } }
        for name in names {
            let bytes = Array(name.utf8) + [0]
            let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
            let characters = storage.assumingMemoryBound(to: UInt8.self)
            for index in bytes.indices { characters[index] = bytes[index] }
            nameMemory.append(storage); namePointers.append(UnsafePointer(storage.assumingMemoryBound(to: CChar.self)))
        }
        let values = [tokenValue, maskValue, mediaValue, mediaValue, mediaValue]
        var output: OpaquePointer?
        defer { if let output { api.ReleaseValue(output) } }
        try namePointers.withUnsafeBufferPointer { names in
            try values.withUnsafeBufferPointer { values in
                try "sentence_embedding".withCString { name in
                    var name: UnsafePointer<CChar>? = name
                    try check(api.Run(session, nil, names.baseAddress, values.baseAddress, 5, &name, 1, &output))
                }
            }
        }
        var information: OpaquePointer?
        try check(api.GetTensorTypeAndShape(output, &information))
        defer { if let information { api.ReleaseTensorTypeAndShapeInfo(information) } }
        var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        var dimensions = 0, count = 0
        try check(api.GetTensorElementType(information, &type)); try check(api.GetDimensionsCount(information, &dimensions)); try check(api.GetTensorShapeElementCount(information, &count))
        guard type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, dimensions == 2, count == 768 else { throw WindowsError.unsupported("The local model returned an unexpected result.") }
        var outputShape: [Int64] = [0,0]
        try outputShape.withUnsafeMutableBufferPointer { try check(api.GetDimensions(information, $0.baseAddress, 2)) }
        guard outputShape == [1,768] else { throw WindowsError.unsupported("The local model returned an unexpected result shape.") }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        guard let raw else { throw WindowsError.unsupported("The local model returned no result.") }
        let full = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: 768)
        guard full.allSatisfy(\.isFinite) else { throw WindowsError.unsupported("The local model returned invalid numbers.") }
        let fullNorm = full.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard (0.9...1.1).contains(fullNorm) else { throw WindowsError.unsupported("The local model returned an invalid embedding.") }
        var result = Array(full.prefix(128))
        let norm = result.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm.isFinite, norm > 0.000001 else { throw WindowsError.unsupported("The local model returned an empty embedding.") }
        for index in result.indices { result[index] /= Float(norm) }
        return result
    }
    private func documentVector(_ document: NativeEmbeddingDocument) throws -> [Float] {
        let text = GemmaBPETokenizer.document(title: document.title, content: document.text)
        let bytes = Array(text.utf8)
        var cursor = 0
        let digest = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, bytes.count - cursor)
            buffer.copyBytes(from: bytes[cursor..<(cursor + count)])
            cursor += count; return count
        }
        let key = digest.map { let value = String($0, radix: 16); return value.count == 1 ? "0" + value : value }.joined()
        if let value = documents[key] { return value }
        let value = try vector(text)
        if order.count == 64 { documents.removeValue(forKey: order.removeFirst()) }
        order.append(key); documents[key] = value
        return value
    }
    private static func score(_ left: [Float], _ right: [Float]) -> Float {
        Float(zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) })
    }
    /// Ready follows real tokenizer, vector and retrieval checks, rather than file presence.
    func validateInference() throws {
        guard try tokenizer.encode(text: GemmaBPETokenizer.query("find my dog"), maxTokens: 128) == [2,8071,236787,3927,1354,1109,7609,236787,1586,1041,4799,1] else { throw WindowsError.unsupported("The local tokenizer is incompatible with the search model.") }
        let query = try vector(GemmaBPETokenizer.query("find my dog"))
        let dog = try documentVector(.init(id: "dog", title: "", text: "A dog is playing in the park."))
        let math = try documentVector(.init(id: "math", title: "", text: "Linear algebra studies matrices and vector spaces."))
        guard Self.score(query, dog) > Self.score(query, math) + 0.05 else { throw WindowsError.unsupported("The local model did not pass its retrieval check. Text search remains available.") }
    }
    func rank(query: String, documents: [NativeEmbeddingDocument], progress: (String) throws -> Void) throws -> [(Int, Float)] {
        guard !query.isEmpty, query.utf8.count <= 4096, (1...8).contains(documents.count), documents.allSatisfy({ $0.title.utf8.count <= 4096 && $0.text.utf8.count <= 65536 }) else { throw WindowsError.unsupported("The local search request exceeds its text budget.") }
        try progress("Comparing local document meanings…")
        let queryVector: [Float]
        if let cached = lastQuery, cached.text.utf8.elementsEqual(query.utf8) { queryVector = cached.vector }
        else { queryVector = try vector(GemmaBPETokenizer.query(query)); lastQuery = (query, queryVector) }
        var result: [(Int, Float)] = []
        for (index, document) in documents.enumerated() {
            try progress("Comparing local document \(index + 1) of \(documents.count)…")
            let score = Self.score(queryVector, try documentVector(document))
            guard score.isFinite, (-1.001...1.001).contains(score) else { throw WindowsError.unsupported("The local model returned an invalid score.") }
            result.append((index, score))
        }
        return result.sorted { $0.1 > $1.1 }
    }
    deinit { dispose(); FreeLibrary(library) }
}
