// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK
import WindowsDisplayABI

struct NativeSearchModelDescriptor: Sendable {
    enum Adapter: String, Sendable { case gemmaBPE, bertWordPiece }
    let repositoryID: String
    let revision: String
    let adapter: Adapter
    let dimensions: Int
    let tokenLimit: Int
    let graph: NativeEmbeddingAsset
    let tokenizer: NativeEmbeddingAsset
    let weights: NativeEmbeddingAsset?
    var assets: [NativeEmbeddingAsset] { [tokenizer, graph] + (weights.map { [$0] } ?? []) }
    // Include preprocessing and pooling versions: vectors from different pipelines never share an index.
    var fingerprint: String {
        repositoryID + "@" + revision + ":" + adapter.rawValue + ":v1:" + String(dimensions)
            + ":" + String(tokenLimit) + ":" + graph.sha256
    }
    static var recommended: Self {
        .init(repositoryID: "onnx-community/embeddinggemma-2-ONNX",
            revision: "daa72c51243991dfcaf9f9137d2c573d8f7790c0", adapter: .gemmaBPE,
            dimensions: 128, tokenLimit: 128, graph: NativeEmbeddingAssets.graph,
            tokenizer: NativeEmbeddingAssets.tokenizer, weights: NativeEmbeddingAssets.weights)
    }
    static let miniLM: Self = {
        let id = "sentence-transformers/all-MiniLM-L6-v2"
        let revision = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
        let route = "/" + id + "/resolve/" + revision + "/"
        return .init(repositoryID: id, revision: revision, adapter: .bertWordPiece,
            dimensions: 384, tokenLimit: 128,
            graph: .init(name: "model.onnx", host: "huggingface.co", remotePath: route + "onnx/model.onnx",
                bytes: 90405214, sha256: "6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452"),
            tokenizer: .init(name: "vocab.txt", host: "huggingface.co", remotePath: route + "vocab.txt",
                bytes: 231508, sha256: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"),
            weights: nil)
    }()
}

struct NativeSearchModelCandidate: Sendable {
    let repositoryID: String
    let reason: String?
}

enum NativeSearchModelCatalog {
    static var builtIns: [NativeSearchModelDescriptor] { [.recommended, .miniLM] }
    static func validRepositoryID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && id.utf8.count <= 192 && parts.allSatisfy { part in
            !part.isEmpty && part.first != "." && part.last != "." && !part.containsText("..")
                && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
    }
    static func digest(_ text: String) throws -> String {
        let bytes = Array(text.utf8); var offset = 0
        let hash = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, bytes.count - offset)
            buffer.copyBytes(from: bytes[offset..<offset + count]); offset += count
            return count
        }
        return hash.map { let value = String($0, radix: 16); return value.count == 1 ? "0" + value : value }.joined()
    }
    private static func manifestPath(_ id: String) throws -> String {
        try NativeFiles.path("SearchModel-" + digest(id) + ".catalog")
    }
    static func descriptor(repositoryID: String) throws -> NativeSearchModelDescriptor {
        try descriptor(repositoryID: repositoryID, readManifest: {
            let path = try manifestPath(repositoryID)
            guard try NativeFiles.exists(path) else { return nil }
            try NativeEmbeddingAssets.inspect(path, directory: false)
            return try NativeFiles.read(path, maximum: 4096)
        })
    }
    private static func descriptor(repositoryID: String,
        readManifest: () throws -> [UInt8]?) throws -> NativeSearchModelDescriptor {
        guard validRepositoryID(repositoryID) else { throw WindowsError.unsupported("Enter a public Hugging Face repository ID in owner/model form.") }
        if let known = builtIns.first(where: { $0.repositoryID == repositoryID }) { return known }
        guard let bytes = try readManifest() else {
            throw WindowsError.unsupported("Refresh this model from Hugging Face before selecting it.")
        }
        let rows = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard rows.count == 4, rows[0] == repositoryID, hex(rows[1], count: 40),
            let size = UInt64(rows[2]), (1...120_000_000).contains(size), hex(rows[3], count: 64) else {
            throw WindowsError.unsupported("Refresh this model from Hugging Face before selecting it.")
        }
        return bertDescriptor(id: repositoryID, revision: rows[1], bytes: size, hash: rows[3])
    }
    private static func hex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func bertDescriptor(id: String, revision: String, bytes: UInt64, hash: String) -> NativeSearchModelDescriptor {
        let route = "/" + id + "/resolve/" + revision + "/"
        return .init(repositoryID: id, revision: revision, adapter: .bertWordPiece,
            dimensions: 384, tokenLimit: 128,
            graph: .init(name: "model.onnx", host: "huggingface.co", remotePath: route + "onnx/model.onnx", bytes: bytes, sha256: hash),
            tokenizer: .init(name: "vocab.txt", host: "huggingface.co", remotePath: route + "vocab.txt",
                bytes: NativeSearchModelDescriptor.miniLM.tokenizer.bytes, sha256: NativeSearchModelDescriptor.miniLM.tokenizer.sha256),
            weights: nil)
    }
    static func parse(_ bytes: [UInt8]) throws -> SmallJSON {
        try bytes.withUnsafeBufferPointer { pointer in
            var reader = TokenizerJSONReader(bytes: pointer)
            let result = try reader.smallValue(); reader.whitespace()
            guard reader.offset == pointer.count else { throw TokenizerFailure("Unexpected trailing model metadata") }
            return result
        }
    }
    /// This sends only the repository ID; user queries, filenames and document contents stay local.
    static func resolve(repositoryID id: String, cancelled: @Sendable () -> Bool = { false }) throws -> NativeSearchModelDescriptor {
        guard validRepositoryID(id) else { throw WindowsError.unsupported("Enter a public Hugging Face repository ID in owner/model form.") }
        let pinned = builtIns.first(where: { $0.repositoryID == id })
        let route = "/api/models/" + id + (pinned.map { "/revision/" + $0.revision } ?? "") + "?blobs=true"
        let metadata = try parse(fetch(route, cancelled: cancelled))
        guard metadata["id"]?.string == id, metadata["private"]?.bool != true,
            metadata["gated"]?.bool == false, let revision = metadata["sha"]?.string,
            hex(revision, count: 40), metadata["cardData"]?["license"]?.string == "apache-2.0" else {
            throw WindowsError.unsupported("This model must be public, ungated and Apache-2.0 licensed for this native adapter.")
        }
        let siblings = metadata["siblings"]?.array ?? []
        if let known = builtIns.first(where: { $0.repositoryID == id && $0.revision == revision }) {
            for asset in known.assets {
                let route = "/" + id + "/resolve/" + revision + "/"
                guard siblings.contains(where: { $0["rfilename"]?.string == String(asset.remotePath.dropFirst(route.count)) }) else {
                    throw WindowsError.unsupported("The published model files have changed. Retry after updating SwiftyToys.")
                }
            }
            return known
        }
        let modelRoute = "/" + id + "/resolve/" + revision + "/"
        let config = try parse(fetch(modelRoute + "config.json", cancelled: cancelled))
        let pooling = try parse(fetch(modelRoute + "1_Pooling/config.json", cancelled: cancelled))
        let tokenizer = try fetch(modelRoute + "tokenizer_config.json", cancelled: cancelled)
        let tokenConfig = try parse(tokenizer)
        guard config["model_type"]?.string == "bert", config["hidden_size"]?.integer == 384,
            config["vocab_size"]?.integer == 30522, config["num_hidden_layers"]?.integer == 6,
            config["max_position_embeddings"]?.integer == 512, config["auto_map"] == nil,
            pooling["pooling_mode_mean_tokens"]?.bool == true,
            pooling["pooling_mode_cls_token"]?.bool == false,
            pooling["pooling_mode_max_tokens"]?.bool == false,
            pooling["pooling_mode_mean_sqrt_len_tokens"]?.bool == false,
            tokenConfig["do_lower_case"]?.bool == true, tokenConfig["auto_map"] == nil,
            let graph = siblings.first(where: { $0["rfilename"]?.string == "onnx/model.onnx" }),
            let size = graph["lfs"]?["size"]?.integer, (1...120_000_000).contains(size),
            let hash = graph["lfs"]?["sha256"]?.string, hex(hash, count: 64) else {
            throw WindowsError.unsupported("Unsupported native model. Choose EmbeddingGemma2 or a 384-dimensional MiniLM BERT ONNX model with mean pooling; Python and custom code are not supported.")
        }
        let vocab = try fetch(modelRoute + "vocab.txt", cancelled: cancelled)
        let pipeline = try fetch(modelRoute + "tokenizer.json", cancelled: cancelled)
        guard UInt64(vocab.count) == NativeSearchModelDescriptor.miniLM.tokenizer.bytes,
            try digest(String(decoding: vocab, as: UTF8.self)) == NativeSearchModelDescriptor.miniLM.tokenizer.sha256,
            pipeline.count == 466247,
            try digest(String(decoding: pipeline, as: UTF8.self)) == "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037" else {
            throw WindowsError.unsupported("This model uses an unsupported tokenizer. Choose a standard uncased MiniLM vocabulary.")
        }
        let result = bertDescriptor(id: id, revision: revision, bytes: UInt64(size), hash: hash)
        try NativeEmbeddingAssets.cancelled(cancelled)
        let directory = try NativeFiles.directory()
        try NativeFiles.createDirectory(directory)
        try NativeEmbeddingAssets.inspect(directory, directory: true)
        try NativeFiles.write(Array((id + "\n" + revision + "\n" + String(size) + "\n" + hash + "\n").utf8), to: manifestPath(id))
        return result
    }
    static func search(_ text: String, cancelled: @Sendable () -> Bool = { false }) throws -> [NativeSearchModelCandidate] {
        guard text.utf8.count <= 192 else { throw WindowsError.unsupported("The model search text is too long.") }
        let encoded = text.utf8.map { byte -> String in
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95].contains(byte) { return String(Unicode.Scalar(byte)) }
            let value = String(byte, radix: 16, uppercase: true); return "%" + (value.count == 1 ? "0" : "") + value
        }.joined()
        let results = try parse(fetch("/api/models?search=" + encoded + "&filter=onnx&limit=20&sort=downloads&direction=-1", cancelled: cancelled))
        return (results.array ?? []).compactMap { item in
            guard let id = item["id"]?.string, validRepositoryID(id) else { return nil }
            return .init(repositoryID: id, reason: builtIns.contains(where: { $0.repositoryID == id }) ? nil : "Check compatibility before downloading")
        }
    }
    private static func fetch(_ route: String, cancelled: @Sendable () -> Bool) throws -> [UInt8] {
        try NativeEmbeddingAssets.cancelled(cancelled)
        guard let session = withWideString("SwiftyToys model catalog", { WinHttpOpen($0, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) }) else { throw WindowsError.api("Open model catalog", GetLastError()) }
        defer { WinHttpCloseHandle(session) }
        guard WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000) else { throw WindowsError.api("Set model catalog deadline", GetLastError()) }
        guard let connection = withWideString("huggingface.co", { WinHttpConnect(session, $0, INTERNET_PORT(443), 0) }) else { throw WindowsError.api("Connect to Hugging Face", GetLastError()) }
        defer { WinHttpCloseHandle(connection) }
        guard let request = withWideString(route, { WinHttpOpenRequest(connection, nil, $0, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) }) else { throw WindowsError.api("Open model catalog request", GetLastError()) }
        defer { WinHttpCloseHandle(request) }
        var policy = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP)
        guard WinHttpSetOption(request, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &policy, 4),
            WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0), WinHttpReceiveResponse(request, nil) else { throw WindowsError.api("Read Hugging Face model metadata", GetLastError()) }
        var code: DWORD = 0, length: DWORD = 4
        guard WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &code, &length, nil), code == 200 else {
            throw WindowsError.unsupported("The public Hugging Face model is unavailable. Check the ID and connection, then retry.")
        }
        var result: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = GetTickCount64() + 15000
        while true {
            try NativeEmbeddingAssets.cancelled(cancelled)
            var count: DWORD = 0
            guard GetTickCount64() < deadline, WinHttpReadData(request, &buffer, DWORD(buffer.count), &count),
                count <= buffer.count, result.count + Int(count) <= 1_048_576 else {
                throw WindowsError.unsupported("The model catalog exceeded its time or metadata size limit.")
            }
            if count == 0 { return result }
            result += buffer.prefix(Int(count))
        }
    }
    static func selfCheck() throws {
        for id in ["owner/model", "sentence-transformers/all-MiniLM-L6-v2"] {
            guard validRepositoryID(id) else { throw TokenizerFailure("Valid model ID was rejected") }
        }
        for id in ["", "model", "owner/model/other", "../model", "owner/..model", "owner/model?token=x", "owner\\model", "owner/model\n"] {
            guard !validRepositoryID(id) else { throw TokenizerFailure("Unsafe model ID was accepted") }
        }
        let json = try parse(Array("{\"score\":1.25e-3,\"size\":512,\"ok\":false}".utf8))
        guard json["size"]?.integer == 512, json["ok"]?.bool == false else { throw TokenizerFailure("Model metadata number parsing failed") }
        for malformed in ["01", "1.", "1e", "1e+", "1e999", "--1", "{}x"] {
            var rejected = false
            do { _ = try parse(Array(malformed.utf8)) } catch { rejected = true }
            guard rejected else { throw TokenizerFailure("Model catalog accepted invalid JSON") }
        }
        guard recommendedIdentityDistinct() else { throw TokenizerFailure("Model index namespaces overlap") }
        let mini = NativeSearchModelDescriptor.miniLM
        let staleManifest = Array((mini.repositoryID + "\n" + String(repeating: "a", count: 40)
            + "\n90405214\n" + String(repeating: "b", count: 64) + "\n").utf8)
        var readStaleManifest = false
        let selected = try descriptor(repositoryID: mini.repositoryID, readManifest: {
            readStaleManifest = true; return staleManifest
        })
        guard selected.fingerprint == mini.fingerprint, !readStaleManifest else {
            throw TokenizerFailure("A stale catalog manifest overrode a pinned builtin model")
        }
        try BertWordPieceTokenizer.selfCheck()
        try NativeEmbeddingGraphPolicy.selfCheck()
        Console.writeLine("PASS: native model catalog IDs, metadata bounds, WordPiece Unicode/segmentation/truncation and ONNX graph trust policy; no network or model inference")
    }
    private static func recommendedIdentityDistinct() -> Bool {
        NativeSearchModelDescriptor.recommended.fingerprint != NativeSearchModelDescriptor.miniLM.fingerprint
    }
}
