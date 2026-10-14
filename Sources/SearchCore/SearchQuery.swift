// SPDX-License-Identifier: MIT
import BrightnessCore

/// The result scopes shared by the Search UI and every provider.
public enum SearchCategory: String, Sendable, CaseIterable {
  case all, applications, files, actions

  public var title: String {
    switch self {
    case .all: "All"
    case .applications: "Applications"
    case .files: "Files"
    case .actions: "Actions"
    }
  }

  public var prefix: String {
    switch self {
    case .all: ""
    case .applications: "apps:"
    case .files: "files:"
    case .actions: "actions:"
    }
  }
}

/// A bounded prefix grammar; ordinary paths and unknown prefixes remain literal search text.
public struct SearchQuery: Sendable {
  public let text: String
  public let category: SearchCategory
  public let contentKind: String?
  public let fileExtension: String?
  public let isValid: Bool
  private let allowedExtensions: Set<String>?

  public init(_ raw: String) {
    var remaining = raw.trimmingWhitespace()
    var category = SearchCategory.all
    var kind: String?, fileExtension: String?
    var valid = raw.utf8.count <= 4096 && !raw.utf16.contains(0)
    var foundCategory = false
    if valid {
      while let colon = remaining.firstIndex(of: ":"),
        !remaining[..<colon].contains(where: \.isWhitespace) {
        let prefix = remaining[..<colon].lowercased()
        let after = remaining.index(after: colon)
        if let scope = Self.categories[prefix] {
          if foundCategory || kind != nil || fileExtension != nil { valid = false; break }
          category = scope
          foundCategory = true
          remaining = remaining[after...].trimmingWhitespace()
        } else if let alias = Self.kinds[prefix] {
          if kind != nil || category == .applications || category == .actions {
            valid = false; break
          }
          category = .files
          kind = alias
          remaining = remaining[after...].trimmingWhitespace()
        } else if prefix == "kind" || prefix == "ext" {
          let end = remaining[after...].firstIndex(where: \.isWhitespace) ?? remaining.endIndex
          let value = remaining[after..<end].lowercased()
          if category == .applications || category == .actions { valid = false; break }
          category = .files
          if prefix == "kind" {
            guard kind == nil, let parsed = Self.kinds[value] else { valid = false; break }
            kind = parsed
          } else {
            guard fileExtension == nil, Self.validExtension(value) else { valid = false; break }
            fileExtension = value
          }
          remaining = remaining[end...].trimmingWhitespace()
        } else { break }
      }
    }
    self.text = remaining
    self.category = category
    self.contentKind = kind
    self.fileExtension = fileExtension
    self.isValid = valid
    allowedExtensions = kind.map { Set(Self.extensions(for: $0)) }
  }

  public var libraryQuery: String {
    var tokens: [String] = category == .all ? [] : [category.prefix]
    if let contentKind { tokens.append("kind:" + contentKind) }
    if let fileExtension { tokens.append("ext:" + fileExtension) }
    tokens.append(text)
    return tokens.joined(separator: " ").trimmingWhitespace()
  }

  public var indexedQuery: String { text }

  /// Filters candidates before ranking, including recent and filename-only fallbacks.
  public func accepts(_ item: SearchItem) -> Bool {
    guard isValid else { return false }
    switch category {
    case .all: return true
    case .applications: return item.kind == "Application"
    case .actions: return item.kind == "Action"
    case .files:
      guard item.kind == "File" || item.kind == "Folder" else { return false }
      if let fileExtension,
        item.kind != "File" || Self.pathExtension(item.path) != fileExtension { return false }
      if let allowedExtensions {
        guard item.kind == "File",
          allowedExtensions.contains(Self.pathExtension(item.path)) else {
          return false
        }
      }
      return true
    }
  }

  /// Canonical extension groups also bound native SQL restrictions; they contain no user input.
  public static func extensions(for kind: String) -> [String] {
    switch kind {
    case "pdf": ["pdf"]
    case "image": ["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp", "heic",
      "heif", "jxr", "dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "raw"]
    case "audio": ["wav", "mp3", "m4a", "aac", "wma", "flac", "aif", "aiff", "ogg"]
    case "video": ["mp4", "m4v", "mov", "wmv", "avi", "mkv", "webm", "mpeg", "mpg", "mts", "m2ts"]
    case "document": ["pdf", "doc", "docx", "rtf", "odt", "ppt", "pptx", "xls", "xlsx", "eml", "msg"]
    case "code": ["swift", "rs", "c", "h", "cpp", "hpp", "m", "mm", "py", "js", "jsx",
      "ts", "tsx", "java", "kt", "cs", "go", "rb", "sh", "ps1", "sql", "css", "scss",
      "lua", "vue", "svelte", "dart"]
    case "text": ["txt", "md", "markdown", "csv", "tsv", "json", "log", "yaml",
      "yml", "toml", "html", "htm", "xml", "ini", "cfg", "rst", "tex"]
    default: []
    }
  }

  private static let categories: [String: SearchCategory] = [
    "apps": .applications, "applications": .applications, "files": .files, "actions": .actions,
  ]
  private static let kinds = ["code": "code", "pdf": "pdf", "image": "image", "photo": "image",
    "audio": "audio", "video": "video", "document": "document", "text": "text"]

  private static func validExtension(_ value: String) -> Bool {
    (1...16).contains(value.utf8.count) && value.utf8.allSatisfy {
      (97...122).contains($0) || (48...57).contains($0)
    }
  }

  private static func pathExtension(_ path: String) -> String {
    let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
  }
}
