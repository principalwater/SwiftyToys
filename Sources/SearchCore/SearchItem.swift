// SPDX-License-Identifier: MIT
import BrightnessCore
public struct SearchItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let path: String
    public let kind: String
    public init(id: String, title: String, subtitle: String, path: String, kind: String) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.path = path; self.kind = kind
    }
}

/// Bounded, deterministic ranking. No disk access or model is needed to show lexical results.
public enum SearchRanking {
    public static func score(_ title: String, query: String) -> Int {
        let title = title.lowercased(), query = query.lowercased()
        guard !query.isEmpty, query.utf8.count <= 1024, title.utf8.count <= 4096 else { return query.isEmpty ? 1 : 0 }
        if title == query { return 1000 }
        if title.hasPrefix(query) { return 900 - min(100, title.count - query.count) }
        if title.containsText(query) { return 700 }
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        if !terms.isEmpty, terms.allSatisfy({ title.containsText(String($0)) }) { return 600 }
        // Subsequence matching keeps abbreviated app names useful without a quadratic edit-distance table.
        var remaining = query.makeIterator(), wanted = remaining.next(), gap = 0, started = false
        for character in title {
            if character == wanted { started = true; wanted = remaining.next(); if wanted == nil { return max(100, 400 - gap) } }
            else if started { gap += 1 }
        }
        return 0
    }
    public static func results(_ items: [SearchItem], query: String, limit: Int = 32) -> [SearchItem] {
        var seen = Set<String>()
        return items.prefix(8192).compactMap { item -> (SearchItem, Int)? in
            let value = score(item.title, query: query)
            guard value > 0, seen.insert(item.id.lowercased()).inserted else { return nil }
            return (item, value)
        }.sorted {
            $0.1 == $1.1 ? $0.0.title.lowercased() < $1.0.title.lowercased() : $0.1 > $1.1
        }.prefix(max(0, min(64, limit))).map(\.0)
    }
}

public enum SearchWireError: Error, Sendable { case invalid }

/// Length-prefixed UTF-8 IPC: tabs/newlines in filenames are data, never commands.
public enum SearchWire {
    public static func encode(_ items: [SearchItem], status: String = "") throws -> [UInt8] {
        guard items.count <= 64 else { throw SearchWireError.invalid }
        var bytes = Array("SWTSRCH1".utf8)
        func integer(_ value: Int) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        func field(_ value: String) throws {
            let data = Array(value.utf8)
            guard data.count <= 16384, !data.contains(0) else { throw SearchWireError.invalid }
            integer(data.count); bytes += data
        }
        integer(items.count); try field(status)
        for item in items { for value in [item.id, item.title, item.subtitle, item.path, item.kind] { try field(value) } }
        guard bytes.count <= 1_048_576 else { throw SearchWireError.invalid }
        return bytes
    }
    public static func decode(_ bytes: [UInt8]) throws -> (items: [SearchItem], status: String) {
        guard bytes.count >= 16, bytes.count <= 1_048_576, Array(bytes.prefix(8)) == Array("SWTSRCH1".utf8) else { throw SearchWireError.invalid }
        var index = 8
        func integer() throws -> Int {
            guard index <= bytes.count - 4 else { throw SearchWireError.invalid }
            let number = (0..<4).reduce(0) { $0 | Int(bytes[index + $1]) << ($1 * 8) }; index += 4; return number
        }
        func field() throws -> String {
            let count = try integer()
            guard count <= 16384, count <= bytes.count - index else { throw SearchWireError.invalid }
            let data = bytes[index..<(index + count)]; index += count
            let text = String(decoding: data, as: UTF8.self)
            guard !data.contains(0), Array(text.utf8) == Array(data) else { throw SearchWireError.invalid }
            return text
        }
        let count = try integer(); guard count <= 64 else { throw SearchWireError.invalid }
        let status = try field(); var items: [SearchItem] = []; items.reserveCapacity(count)
        for _ in 0..<count { items.append(try SearchItem(id: field(), title: field(), subtitle: field(), path: field(), kind: field())) }
        guard index == bytes.count else { throw SearchWireError.invalid }
        return (items, status)
    }
}
