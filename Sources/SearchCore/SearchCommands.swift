// SPDX-License-Identifier: MIT

/// Built-in commands share the same safe action path as Search results.
public enum SearchCommands {
  public static let items: [SearchItem] = [
    SearchItem(id: "action:settings", title: "SwiftyToys Settings",
      subtitle: "Open the tool overview", path: "", kind: "Action"),
    SearchItem(id: "action:windows-settings", title: "Windows Settings",
      subtitle: "Configure Windows", path: "", kind: "Action"),
    SearchItem(id: "action:calculator", title: "Calculator",
      subtitle: "Open Windows Calculator", path: "", kind: "Action"),
    SearchItem(id: "action:explorer", title: "File Explorer",
      subtitle: "Browse files and folders", path: "", kind: "Action"),
    SearchItem(id: "action:lock", title: "Lock screen",
      subtitle: "Lock this Windows session", path: "", kind: "Action"),
    SearchItem(id: "action:sleep", title: "Sleep",
      subtitle: "Put this computer to sleep", path: "", kind: "Action"),
    SearchItem(id: "action:bluetooth", title: "Bluetooth settings",
      subtitle: "Manage paired devices", path: "", kind: "Action"),
    SearchItem(id: "action:sound", title: "Sound settings",
      subtitle: "Choose audio devices", path: "", kind: "Action"),
    SearchItem(id: "action:display", title: "Display settings",
      subtitle: "Resolution and display options", path: "", kind: "Action"),
  ]
}

public enum SearchQuickKeysError: Error, CustomStringConvertible, Sendable {
  case limit, syntax, alias, duplicate, command

  public var description: String {
    switch self {
    case .limit: return "Use at most 32 Quick Keys and 8,192 bytes of text."
    case .syntax: return "Enter one Quick Key per line, such as calc = Calculator."
    case .alias: return "Quick Keys need 1–16 letters, numbers, hyphens or underscores."
    case .duplicate: return "Each Quick Key must be unique, ignoring letter case."
    case .command: return "Choose a command name from the list below Quick Keys."
    }
  }
}

/// Exact, user-defined aliases for built-in commands; matching never executes an action.
public struct SearchQuickKeys: Sendable, Equatable {
  private var commands: [String: String] = [:]

  public init() {}

  /// Parses human-readable lines such as `calc = Calculator`.
  public init(editorText: String) throws {
    try self.init(contents: editorText, separator: "=", usesTitles: true)
  }

  /// Parses persisted `alias|actionID` lines, rejecting unknown or executable destinations.
  public init(serialized: String) throws {
    try self.init(contents: serialized, separator: "|", usesTitles: false)
  }

  private init(contents: String, separator: Character, usesTitles: Bool) throws {
    guard contents.utf8.count <= 8_192 else { throw SearchQuickKeysError.limit }
    for line in contents.split(whereSeparator: \.isNewline) {
      if line.allSatisfy(\.isWhitespace) { continue }
      guard commands.count < 32 else { throw SearchQuickKeysError.limit }
      let parts = line.split(separator: separator, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw SearchQuickKeysError.syntax }
      let alias = Self.trim(parts[0]).lowercased()
      guard Self.isValidAlias(alias) else { throw SearchQuickKeysError.alias }
      guard commands[alias] == nil else { throw SearchQuickKeysError.duplicate }
      let destination = Self.trim(parts[1])
      guard let command = SearchCommands.items.first(where: {
        usesTitles ? $0.title.lowercased() == destination.lowercased() : $0.id == destination
      }) else { throw SearchQuickKeysError.command }
      commands[alias] = command.id
    }
  }

  /// Returns the built-in result for a complete alias, never a partial match.
  public func match(_ query: String) -> SearchItem? {
    guard query.utf8.count <= 128 else { return nil }
    let alias = Self.trim(query[...]).lowercased()
    guard Self.isValidAlias(alias), let id = commands[alias] else { return nil }
    return SearchCommands.items.first { $0.id == id }
  }

  /// Stable persistence uses only validated aliases and built-in action identifiers.
  public var serialized: String {
    commands.sorted { $0.key < $1.key }.map { "\($0.key)|\($0.value)" }.joined(separator: "\n")
  }

  /// Human-readable command names keep implementation identifiers out of the editor.
  public var editorText: String {
    commands.keys.sorted().compactMap { alias in
      guard let item = SearchCommands.items.first(where: { $0.id == commands[alias] }) else {
        return nil
      }
      return "\(alias) = \(item.title)"
    }.joined(separator: "\r\n")
  }

  private static func isValidAlias(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 16 && value.utf8.count <= 128
      && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
  }

  private static func trim(_ value: Substring) -> String {
    String(value.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
  }
}
