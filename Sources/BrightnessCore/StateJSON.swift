// SPDX-License-Identifier: MIT

/// Values used by SwiftyToys's flat JSON status and recovery files.
public enum StateField: Sendable, Equatable {
    case string(String)
    case unsigned(UInt64)
    case signed(Int64)
    case bool(Bool)
    case words([UInt16])
    case null

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var unsigned: UInt64? { if case .unsigned(let value) = self { value } else { nil } }
    public var integer: Int? {
        switch self {
        case .unsigned(let value): Int(exactly: value)
        case .signed(let value): Int(exactly: value)
        default: nil
        }
    }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var words: [UInt16]? { if case .words(let value) = self { value } else { nil } }
}

public enum StateJSONError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid, tooLarge
    public var description: String {
        switch self {
        case .invalid: "Invalid brightness state JSON."
        case .tooLarge: "Brightness state exceeds the size limit."
        }
    }
}

/// Bounded codec for the application's state schemas, not general-purpose JSON.
/// Integers never pass through floating point; duplicate keys are rejected.
public enum StateJSON {
    public static func decode(_ bytes: [UInt8]) throws(StateJSONError) -> [String: StateField] {
        guard bytes.count < 32768 else { throw .tooLarge }
        var reader = Reader(bytes: bytes)
        let fields = try reader.object()
        reader.whitespace()
        guard reader.index == bytes.count else { throw .invalid }
        return fields
    }

    public static func encode(_ fields: [String: StateField]) -> [UInt8] {
        func quoted(_ text: String) -> String {
            let hex = Array("0123456789abcdef".utf8)
            var bytes: [UInt8] = [34]
            for byte in text.utf8 {
                switch byte {
                case 34, 92: bytes += [92, byte]
                case 0..<32: bytes += [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]]
                default: bytes.append(byte)
                }
            }
            bytes.append(34)
            return String(decoding: bytes, as: UTF8.self)
        }
        let members = fields.keys.sorted().map { key in
            let value: String
            switch fields[key]! {
            case .string(let text): value = quoted(text)
            case .unsigned(let number): value = String(number)
            case .signed(let number): value = String(number)
            case .bool(let flag): value = flag ? "true" : "false"
            case .words(let words): value = "[" + words.map(String.init).joined(separator: ",") + "]"
            case .null: value = "null"
            }
            return quoted(key) + ":" + value
        }
        return Array(("{" + members.joined(separator: ",") + "}").utf8)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        mutating func require(_ byte: UInt8) throws(StateJSONError) {
            guard consume(byte) else { throw .invalid }
        }
        mutating func next() throws(StateJSONError) -> UInt8 {
            guard index < bytes.count else { throw .invalid }
            defer { index += 1 }
            return bytes[index]
        }
        mutating func hexWord() throws(StateJSONError) -> UInt32 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                let byte = try next()
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte - 48)
                case 65...70: digit = UInt32(byte - 55)
                case 97...102: digit = UInt32(byte - 87)
                default: throw .invalid
                }
                word = word * 16 + digit
            }
            return word
        }
        mutating func string() throws(StateJSONError) -> String {
            try require(34)
            var result: [UInt8] = []
            while true {
                let byte = try next()
                if byte == 34 {
                    guard let string = String(validating: result, as: UTF8.self) else { throw .invalid }
                    return string
                }
                guard byte >= 32 else { throw .invalid }
                if byte != 92 {
                    result.append(byte)
                    continue
                }
                switch try next() {
                case 34: result.append(34)
                case 47: result.append(47)
                case 92: result.append(92)
                case 98: result.append(8)
                case 102: result.append(12)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 117:
                    var scalar = try hexWord()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // No whitespace is allowed inside a surrogate escape.
                        guard try next() == 92, try next() == 117 else { throw .invalid }
                        let low = try hexWord()
                        guard (0xDC00...0xDFFF).contains(low) else { throw .invalid }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00
                    }
                    guard let character = Unicode.Scalar(scalar) else { throw .invalid }
                    result += String(character).utf8
                default: throw .invalid
                }
            }
        }
        mutating func literal(_ text: String) throws(StateJSONError) {
            for byte in text.utf8 { guard try next() == byte else { throw .invalid } }
        }
        mutating func number() throws(StateJSONError) -> StateField {
            whitespace()
            let start = index
            let negative = consume(45)
            // A sign must immediately precede a digit.
            guard index < bytes.count, (48...57).contains(bytes[index]) else { throw .invalid }
            let zero = bytes[index] == 48
            index += 1
            while index < bytes.count, (48...57).contains(bytes[index]) {
                guard !zero else { throw .invalid }
                index += 1
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if negative {
                guard let value = Int64(text) else { throw .invalid }
                return .signed(value)
            }
            guard let value = UInt64(text) else { throw .invalid }
            return .unsigned(value)
        }
        mutating func object() throws(StateJSONError) -> [String: StateField] {
            var fields: [String: StateField] = [:]
            try require(123)
            if !consume(125) {
                repeat {
                    let key = try string()
                    guard fields[key] == nil else { throw .invalid }
                    try require(58)
                    fields[key] = try field()
                } while consume(44)
                try require(125)
            }
            return fields
        }
        mutating func field() throws(StateJSONError) -> StateField {
            whitespace()
            guard index < bytes.count else { throw .invalid }
            switch bytes[index] {
            case 34: return .string(try string())
            case 116:
                try literal("true")
                return .bool(true)
            case 102:
                try literal("false")
                return .bool(false)
            case 110:
                try literal("null")
                return .null
            case 91:
                index += 1
                var words: [UInt16] = []
                if !consume(93) {
                    repeat {
                        guard let value = try number().unsigned, let word = UInt16(exactly: value) else {
                            throw .invalid
                        }
                        words.append(word)
                    } while consume(44)
                    try require(93)
                }
                return .words(words)
            default: return try number()
            }
        }
    }
}
