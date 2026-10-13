// SPDX-License-Identifier: MIT
import WinSDK

struct TokenizerFailure: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }

final class TokenizerMappedJSON {
    let bytes: UnsafeBufferPointer<UInt8>
    private let file: OwnedHandle
    private let mapping: OwnedHandle
    private let view: UnsafeMutableRawPointer
    init(path: String) throws {
        let file = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
        })
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(file.raw, &size), (1...40_000_000).contains(size.QuadPart) else { throw TokenizerFailure("Tokenizer JSON size is invalid") }
        let mapping = try OwnedHandle(CreateFileMappingW(file.raw, nil, DWORD(PAGE_READONLY), 0, 0, nil))
        guard let view = MapViewOfFile(mapping.raw, DWORD(FILE_MAP_READ), 0, 0, 0) else { throw WindowsError.api("Read tokenizer JSON mapping", GetLastError()) }
        self.file = consume file; self.mapping = consume mapping; self.view = view
        bytes = UnsafeBufferPointer(start: view.assumingMemoryBound(to: UInt8.self), count: Int(size.QuadPart))
    }
    deinit { UnmapViewOfFile(view) }
}

indirect enum SmallJSON {
    case object([String: SmallJSON]), array([SmallJSON]), string(String), integer(Int), bool(Bool), null
    var object: [String: SmallJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [SmallJSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    subscript(_ key: String) -> SmallJSON? { object?[key] }
}

struct TokenizerJSONReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset = 0
    mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func consume(_ value: UInt8) -> Bool { whitespace(); guard offset < bytes.count, bytes[offset] == value else { return false }; offset += 1; return true }
    mutating func require(_ value: UInt8) throws { guard consume(value) else { throw TokenizerFailure("Invalid tokenizer JSON at byte \(offset)") } }
    mutating func string() throws -> String {
        try require(34)
        let start = offset
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == 34 {
                let end = offset; offset += 1
                if !escaped {
                    guard let result = String(validating: UnsafeBufferPointer(start: bytes.baseAddress! + start, count: end - start), as: UTF8.self) else { throw TokenizerFailure("Invalid tokenizer UTF-8") }
                    return result
                }
                var result: [UInt8] = [], position = start
                while position < end {
                    let value = bytes[position]; position += 1
                    if value != 92 { result.append(value); continue }
                    guard position < end else { throw TokenizerFailure("Invalid JSON escape") }
                    let escape = bytes[position]; position += 1
                    switch escape {
                    case 34, 47, 92: result.append(escape)
                    case 98: result.append(8)
                    case 102: result.append(12)
                    case 110: result.append(10)
                    case 114: result.append(13)
                    case 116: result.append(9)
                    case 117:
                        func word(_ position: inout Int) throws -> UInt32 {
                            guard position + 4 <= end else { throw TokenizerFailure("Truncated JSON Unicode escape") }
                            var value: UInt32 = 0
                            for _ in 0..<4 {
                                let byte = bytes[position]; position += 1
                                let digit: UInt32
                                switch byte { case 48...57: digit = UInt32(byte - 48); case 65...70: digit = UInt32(byte - 55); case 97...102: digit = UInt32(byte - 87); default: throw TokenizerFailure("Invalid JSON Unicode digit") }
                                value = value << 4 | digit
                            }
                            return value
                        }
                        var scalar = try word(&position)
                        if (0xd800...0xdbff).contains(scalar) {
                            guard position + 2 <= end, bytes[position] == 92, bytes[position + 1] == 117 else { throw TokenizerFailure("Missing low surrogate") }
                            position += 2; let low = try word(&position)
                            guard (0xdc00...0xdfff).contains(low) else { throw TokenizerFailure("Invalid low surrogate") }
                            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00
                        }
                        guard let value = Unicode.Scalar(scalar) else { throw TokenizerFailure("Invalid Unicode scalar") }
                        result += String(value).utf8
                    default: throw TokenizerFailure("Unknown JSON escape")
                    }
                }
                guard let result = String(validating: result, as: UTF8.self) else { throw TokenizerFailure("Invalid escaped UTF-8") }
                return result
            }
            guard byte >= 32 else { throw TokenizerFailure("Unescaped JSON control character") }
            if byte == 92 { escaped = true; offset += 1; guard offset < bytes.count else { throw TokenizerFailure("Truncated JSON escape") } }
            offset += 1
        }
        throw TokenizerFailure("Unterminated tokenizer string")
    }
    mutating func integer() throws -> Int {
        whitespace(); let start = offset
        if offset < bytes.count, bytes[offset] == 45 { offset += 1 }
        while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
        guard start < offset, let value = Int(String(decoding: bytes[start..<offset], as: UTF8.self)) else { throw TokenizerFailure("Invalid JSON integer") }
        return value
    }
    mutating func smallValue(depth: Int = 0) throws -> SmallJSON {
        guard depth < 32 else { throw TokenizerFailure("Tokenizer metadata nesting limit") }
        whitespace(); guard offset < bytes.count else { throw TokenizerFailure("Missing JSON value") }
        if bytes[offset] == 34 { return .string(try string()) }
        if consume(123) {
            var fields: [String: SmallJSON] = [:]
            if consume(125) { return .object(fields) }
            repeat { let key = try string(); try require(58); guard fields[key] == nil, fields.count < 8192 else { throw TokenizerFailure("Duplicate or oversized metadata object") }; fields[key] = try smallValue(depth: depth + 1) } while consume(44)
            try require(125); return .object(fields)
        }
        if consume(91) {
            var items: [SmallJSON] = []
            if consume(93) { return .array(items) }
            repeat { guard items.count < 8192 else { throw TokenizerFailure("Oversized metadata array") }; items.append(try smallValue(depth: depth + 1)) } while consume(44)
            try require(93); return .array(items)
        }
        for (literal, value) in [("true", SmallJSON.bool(true)), ("false", .bool(false)), ("null", .null)] {
            let word = Array(literal.utf8)
            if offset + word.count <= bytes.count, bytes[offset..<offset + word.count].elementsEqual(word) { offset += word.count; return value }
        }
        return .integer(try integer())
    }
}
