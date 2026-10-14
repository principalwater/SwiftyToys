// SPDX-License-Identifier: MIT
import WinSDK

/// The verified uncased BERT tokenizer, with bounded greedy WordPiece segmentation.
final class BertWordPieceTokenizer {
    private let vocabulary: [String: Int64]
    private init(vocabulary: [String: Int64]) { self.vocabulary = vocabulary }
    init(path: String) throws {
        let asset = NativeSearchModelDescriptor.miniLM.tokenizer
        let held = try NativeEmbeddingFile(path, asset: asset)
        let bytes = try NativeFiles.read(path, maximum: 262144)
        guard let text = String(validating: bytes, as: UTF8.self) else { throw TokenizerFailure("Invalid WordPiece vocabulary UTF-8") }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard rows.count == 30523, rows.last?.isEmpty == true else { throw TokenizerFailure("Invalid WordPiece vocabulary length") }
        var vocabulary: [String: Int64] = [:]
        vocabulary.reserveCapacity(30522)
        for (index, row) in rows.dropLast().enumerated() {
            guard !row.isEmpty, vocabulary.updateValue(Int64(index), forKey: String(row)) == nil else { throw TokenizerFailure("Invalid WordPiece vocabulary entry") }
        }
        guard vocabulary["[PAD]"] == 0, vocabulary["[UNK]"] == 100,
            vocabulary["[CLS]"] == 101, vocabulary["[SEP]"] == 102,
            vocabulary["[MASK]"] == 103 else { throw TokenizerFailure("Invalid WordPiece special tokens") }
        self.vocabulary = vocabulary
        withExtendedLifetime(held) {}
    }
    private static func normalized(_ text: String) throws -> [Unicode.Scalar] {
        var clean = ""
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory, value = scalar.value
            if value == 0 || value == 0xfffd || ((category == .control || category == .format) && ![9, 10, 13].contains(value)) { continue }
            if [9, 10, 13, 32].contains(value) || category == .spaceSeparator { clean += " "; continue }
            clean.unicodeScalars.append(scalar)
        }
        let lowered = Array(clean.lowercased().utf16)
        if lowered.isEmpty { return [] }
        let length = lowered.withUnsafeBufferPointer { NormalizeString(NormalizationD, $0.baseAddress, Int32($0.count), nil, 0) }
        guard length > 0, length <= 131072 else { throw TokenizerFailure("WordPiece normalization exceeded its budget") }
        var decomposed = [WCHAR](repeating: 0, count: Int(length))
        let count = lowered.withUnsafeBufferPointer { NormalizeString(NormalizationD, $0.baseAddress, Int32($0.count), &decomposed, length) }
        guard count > 0 else { throw TokenizerFailure("WordPiece Unicode normalization failed") }
        return String(decoding: decomposed.prefix(Int(count)), as: UTF16.self).unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }
    }
    private static func chinese(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4e00...0x9fff).contains(value) || (0x3400...0x4dbf).contains(value)
            || (0x20000...0x2a6df).contains(value) || (0x2a700...0x2b73f).contains(value)
            || (0x2b740...0x2b81f).contains(value) || (0x2b820...0x2ceaf).contains(value)
            || (0xf900...0xfaff).contains(value) || (0x2f800...0x2fa1f).contains(value)
    }
    private static func punctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
    func encode(text: String, maxTokens: Int = 128) throws -> [Int64] {
        guard text.utf8.count <= 65536, (2...512).contains(maxTokens) else { throw TokenizerFailure("WordPiece text or token budget exceeded") }
        var output: [Int64] = [101]
        func word(_ scalars: [Unicode.Scalar]) {
            guard !scalars.isEmpty, output.count < maxTokens - 1 else { return }
            if scalars.count > 100 { output.append(100); return }
            var start = 0, pieces: [Int64] = []
            while start < scalars.count {
                var end = scalars.count, match: Int64?
                while end > start {
                    let candidate = (start > 0 ? "##" : "") + String(String.UnicodeScalarView(scalars[start..<end]))
                    if let id = vocabulary[candidate] { match = id; break }
                    end -= 1
                }
                guard let match else { output.append(100); return }
                pieces.append(match); start = end
            }
            output += pieces.prefix(maxTokens - 1 - output.count)
        }
        func ordinary(_ text: String) throws {
            var pending: [Unicode.Scalar] = []
            for scalar in try Self.normalized(text) {
                if scalar.value == 32 { word(pending); pending.removeAll(keepingCapacity: true) }
                else if Self.chinese(scalar) || Self.punctuation(scalar) {
                    word(pending); pending.removeAll(keepingCapacity: true); word([scalar])
                } else { pending.append(scalar) }
                if output.count == maxTokens - 1 { break }
            }
            word(pending)
        }
        // Added special tokens are matched before normalization, as in the pinned tokenizer.json.
        let specials = ["[UNK]", "[SEP]", "[PAD]", "[CLS]", "[MASK]"].map { (text: $0, bytes: Array($0.utf8)) }
        let bytes = Array(text.utf8)
        var cursor = 0, beginning = 0
        while cursor < bytes.count, output.count < maxTokens - 1 {
            if let special = specials.first(where: { cursor + $0.bytes.count <= bytes.count && bytes[cursor..<cursor + $0.bytes.count].elementsEqual($0.bytes) }) {
                try ordinary(String(decoding: bytes[beginning..<cursor], as: UTF8.self))
                if output.count < maxTokens - 1 { output.append(vocabulary[special.text]!) }
                cursor += special.bytes.count; beginning = cursor
            } else { cursor += 1 }
        }
        if output.count < maxTokens - 1 { try ordinary(String(decoding: bytes[beginning...], as: UTF8.self)) }
        output.append(102)
        return output
    }
    static func selfCheck() throws {
        let tokenizer = BertWordPieceTokenizer(vocabulary: ["[PAD]":0, "[UNK]":100,
            "[CLS]":101, "[SEP]":102, "[MASK]":103, "hello":200, "world":201,
            "##s":202, "!":203, "cafe":204, "中":205, "文":206])
        for (text, expected): (String, [Int64]) in [
            ("Hello worlds!", [101,200,201,202,203,102]),
            ("CAFÉ cafe\u{301}", [101,204,204,102]),
            ("中 文", [101,205,206,102]),
            ("hello[MASK]world", [101,200,103,201,102]),
            ("[MASK]\u{301}", [101,103,102]),
            ("unknown", [101,100,102]),
            (String(repeating: "a", count: 101), [101,100,102]),
            ("hello\u{0}\nworld", [101,200,201,102]),
        ] {
            guard try tokenizer.encode(text: text) == expected else { throw TokenizerFailure("Native WordPiece normalization or segmentation fixture failed") }
        }
        guard try tokenizer.encode(text: "hello worlds!", maxTokens: 3) == [101,200,102] else { throw TokenizerFailure("WordPiece truncation lost SEP") }
    }
}
