// SPDX-License-Identifier: MIT
import WinSDK

extension GemmaBPETokenizer {
    /// Default checks are offline. Supplying verified model/fixture paths additionally checks the complete vocabulary.
    static func selfCheck(tokenizerPath: String? = nil, fixturePath: String? = nil) throws {
        try checkPolicies()
        let json = Array("{\"text\":\"é\\u0065\\u0301\\ud83d\\ude00\",\"id\":2,\"null\":null}".utf8)
        let value = try json.withUnsafeBufferPointer { pointer in
            var reader = TokenizerJSONReader(bytes: pointer)
            let value = try reader.smallValue(); reader.whitespace()
            guard reader.offset == pointer.count else { throw TokenizerFailure("Tokenizer JSON trailing data") }
            return value
        }
        guard value["text"]?.string?.utf8.elementsEqual("ée\u{301}😀".utf8) == true, value["id"]?.integer == 2 else {
            throw TokenizerFailure("Tokenizer bounded JSON Unicode decoding failed")
        }
        for malformed in ["{\"a\":1,\"a\":2}", "\"\\ud800\"", "\"\\uZZZZ\"", "\"raw\ncontrol\""] {
            var refused = false
            do { _ = try Array(malformed.utf8).withUnsafeBufferPointer { pointer in var reader = TokenizerJSONReader(bytes: pointer); return try reader.smallValue() } } catch { refused = true }
            guard refused else { throw TokenizerFailure("Malformed tokenizer JSON was accepted") }
        }
        guard (tokenizerPath == nil) == (fixturePath == nil) else { throw TokenizerFailure("Supply both tokenizer and golden fixture paths") }
        guard let tokenizerPath, let fixturePath else {
            Console.writeLine("PASS: tokenizer byte-exact Unicode keys, merge priority, task prefixes and bounded JSON; no model loaded")
            return
        }
        let tokenizer = try GemmaBPETokenizer(path: tokenizerPath)
        let file = try TokenizerMappedJSON(path: fixturePath)
        defer { withExtendedLifetime(file) {} }
        var reader = TokenizerJSONReader(bytes: file.bytes)
        let root = try reader.smallValue(); reader.whitespace()
        guard reader.offset == file.bytes.count, root["source_sha256"]?.string == expectedSHA256,
            let cases = root["cases"]?.array, !cases.isEmpty else { throw TokenizerFailure("Invalid pinned tokenizer golden fixture") }
        var checked = 0, mediaRejected = 0
        for fixture in cases {
            guard let text = fixture["text"]?.string else { throw TokenizerFailure("Missing tokenizer fixture text") }
            let budget = fixture["max"]?.integer ?? 8192
            for field in ["ids", "plain"] {
                guard let values = fixture[field]?.array else { continue }
                let expected = try values.map { value -> Int64 in
                    guard let id = value.integer, (0..<262144).contains(id) else { throw TokenizerFailure("Invalid golden token ID") }
                    return Int64(id)
                }
                let actual = try tokenizer.encodePrimaryFixture(text: text, addSpecialTokens: field == "ids", maxTokens: budget)
                guard actual == expected else { throw TokenizerFailure("Primary tokenizer golden mismatch at case \(checked)") }
                checked += 1
            }
            if fixture["ids"]?.array?.contains(where: { $0.integer.map { mediaIDs.contains(Int64($0)) } ?? false }) == true {
                var refused = false
                do { _ = try tokenizer.encode(text: text, maxTokens: budget) } catch { refused = true }
                guard refused else { throw TokenizerFailure("Text-only tokenizer accepted a media ID") }
                mediaRejected += 1
            }
        }
        for budget in [0, 1, 8193] {
            var refused = false
            do { _ = try tokenizer.encode(text: "query", maxTokens: budget) } catch { refused = true }
            guard refused else { throw TokenizerFailure("Invalid embedding context budget accepted") }
        }
        var refused = false
        do { _ = try tokenizer.encode(text: String(repeating: "x", count: 65537)) } catch { refused = true }
        guard refused else { throw TokenizerFailure("Oversized embedding text accepted") }
        Console.writeLine("PASS: pinned tokenizer full vocabulary/merge ranks; \(checked) primary golden comparisons, \(mediaRejected) media-literal rejections and context/input limits")
    }
}
