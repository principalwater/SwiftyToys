// SPDX-License-Identifier: MIT
import WinSDK

/// Untrusted BERT exports cannot load external files, functions or custom operator domains.
enum NativeEmbeddingGraphPolicy {
    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0
        mutating func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw TokenizerFailure("Truncated ONNX field") }
                let byte = bytes[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw TokenizerFailure("Oversized ONNX integer") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw TokenizerFailure("Invalid ONNX integer")
        }
        mutating func field() throws -> (Int, Int, UnsafeBufferPointer<UInt8>?) {
            let key = try integer(), number = Int(key >> 3), wire = Int(key & 7)
            guard number > 0 else { throw TokenizerFailure("Invalid ONNX field number") }
            switch wire {
            case 0: _ = try integer(); return (number, wire, nil)
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard size <= bytes.count - offset else { throw TokenizerFailure("Truncated ONNX scalar") }
                offset += size; return (number, wire, nil)
            case 2:
                let size = try integer()
                guard size <= UInt64(bytes.count - offset) else { throw TokenizerFailure("Truncated ONNX message") }
                let value = UnsafeBufferPointer(start: bytes.baseAddress?.advanced(by: offset), count: Int(size))
                offset += Int(size); return (number, wire, value)
            default: throw TokenizerFailure("Unsupported ONNX wire type")
            }
        }
    }
    private enum Message { case model, graph, node, attribute, tensor, opset }
    private static func inspect(_ bytes: UnsafeBufferPointer<UInt8>, message: Message, depth: Int = 0) throws {
        guard depth <= 12 else { throw TokenizerFailure("ONNX graph nesting exceeds its budget") }
        var reader = Reader(bytes: bytes), graphSeen = false
        while reader.offset < bytes.count {
            let (field, _, value) = try reader.field()
            if message == .tensor, field == 13 || field == 14 {
                throw TokenizerFailure("The native BERT model must contain all weights in one ONNX file")
            }
            if message == .model, [20, 25].contains(field) {
                throw TokenizerFailure("Training graphs and custom ONNX functions are unsupported")
            }
            if message == .graph, [15].contains(field) || message == .attribute && [6,11,22,23].contains(field) {
                throw TokenizerFailure("Nested or sparse ONNX graphs are unsupported by this native adapter")
            }
            if (message == .node && field == 7) || (message == .opset && field == 1) {
                guard let value else { throw TokenizerFailure("Invalid ONNX operator domain") }
                let domain = String(decoding: value, as: UTF8.self)
                guard domain.isEmpty || domain == "ai.onnx" else { throw TokenizerFailure("This model requires an unsupported custom operator domain") }
            }
            guard let value else { continue }
            let nested: Message?
            switch (message, field) {
            case (.model, 7):
                guard !graphSeen else { throw TokenizerFailure("Duplicate ONNX graph") }
                graphSeen = true; nested = .graph
            case (.model, 8): nested = .opset
            case (.graph, 1): nested = .node
            case (.graph, 5): nested = .tensor
            case (.node, 5): nested = .attribute
            case (.attribute, 5), (.attribute, 10): nested = .tensor
            default: nested = nil
            }
            if let nested { try inspect(value, message: nested, depth: depth + 1) }
        }
        if message == .model, !graphSeen { throw TokenizerFailure("The ONNX model has no graph") }
    }
    static func validate(_ path: String) throws {
        let file = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        })
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(file.raw, &size), (1...120_000_000).contains(size.QuadPart) else { throw TokenizerFailure("The ONNX model exceeds its native size budget") }
        let mapping = try OwnedHandle(CreateFileMappingW(file.raw, nil, DWORD(PAGE_READONLY), 0, 0, nil))
        guard let view = MapViewOfFile(mapping.raw, DWORD(FILE_MAP_READ), 0, 0, 0) else { throw WindowsError.api("Inspect ONNX model", GetLastError()) }
        defer { UnmapViewOfFile(view) }
        try inspect(UnsafeBufferPointer(start: view.assumingMemoryBound(to: UInt8.self), count: Int(size.QuadPart)), message: .model)
        withExtendedLifetime(mapping) {}
    }
    static func selfCheck() throws {
        let valid: [UInt8] = [58, 0] // ModelProto.graph = empty GraphProto.
        try valid.withUnsafeBufferPointer { try inspect($0, message: .model) }
        for invalid: [UInt8] in [[58, 2], [58, 4, 42, 2, 106, 0], [202, 1, 0], [58, 5, 10, 3, 58, 1, 120]] {
            var rejected = false
            do { try invalid.withUnsafeBufferPointer { try inspect($0, message: .model) } } catch { rejected = true }
            guard rejected else { throw TokenizerFailure("ONNX model policy accepted an unsafe fixture") }
        }
    }
}
