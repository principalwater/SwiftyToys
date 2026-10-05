// SPDX-License-Identifier: MIT

extension StringProtocol {
    /// Removes surrounding Unicode whitespace without a locale database.
    public func trimmingWhitespace() -> String {
        var text = self[...]
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return String(text)
    }
}

/// Accepts only the application's fixed name or its per-user ASCII SID suffix.
public func isValidStartupTaskName(_ name: String) -> Bool {
    if name == "SwiftyToys" { return true }
    let prefix = "SwiftyToys-S-"
    let suffix = name.dropFirst(prefix.count)
    return name.hasPrefix(prefix) && !suffix.isEmpty
        && suffix.utf8.allSatisfy { $0 == 45 || (48...57).contains($0) }
}
