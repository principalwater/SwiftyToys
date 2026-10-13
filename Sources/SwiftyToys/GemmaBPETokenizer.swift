// SPDX-License-Identifier: MIT
import WinSDK

final class GemmaBPETokenizer {
    static let expectedSize = 32_170_510
    static let expectedSHA256 = "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"
    private struct TokenKey: Hashable {
        // BPE uses exact UTF-8 bytes; Swift String equality folds canonical Unicode equivalents.
        let text: String
        init(_ text: String) { self.text = text }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.utf8.elementsEqual(rhs.text.utf8) }
        func hash(into hasher: inout Hasher) {
            var text = text
            text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }
    private struct Merge { let rank: Int; let result: Int64 }
    private struct Added { let bytes: [UInt8]; let id: Int64 }
    private struct Symbol { var id: Int64; var previous: Int; var next: Int; var generation = 0; var live = true }
    private struct Candidate { let rank: Int; let left: Int; let right: Int; let generation: Int; let result: Int64 }
    private struct Heap {
        var values: [Candidate] = []
        private func before(_ lhs: Candidate, _ rhs: Candidate) -> Bool { lhs.rank < rhs.rank || lhs.rank == rhs.rank && lhs.left < rhs.left }
        mutating func push(_ value: Candidate) {
            values.append(value); var index = values.count - 1
            while index > 0 { let parent = (index - 1) / 2; if !before(values[index], values[parent]) { break }; values.swapAt(index, parent); index = parent }
        }
        mutating func pop() -> Candidate? {
            guard !values.isEmpty else { return nil }
            let result = values[0], last = values.removeLast()
            if !values.isEmpty {
                values[0] = last; var index = 0
                while index * 2 + 1 < values.count {
                    var child = index * 2 + 1
                    if child + 1 < values.count, before(values[child + 1], values[child]) { child += 1 }
                    if !before(values[child], values[index]) { break }
                    values.swapAt(child, index); index = child
                }
            }
            return result
        }
    }
    private var vocabulary: [TokenKey: Int64] = [:]
    private var merges: [UInt64: Merge] = [:]
    private var addedByFirst: [UInt8: [Added]] = [:]
    private var fallback: [Int64] = []
    static let mediaIDs: Set<Int64> = [255999, 256000, 258880, 258881, 258882, 258883, 258884]
    var vocabularyCount: Int { vocabulary.count }
    var mergeCount: Int { merges.count }
    private static func pair(_ lhs: Int64, _ rhs: Int64) -> UInt64 { UInt64(lhs) << 32 | UInt64(rhs) }

    /// Load once on the optional model worker; file hashing/parsing never belongs on a UI/input thread.
    init(path: String) throws {
        let mapped = try TokenizerMappedJSON(path: path)
        defer { withExtendedLifetime(mapped) {} }
        guard mapped.bytes.count == Self.expectedSize else { throw TokenizerFailure("Tokenizer file does not match the pinned model") }
        var remaining = mapped.bytes[...]
        let digest = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, remaining.count)
            buffer.copyBytes(from: remaining.prefix(count)); remaining = remaining.dropFirst(count)
            return count
        }
        guard NativeDriverTrust.hashMatches(digest, expected: Self.expectedSHA256) else { throw TokenizerFailure("Tokenizer SHA-256 does not match the pinned model") }
        var reader = TokenizerJSONReader(bytes: mapped.bytes), metadata: [String: SmallJSON] = [:]
        var seenIDs = [Bool](repeating: false, count: 262144)
        try reader.require(123)
        repeat {
            let key = try reader.string(); try reader.require(58)
            if key == "model" {
                try reader.require(123)
                repeat {
                    let field = try reader.string(); try reader.require(58)
                    if field == "vocab" {
                        vocabulary.reserveCapacity(262144); try reader.require(123)
                        repeat {
                            let token = try reader.string(); try reader.require(58); let id = try reader.integer()
                            guard (0..<262144).contains(id), !seenIDs[id], vocabulary.count < 262144, vocabulary.updateValue(Int64(id), forKey: TokenKey(token)) == nil else { throw TokenizerFailure("Invalid vocabulary entry") }
                            seenIDs[id] = true
                        } while reader.consume(44)
                        try reader.require(125)
                    } else if field == "merges" {
                        guard vocabulary.count == 262144 else { throw TokenizerFailure("Pinned tokenizer vocabulary must precede merge ranks") }
                        merges.reserveCapacity(262144); try reader.require(91); var rank = 0
                        if !reader.consume(93) {
                            repeat {
                                let left: String, right: String
                                if reader.consume(91) { left = try reader.string(); try reader.require(44); right = try reader.string(); try reader.require(93) }
                                else {
                                    let value = try reader.string()
                                    guard let separator = value.firstIndex(of: " ") else { throw TokenizerFailure("Invalid BPE merge row") }
                                    left = String(value[..<separator]); right = String(value[value.index(after: separator)...])
                                }
                                guard rank < 1_000_000, let lhs = vocabulary[TokenKey(left)], let rhs = vocabulary[TokenKey(right)], let output = vocabulary[TokenKey(left + right)] else { throw TokenizerFailure("BPE merge references an absent token") }
                                let pair = Self.pair(lhs, rhs)
                                guard merges.updateValue(Merge(rank: rank, result: output), forKey: pair) == nil else { throw TokenizerFailure("Duplicate BPE pair") }
                                rank += 1
                            } while reader.consume(44)
                            try reader.require(93)
                        }
                    } else { metadata["model." + field] = try reader.smallValue() }
                } while reader.consume(44)
                try reader.require(125)
            } else { guard metadata[key] == nil else { throw TokenizerFailure("Duplicate tokenizer field") }; metadata[key] = try reader.smallValue() }
        } while reader.consume(44)
        try reader.require(125); reader.whitespace()
        guard case .null? = metadata["model.dropout"], case .null? = metadata["model.continuing_subword_prefix"],
            case .null? = metadata["model.end_of_word_suffix"] else { throw TokenizerFailure("Unsupported stochastic or affixed BPE") }
        guard reader.offset == mapped.bytes.count, vocabulary.count == 262144, !merges.isEmpty,
            metadata["model.type"]?.string == "BPE", metadata["model.byte_fallback"]?.bool == true,
            metadata["model.ignore_merges"]?.bool == false, metadata["model.fuse_unk"]?.bool == true,
            metadata["normalizer"]?["type"]?.string == "Replace", metadata["normalizer"]?["pattern"]?["String"]?.string == " ",
            metadata["normalizer"]?["content"]?.string == "▁", metadata["pre_tokenizer"]?["type"]?.string == "Split",
            metadata["pre_tokenizer"]?["pattern"]?["String"]?.string == " ", metadata["pre_tokenizer"]?["behavior"]?.string == "MergedWithPrevious",
            metadata["pre_tokenizer"]?["invert"]?.bool == false,
            vocabulary[TokenKey("<bos>")] == 2, vocabulary[TokenKey("<eos>")] == 1 else { throw TokenizerFailure("Tokenizer differs from the pinned Gemma 2 BPE pipeline") }
        guard let template = metadata["post_processor"]?["single"]?.array, template.count == 3,
            template[0]["SpecialToken"]?["id"]?.string == "<bos>", template[1]["Sequence"]?["id"]?.string == "A",
            template[2]["SpecialToken"]?["id"]?.string == "<eos>" else { throw TokenizerFailure("Unsupported tokenizer special-token template") }
        guard metadata["post_processor"]?["special_tokens"]?["<bos>"]?["ids"]?.array?.map({ $0.integer }) == [2],
            metadata["post_processor"]?["special_tokens"]?["<eos>"]?["ids"]?.array?.map({ $0.integer }) == [1],
            metadata["added_tokens"]?.array?.count == 24 else { throw TokenizerFailure("Pinned special-token mapping changed") }
        for token in metadata["added_tokens"]?.array ?? [] {
            guard let content = token["content"]?.string, let id = token["id"]?.integer,
                !content.isEmpty, vocabulary[TokenKey(content)] == Int64(id), token["normalized"]?.bool == false,
                token["single_word"]?.bool == false, token["lstrip"]?.bool == false, token["rstrip"]?.bool == false else { throw TokenizerFailure("Unsupported added-token matching policy") }
            let bytes = Array(content.utf8); addedByFirst[bytes[0], default: []].append(Added(bytes: bytes, id: Int64(id)))
        }
        for key in addedByFirst.keys { addedByFirst[key]!.sort { $0.bytes.count > $1.bytes.count } }
        for byte in 0..<256 {
            let text = String(byte, radix: 16, uppercase: true)
            guard let id = vocabulary[TokenKey("<0x" + (byte < 16 ? "0" : "") + text + ">")] else { throw TokenizerFailure("Missing byte fallback token") }
            fallback.append(id)
        }
    }
    static func query(_ text: String) -> String { "task: search result | query: " + text }
    static func document(title: String?, content: String) -> String { "title: " + (title.flatMap { $0.isEmpty ? nil : $0 } ?? "none") + " | text: " + content }
    static func checkPolicies() throws {
        guard TokenKey("é") != TokenKey("e\u{301}"),
            query("dogs") == "task: search result | query: dogs",
            document(title: nil, content: "text") == "title: none | text: text",
            document(title: "Guide", content: "text") == "title: Guide | text: text" else { throw TokenizerFailure("Tokenizer Unicode key or task prefix policy failed") }
        var heap = Heap()
        for (rank, index) in [(9, 0), (3, 2), (3, 1), (5, 4)] { heap.push(Candidate(rank: rank, left: index, right: index + 1, generation: 0, result: 0)) }
        for expected in [1, 2, 4, 0] {
            guard heap.pop()?.left == expected else { throw TokenizerFailure("BPE adjacent merge rank/position priority failed") }
        }
        guard heap.pop() == nil else { throw TokenizerFailure("BPE merge queue did not empty") }
    }

    func encode(text: String, addSpecialTokens: Bool = true, maxTokens: Int = 8192) throws -> [Int64] {
        let tokens = try encodePrimaryFixture(text: text, addSpecialTokens: addSpecialTokens, maxTokens: maxTokens)
        guard !tokens.contains(where: Self.mediaIDs.contains) else { throw TokenizerFailure("Media-token literals require media features; this encoder is text-only") }
        return tokens
    }
    /// Golden-reference comparisons only; production callers must use the text-only guard above.
    func encodePrimaryFixture(text: String, addSpecialTokens: Bool = true, maxTokens: Int = 8192) throws -> [Int64] {
        guard text.utf8.count <= 65536, (addSpecialTokens ? 2 : 1)...8192 ~= maxTokens else { throw TokenizerFailure("Tokenizer input or context budget exceeded") }
        let bytes = Array(text.utf8); var offset = 0, ordinaryStart = 0, result: [Int64] = []
        let budget = maxTokens - (addSpecialTokens ? 2 : 0)
        func appendOrdinary(_ start: Int, _ end: Int) throws {
            guard start < end, result.count < budget else { return }
            guard let piece = String(validating: bytes[start..<end], as: UTF8.self) else { throw TokenizerFailure("Added token divided a UTF-8 scalar") }
            result += try bpe(piece).prefix(budget - result.count)
        }
        while offset < bytes.count, result.count < budget {
            if let added = addedByFirst[bytes[offset]]?.first(where: { offset + $0.bytes.count <= bytes.count && bytes[offset..<offset + $0.bytes.count].elementsEqual($0.bytes) }) {
                try appendOrdinary(ordinaryStart, offset)
                if result.count < budget { result.append(added.id) }
                offset += added.bytes.count; ordinaryStart = offset
            } else { offset += 1 }
        }
        try appendOrdinary(ordinaryStart, offset)
        return addSpecialTokens ? [2] + result + [1] : result
    }
    private func bpe(_ text: String) throws -> [Int64] {
        var nodes: [Symbol] = []
        nodes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let token = scalar.value == 32 ? "▁" : String(scalar)
            if let id = vocabulary[TokenKey(token)] { nodes.append(Symbol(id: id, previous: nodes.count - 1, next: nodes.count + 1)) }
            else { for byte in token.utf8 { nodes.append(Symbol(id: fallback[Int(byte)], previous: nodes.count - 1, next: nodes.count + 1)) } }
        }
        guard !nodes.isEmpty else { return [] }; nodes[nodes.count - 1].next = -1
        var heap = Heap()
        func candidate(_ index: Int) -> Candidate? {
            guard index >= 0, nodes[index].live, nodes[index].next >= 0 else { return nil }
            let right = nodes[index].next
            guard let merge = merges[Self.pair(nodes[index].id, nodes[right].id)] else { return nil }
            return Candidate(rank: merge.rank, left: index, right: right, generation: nodes[index].generation, result: merge.result)
        }
        for index in nodes.indices { if let value = candidate(index) { heap.push(value) } }
        while let merge = heap.pop() {
            let left = merge.left, right = merge.right
            guard nodes[left].live, nodes[right].live, nodes[left].next == right, nodes[left].generation == merge.generation,
                merges[Self.pair(nodes[left].id, nodes[right].id)]?.rank == merge.rank else { continue }
            let next = nodes[right].next
            nodes[left].id = merge.result; nodes[left].next = next; nodes[left].generation += 1
            nodes[right].live = false
            if next >= 0 { nodes[next].previous = left }
            if let value = candidate(nodes[left].previous) { heap.push(value) }
            if let value = candidate(left) { heap.push(value) }
        }
        var result: [Int64] = [], index = 0
        while index >= 0 { result.append(nodes[index].id); index = nodes[index].next }
        return result
    }
}
