// SPDX-License-Identifier: MIT

enum AppVersion {
    static let string = "0.1.27"
    static let implementation: String = {
        let directory = executablePath().split(separator: "\\").dropLast().joined(separator: "\\")
        guard let bytes = try? NativeFiles.read(directory + "\\swift-version.txt", maximum: 64) else { return "Swift" }
        let values = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard values.count == 1 else { return "Swift" }
        let parts = values[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return "Swift" }
        return "Swift \(values[0])"
    }()
}
