// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import BrightnessCore

private struct ReferenceLease: Codable, Equatable {
    var version = 1
    let owner: UInt32
    let started: UInt64
    let displayID: String
    let backend: String
    let amdID: String?
    let brightness: Int?
    let contrast: Int?
    let gamma: [UInt16]?
}

struct StateJSONTests {
    @Test(arguments: ["native", "amd"])
    func remainsCompatibleWithFoundationRecoveryFiles(_ backend: String) throws {
        let reference = ReferenceLease(
            owner: UInt32.max, started: UInt64.max,
            displayID: "display\\\"/🍎\u{0000}\r\n", backend: backend,
            amdID: backend == "amd" ? "adapter/display" : nil,
            brightness: backend == "amd" ? -50 : nil, contrast: backend == "amd" ? 100 : nil,
            gamma: backend == "native" ? (0..<768).map { UInt16($0 * 73) } : nil)
        let original = try JSONEncoder().encode(reference)
        let fields = try StateJSON.decode(Array(original))
        #expect(fields["started"]?.unsigned == UInt64.max)
        #expect(fields["owner"]?.unsigned == UInt64(UInt32.max))
        #expect(fields["displayID"]?.string == reference.displayID)
        #expect(fields["brightness"]?.integer == reference.brightness)
        #expect(fields["gamma"]?.words == reference.gamma)
        let decoded = try JSONDecoder().decode(ReferenceLease.self, from: Data(StateJSON.encode(fields)))
        #expect(decoded == reference)
    }

    @Test func acceptsReorderedFieldsNullAndUTF16Escapes() throws {
        let bytes = Array(#" { "gamma":null, "displayID":"a\/b\\c\uD83C\uDF4E", "started":638952000000000001 } "#.utf8)
        let fields = try StateJSON.decode(bytes)
        #expect(fields["gamma"] == .null)
        #expect(fields["displayID"]?.string == "a/b\\c🍎")
        #expect(fields["started"]?.unsigned == 638_952_000_000_000_001)
    }

    @Test func preservesStatusSchemaAndIntegerExtremes() throws {
        struct Status: Codable, Equatable {
            let level: Int
            let connected: Bool
            let device: String
            let backend: String
        }
        let expected = Status(level: 75, connected: true, device: "\\\\.\\DISPLAY1", backend: "native WDDM gamma")
        let fields: [String: StateField] = [
            "level": .unsigned(75), "connected": .bool(true),
            "device": .string(expected.device), "backend": .string(expected.backend),
        ]
        #expect(try JSONDecoder().decode(Status.self, from: Data(StateJSON.encode(fields))) == expected)
        #expect(
            try StateJSON.decode(Array(#"{"min":-9223372036854775808,"max":18446744073709551615}"#.utf8))["min"]?
                .integer == Int.min)
    }

    @Test(arguments: [
        "", "[]", "{", "{}x", "{\"x\":1,}", "{\"x\":01}", "{\"x\":+1}", "{\"x\":- 1}",
        "{\"x\":1.5}", "{\"x\":1e3}", "{\"x\":18446744073709551616}", "{\"x\":-9223372036854775809}",
        "{\"x\":1,\"x\":2}", "{\"a\":null,\"\\u0061\":true}", "{\"x\":[65536]}", "{\"x\":[-1]}",
        "{\"x\":[0,]}", "{\"x\":{}}", "{\"x\":\"\\uD800\"}", "{\"x\":\"\\uDC00\"}",
        "{\"x\":\"\\uD800 \\uDC00\"}", "{\"x\":\"\\q\"}", "{\"x\":\"\u{0001}\"}",
    ])
    func rejectsMalformedOrUnsupportedStateValues(_ input: String) {
        #expect(throws: StateJSONError.invalid) { try StateJSON.decode(Array(input.utf8)) }
    }

    @Test func rejectsInvalidUTF8AndBoundsInput() {
        #expect(throws: StateJSONError.invalid) { try StateJSON.decode([123, 34, 120, 34, 58, 34, 255, 34, 125]) }
        #expect(throws: StateJSONError.tooLarge) { try StateJSON.decode(Array(repeating: 32, count: 32768)) }
        #expect(throws: StateJSONError.invalid) { try StateJSON.decode([239, 187, 191, 123, 125]) }
        #expect(throws: Never.self) { try StateJSON.decode(Array("{}".utf8) + Array(repeating: 32, count: 32765)) }
    }

    @Test(arguments: ["SwiftyToys", "SwiftyToys-S-1-5-1", "SwiftyToys-S-1-2-3-1000"])
    func acceptsFixedTaskNames(_ name: String) { #expect(isValidStartupTaskName(name)) }

    @Test(arguments: [
        "", "SwiftyToys-S-", "SwiftyToys-S-١", "SwiftyToys-other", "SwiftyToys\n", "SwiftyToys-S-1/2",
    ])
    func rejectsOtherTaskNames(_ name: String) { #expect(isValidStartupTaskName(name) == false) }

    @Test func trimsWhitespaceWithoutChangingContent() {
        #expect("\t\u{00A0} abc def \r\n".trimmingWhitespace() == "abc def")
        #expect("\r\n\t".trimmingWhitespace().isEmpty)
    }
}
