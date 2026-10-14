// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import EmbeddingABI

/// This object exists only in the isolated embedding child, never in UI or input callbacks.
final class NativeEmbeddingEngine {
    private let runtimeFile: NativeEmbeddingFile
    private let graphFile: NativeEmbeddingFile
    private let weightFile: NativeEmbeddingFile?
    private let directory: OwnedHandle
    private let library: HMODULE
    private let api: OrtApi
    let model: NativeSearchModelDescriptor
    private let tokenizer: GemmaBPETokenizer?
    private let wordPiece: BertWordPieceTokenizer?
    private var environment: OpaquePointer?, options: OpaquePointer?, session: OpaquePointer?, memory: OpaquePointer?
    private var documents: [String: [Float]] = [:]
    private var order: [String] = []
    private var lastQuery: (text: String, vector: [Float])?

    var ortAPI: OrtApi { api }
    var ortEnvironment: OpaquePointer? { environment }
    var ortOptions: OpaquePointer? { options }
    var ortMemory: OpaquePointer? { memory }
    init(assetDirectory: String? = nil, model: NativeSearchModelDescriptor = .recommended) throws {
        guard NativeEmbeddingAssets.supported() else { throw WindowsError.unsupported("Local semantic search requires Windows10 version1903 or newer.") }
        self.model = model
        let root = try assetDirectory ?? NativeEmbeddingAssets.directory(model: model)
        try NativeEmbeddingAssets.inspect(root, directory: true)
        directory = try OwnedHandle(withWideString(try NativeFiles.windowsPath(root)) { CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil) })
        runtimeFile = try NativeEmbeddingFile(root + "\\" + NativeEmbeddingAssets.runtime.name, asset: NativeEmbeddingAssets.runtime)
        graphFile = try NativeEmbeddingFile(root + "\\" + model.graph.name, asset: model.graph)
        weightFile = try model.weights.map { try NativeEmbeddingFile(root + "\\" + $0.name, asset: $0) }
        let runtimePath = root + "\\" + NativeEmbeddingAssets.runtime.name
        try NativeDriverTrust.verifySignature(runtimePath, signer: .microsoftWindows, fileHandle: runtimeFile.raw)
        tokenizer = model.adapter == .gemmaBPE ? try GemmaBPETokenizer(path: root + "\\" + model.tokenizer.name) : nil
        wordPiece = model.adapter == .bertWordPiece ? try BertWordPieceTokenizer(path: root + "\\" + model.tokenizer.name) : nil
        if model.adapter == .bertWordPiece { try NativeEmbeddingGraphPolicy.validate(root + "\\" + model.graph.name) }
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
            try withWideString(NativeFiles.windowsPath(root + "\\" + model.graph.name)) { try check(api.CreateSession(environment, $0, options, &session)) }
        }
    }
    func check(_ status: OpaquePointer?) throws {
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
    func vector(_ text: String, imageFeatures: [Float] = [], videoFeatures: [Float] = [], audioFeatures: [Float] = []) throws -> [Float] {
        let features = [imageFeatures, videoFeatures, audioFeatures]
        let hasMedia = features.contains { !$0.isEmpty }
        guard features.allSatisfy({ $0.count <= 512 * 8192 && $0.count % 512 == 0 && $0.allSatisfy(\.isFinite) }),
            !hasMedia || model.adapter == .gemmaBPE else { throw WindowsError.unsupported("Invalid or unsupported local media features.") }
        let ids: [Int64]
        let tokenBudget = hasMedia ? 1024 : model.tokenLimit
        if let tokenizer {
            ids = hasMedia ? try tokenizer.encodePrimaryFixture(text: text, maxTokens: tokenBudget) : try tokenizer.encode(text: text, maxTokens: tokenBudget)
            guard ids.first == 2, ids.last == 1, ids.allSatisfy({ $0 >= 0 && $0 < 262144 }) else { throw WindowsError.unsupported("The local model received invalid tokens.") }
            if hasMedia {
                for (index, token) in [Int64(258880),258884,258881].enumerated() {
                    guard ids.filter({ $0 == token }).count == features[index].count / 512 else {
                        throw WindowsError.unsupported("The local media token count does not match its encoded features.")
                    }
                }
                guard (ids.contains(255999) == (!imageFeatures.isEmpty || !videoFeatures.isEmpty)),
                    (ids.contains(256000) == !audioFeatures.isEmpty),
                    (ids.contains(258882) == (!imageFeatures.isEmpty || !videoFeatures.isEmpty)),
                    (ids.contains(258883) == !audioFeatures.isEmpty) else {
                    throw WindowsError.unsupported("The local media delimiters do not match its encoded features.")
                }
            }
        } else if let wordPiece { ids = try wordPiece.encode(text: text, maxTokens: model.tokenLimit) }
        else { throw WindowsError.unsupported("The local model has no supported tokenizer.") }
        guard (2...tokenBudget).contains(ids.count) else { throw WindowsError.unsupported("The local model received an invalid token count.") }
        let mediaBytes = features.reduce(0) { $0 + $1.count * 4 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: ids.count * 24 + mediaBytes + 16, alignment: MemoryLayout<Int64>.alignment)
        defer { data.deallocate() }
        let tokens = data.assumingMemoryBound(to: Int64.self), mask = tokens.advanced(by: ids.count), segments = mask.advanced(by: ids.count)
        for index in ids.indices { tokens[index] = ids[index]; mask[index] = 1; segments[index] = 0 }
        var tokenValue: OpaquePointer?, maskValue: OpaquePointer?
        var additional: [OpaquePointer?] = []
        defer { for value in [tokenValue, maskValue] + additional { if let value { api.ReleaseValue(value) } } }
        let shape: [Int64] = [1, Int64(ids.count)]
        try shape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, tokens, ids.count * 8, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tokenValue)) }
        try shape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, mask, ids.count * 8, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &maskValue)) }
        if model.adapter == .gemmaBPE {
            var offset = ids.count * 24
            for feature in features {
                let pointer = data.advanced(by: offset).assumingMemoryBound(to: Float.self)
                for index in feature.indices { pointer[index] = feature[index] }
                var value: OpaquePointer?
                let mediaShape: [Int64] = [Int64(feature.count / 512), 512]
                try mediaShape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, pointer, feature.count * 4, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value)) }
                additional.append(value); offset += feature.count * 4
            }
        } else {
            var value: OpaquePointer?
            try shape.withUnsafeBufferPointer { try check(api.CreateTensorWithDataAsOrtValue(memory, segments, ids.count * 8, $0.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &value)) }
            additional.append(value)
        }
        let names = model.adapter == .gemmaBPE ? ["input_ids", "attention_mask", "image_features", "video_features", "audio_features"] : ["input_ids", "attention_mask", "token_type_ids"]
        var namePointers: [UnsafePointer<CChar>?] = [], nameMemory: [UnsafeMutableRawPointer] = []
        defer { nameMemory.forEach { $0.deallocate() } }
        for name in names {
            let bytes = Array(name.utf8) + [0]
            let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
            let characters = storage.assumingMemoryBound(to: UInt8.self)
            for index in bytes.indices { characters[index] = bytes[index] }
            nameMemory.append(storage); namePointers.append(UnsafePointer(storage.assumingMemoryBound(to: CChar.self)))
        }
        let values = [tokenValue, maskValue] + additional
        var output: OpaquePointer?
        defer { if let output { api.ReleaseValue(output) } }
        try namePointers.withUnsafeBufferPointer { names in
            try values.withUnsafeBufferPointer { values in
                try (model.adapter == .gemmaBPE ? "sentence_embedding" : "last_hidden_state").withCString { name in
                    var name: UnsafePointer<CChar>? = name
                    try check(api.Run(session, nil, names.baseAddress, values.baseAddress, values.count, &name, 1, &output))
                }
            }
        }
        var information: OpaquePointer?
        try check(api.GetTensorTypeAndShape(output, &information))
        defer { if let information { api.ReleaseTensorTypeAndShapeInfo(information) } }
        var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        var dimensions = 0, count = 0
        try check(api.GetTensorElementType(information, &type)); try check(api.GetDimensionsCount(information, &dimensions)); try check(api.GetTensorShapeElementCount(information, &count))
        let expected: [Int64] = model.adapter == .gemmaBPE ? [1,768] : [1, Int64(ids.count), 384]
        guard type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, dimensions == expected.count,
            count == expected.reduce(1, { $0 * Int($1) }) else { throw WindowsError.unsupported("The local model returned an unexpected result.") }
        var outputShape = [Int64](repeating: 0, count: dimensions)
        try outputShape.withUnsafeMutableBufferPointer { try check(api.GetDimensions(information, $0.baseAddress, dimensions)) }
        guard outputShape == expected else { throw WindowsError.unsupported("The local model returned an unexpected result shape.") }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        guard let raw else { throw WindowsError.unsupported("The local model returned no result.") }
        let full = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count)
        guard full.allSatisfy(\.isFinite) else { throw WindowsError.unsupported("The local model returned invalid numbers.") }
        var result: [Float]
        if model.adapter == .gemmaBPE {
            let fullNorm = full.reduce(0.0) { $0 + Double($1) * Double($1) }
            guard (0.9...1.1).contains(fullNorm) else { throw WindowsError.unsupported("The local model returned an invalid embedding.") }
            result = Array(full.prefix(model.dimensions))
        } else {
            // A single unpadded document has an all-one mask; mean-pool every token including CLS/SEP.
            result = (0..<384).map { dimension in
                Float((0..<ids.count).reduce(0.0) { $0 + Double(full[$1 * 384 + dimension]) } / Double(ids.count))
            }
        }
        let norm = result.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm.isFinite, norm > 0.000001 else { throw WindowsError.unsupported("The local model returned an empty embedding.") }
        for index in result.indices { result[index] /= Float(norm) }
        return result
    }
    /// Split indexed text without dropping the part beyond the model's token window.
    func documentSegments(_ text: String) throws -> [String] {
        guard !text.isEmpty, text.utf8.count <= 60_000 else {
            throw WindowsError.unsupported("The document fragment exceeds its text budget.")
        }
        func fits(_ value: String) throws -> Bool {
            if let tokenizer {
                return try tokenizer.encode(text: GemmaBPETokenizer.document(title: "", content: value),
                    maxTokens: model.tokenLimit + 1).count <= model.tokenLimit
            }
            guard let wordPiece else { throw WindowsError.unsupported("The document tokenizer is unavailable.") }
            return try wordPiece.encode(text: value, maxTokens: model.tokenLimit + 1).count <= model.tokenLimit
        }
        if try fits(text) { return [text] }
        let characters = Array(text.unicodeScalars)
        var offset = 0, result: [String] = []
        while offset < characters.count {
            guard result.count < 256 else { throw WindowsError.unsupported("Document segmentation exceeds its fragment budget.") }
            var low = 1, high = characters.count - offset, accepted = 0
            while low <= high {
                let count = low + (high - low) / 2
                if try fits(String(String.UnicodeScalarView(characters[offset..<(offset + count)]))) {
                    accepted = count; low = count + 1
                } else { high = count - 1 }
            }
            guard accepted > 0 else { throw WindowsError.unsupported("A text character exceeds the model's token window.") }
            result.append(String(String.UnicodeScalarView(characters[offset..<(offset + accepted)])))
            offset += accepted
        }
        return result
    }
    func documentVector(_ document: NativeEmbeddingDocument) throws -> [Float] {
        guard document.title.utf8.count <= 4096, document.text.utf8.count <= 65536 else { throw WindowsError.unsupported("The local document exceeds its text budget.") }
        let text = model.adapter == .gemmaBPE ? GemmaBPETokenizer.document(title: document.title, content: document.text) : (document.title.isEmpty ? document.text : document.title + "\n" + document.text)
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
        if let tokenizer {
            guard try tokenizer.encode(text: GemmaBPETokenizer.query("find my dog"), maxTokens: model.tokenLimit) == [2,8071,236787,3927,1354,1109,7609,236787,1586,1041,4799,1] else { throw WindowsError.unsupported("The local tokenizer is incompatible with the search model.") }
        } else {
            guard try wordPiece?.encode(text: "find my dog") == [101,2424,2026,3899,102] else { throw WindowsError.unsupported("The local WordPiece tokenizer is incompatible with the search model.") }
        }
        let longText = String(repeating: "Watering gardens in summer keeps the roots healthy. 🌿\n", count: 45)
        let segments = try documentSegments(longText)
        guard segments.count > 1, segments.joined(separator: "") == longText,
            try segments.allSatisfy({ try documentSegments($0) == [$0] }) else {
            throw WindowsError.unsupported("Document token windows lost text or exceeded the model limit.")
        }
        let combined = "a" + String(repeating: "\u{0301}", count: 180)
        guard try documentSegments(combined).joined(separator: "").utf8.elementsEqual(combined.utf8) else {
            throw WindowsError.unsupported("Unicode scalar windows lost a long combining sequence.")
        }
        let query = try queryVector("find my dog")
        let dog = try documentVector(.init(id: "dog", title: "", text: "A dog is playing in the park."))
        let math = try documentVector(.init(id: "math", title: "", text: "Linear algebra studies matrices and vector spaces."))
        guard Self.score(query, dog) > Self.score(query, math) + 0.05 else { throw WindowsError.unsupported("The local model did not pass its retrieval check. Text search remains available.") }
    }
    func queryVector(_ query: String) throws -> [Float] {
        guard !query.isEmpty, query.utf8.count <= 4096 else { throw WindowsError.unsupported("The local query exceeds its text budget.") }
        if let cached = lastQuery, cached.text.utf8.elementsEqual(query.utf8) { return cached.vector }
        let value = try vector(model.adapter == .gemmaBPE ? GemmaBPETokenizer.query(query) : query)
        lastQuery = (query, value)
        return value
    }
    func rank(query: String, documents: [NativeEmbeddingDocument], progress: (String) throws -> Void) throws -> [(Int, Float)] {
        guard !query.isEmpty, query.utf8.count <= 4096, (1...8).contains(documents.count), documents.allSatisfy({ $0.title.utf8.count <= 4096 && $0.text.utf8.count <= 65536 }) else { throw WindowsError.unsupported("The local search request exceeds its text budget.") }
        try progress("Comparing local document meanings…")
        let queryVector = try queryVector(query)
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
