// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchContentABI
import WinSDK

struct SearchContentImage {
  let width: Int
  let height: Int
  let bgra: [UInt8]
}

struct SearchContentFragment {
  let kind: String
  var text: String = ""
  var page: Int?
  var line: Int?
  var milliseconds: Int64?
  var durationMilliseconds: Int64?
  var image: SearchContentImage?
  var audio: [Float]?
}

struct SearchContentReport {
  let status: String
  let truncated: Bool
  var continuationMilliseconds: Int64? = nil
  var continuationPage: Int? = nil
}

/// Runs only in an owned, memory-limited child; OS filters/codecs may block inside a native call.
enum NativeSearchContent {
  static let textExtensions: Set<String> = [
    "txt", "md", "markdown", "csv", "tsv", "json", "log", "yaml", "yml", "toml",
    "html", "htm", "xml", "swift", "rs", "c", "h", "cpp", "hpp", "m", "mm", "py",
    "js", "jsx", "ts", "tsx", "java", "kt", "cs", "go", "rb", "sh", "ps1", "sql",
    "css", "scss", "ini", "cfg", "rst", "tex", "lua", "vue", "svelte", "dart",
  ]
  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp", "heic", "heif", "jxr",
    "dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "raw",
  ]
  static let documentExtensions: Set<String> = [
    "pdf", "doc", "docx", "rtf", "odt", "ppt", "pptx", "xls", "xlsx", "eml", "msg",
  ]
  static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "wma", "flac", "aif", "aiff", "ogg"]
  static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "wmv", "avi", "mkv", "webm", "mpeg", "mpg", "mts", "m2ts"]

  static func fileExtension(_ path: String) -> String {
    path.split(separator: "\\").last?.split(separator: ".").last?.lowercased() ?? ""
  }

  static func supports(_ path: String) -> Bool {
    let ext = fileExtension(path)
    return textExtensions.contains(ext) || imageExtensions.contains(ext)
      || documentExtensions.contains(ext) || audioExtensions.contains(ext)
      || videoExtensions.contains(ext)
  }

  static func checkDeadline(_ deadline: UInt64, _ cancelled: () -> Bool) throws {
    guard !cancelled(), GetTickCount64() < deadline else {
      throw WindowsError.unsupported("Content extraction cancelled or exceeded its time limit.")
    }
  }

  static func check(_ result: HRESULT, _ operation: String) throws {
    guard result >= 0 else { throw WindowsError.status(operation, result) }
  }

  /// A locked local handle prevents replacement while an OS reader opens the same file.
  static func openLocal(_ path: String) throws -> OwnedHandle {
    guard !path.dropFirst(2).contains(":"), let separator = path.lastIndex(of: "\\"),
      NativeSearchFiles.validFolder(String(path[..<separator])),
      let native = try? NativeFiles.windowsPath(path) else {
      throw WindowsError.unsupported("Content requires a local file without linked parents.")
    }
    let attributes = withWideString(native) { GetFileAttributesW($0) }
    // Recall flags are tested before opening: an open can hydrate a cloud placeholder.
    let excluded = DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT
      | FILE_ATTRIBUTE_OFFLINE) | 0x00040000 | 0x00400000
    guard attributes != DWORD(INVALID_FILE_ATTRIBUTES), attributes & excluded == 0 else {
      throw WindowsError.unsupported("Linked, offline and cloud-only content is excluded.")
    }
    let file = try OwnedHandle(withWideString(native) {
      CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN), nil)
    })
    var info = BY_HANDLE_FILE_INFORMATION()
    let media = audioExtensions.contains(fileExtension(path)) || videoExtensions.contains(fileExtension(path))
    guard GetFileInformationByHandle(file.raw, &info), info.dwFileAttributes & excluded == 0,
      media || (info.nFileSizeHigh == 0 && info.nFileSizeLow <= 268_435_456) else {
      throw WindowsError.unsupported("Content is unavailable or exceeds the 256 MiB file limit.")
    }
    var finalPath = [WCHAR](repeating: 0, count: 32768)
    let count = GetFinalPathNameByHandleW(file.raw, &finalPath, DWORD(finalPath.count), 0)
    let resolved = String(decoding: finalPath.prefix(Int(count)), as: UTF16.self)
    let expected = native.hasPrefix("\\\\?\\") ? native : "\\\\?\\" + native
    guard count > 0, count < finalPath.count, equalWindowsNames(resolved, expected) else {
      throw WindowsError.unsupported("Content path changed while it was opened.")
    }
    return file
  }

  static func extract(path: String, deadline: UInt64, startMilliseconds: Int64 = 0, startPage: Int = 1,
    includeMedia: Bool = true, cancelled: () -> Bool,
    emit: (SearchContentFragment) throws -> Void) throws -> SearchContentReport {
    try checkDeadline(deadline, cancelled)
    guard supports(path), startMilliseconds >= 0 else {
      return SearchContentReport(status: "Unsupported content format", truncated: false)
    }
    let file = try openLocal(path)
    defer { withExtendedLifetime(file) {} }
    let ext = fileExtension(path)
    if textExtensions.contains(ext) {
      return try text(file: file, deadline: deadline, cancelled: cancelled, emit: emit)
    }
    let initialized = RoInitialize(RO_INIT_MULTITHREADED)
    try check(initialized, "Initialize native content readers")
    defer { RoUninitialize() }
    if imageExtensions.contains(ext) {
      let image = try NativeSearchMedia.image(path: path)
      var fragment = SearchContentFragment(kind: "image", image: image)
      do { fragment.text = try NativeSearchMedia.ocr(image, deadline: deadline, cancelled: cancelled) }
      catch {
        try checkDeadline(deadline, cancelled)
        try emit(fragment)
        return SearchContentReport(status: "Image decoded; OCR unavailable", truncated: false)
      }
      try emit(fragment)
      return SearchContentReport(status: "Image and OCR", truncated: false)
    }
    if documentExtensions.contains(ext) {
      if ext == "pdf" {
        return try NativeSearchPDF.extract(path: path, startPage: startPage, deadline: deadline,
          cancelled: cancelled, emit: emit)
      }
      return try filtered(path: path, deadline: deadline, cancelled: cancelled, emit: emit)
    }
    guard includeMedia else {
      return SearchContentReport(status: "Audio/video requires the multimodal encoders", truncated: false)
    }
    return try NativeSearchMedia.extract(path: path, video: videoExtensions.contains(ext),
      startMilliseconds: startMilliseconds, deadline: deadline, cancelled: cancelled, emit: emit)
  }

  private static func text(file: borrowing OwnedHandle, deadline: UInt64, cancelled: () -> Bool,
    emit: (SearchContentFragment) throws -> Void) throws -> SearchContentReport {
    var bytes = [UInt8](repeating: 0, count: 1_048_576), count: DWORD = 0
    guard ReadFile(file.raw, &bytes, DWORD(bytes.count), &count, nil) else {
      throw WindowsError.api("Read bounded content", GetLastError())
    }
    bytes.removeLast(bytes.count - Int(count))
    guard let value = NativeSearchFiles.decodeSnippet(bytes) else {
      return SearchContentReport(status: "Unsupported text encoding or binary content", truncated: false)
    }
    let fragments = chunks(value)
    for fragment in fragments {
      try checkDeadline(deadline, cancelled)
      try emit(fragment)
    }
    return SearchContentReport(status: "UTF-8/UTF-16 content",
      truncated: count == 1_048_576 || fragments.count == 64)
  }

  static func chunks(_ value: String) -> [SearchContentFragment] {
    var result: [SearchContentFragment] = [], current = "", firstLine = 1, line = 1
    for part in value.split(separator: "\n", omittingEmptySubsequences: false) {
      var remaining = part[...]
      while !remaining.isEmpty {
        let available = 2048 - current.count
        let prefix = remaining.prefix(available)
        current += prefix
        remaining = remaining.dropFirst(prefix.count)
        if current.count == 2048 {
          result.append(SearchContentFragment(kind: "text", text: current, line: firstLine))
          if result.count == 64 { return result }
          current = ""; firstLine = line
        }
      }
      current += "\n"
      if current.count >= 2048 {
        result.append(SearchContentFragment(kind: "text", text: current, line: firstLine))
        if result.count == 64 { return result }
        current = ""; firstLine = line + 1
      }
      line += 1
    }
    if !current.trimmingWhitespace().isEmpty {
      result.append(SearchContentFragment(kind: "text", text: current, line: firstLine))
    }
    return result
  }

  private static func filtered(path: String, deadline: UInt64, cancelled: () -> Bool,
    emit: (SearchContentFragment) throws -> Void) throws -> SearchContentReport {
    var pointer: UnsafeMutableRawPointer?
    let loaded = withWideString(try NativeFiles.windowsPath(path)) { LoadIFilter($0, nil, &pointer) }
    guard loaded >= 0, let pointer else {
      return SearchContentReport(status: "No installed document filter for this format", truncated: false)
    }
    let filter = SearchContentReference(pointer.assumingMemoryBound(to: IFilter.self))
    var flags: ULONG = 0
    try check(filter.raw.pointee.lpVtbl.pointee.Init(filter.raw,
      ULONG(IFILTER_INIT_CANON_PARAGRAPHS.rawValue | IFILTER_INIT_CANON_HYPHENS.rawValue
        | IFILTER_INIT_CANON_SPACES.rawValue), 0, nil, &flags), "Initialize document filter")
    var emitted = 0, calls = 0
    while calls < 512, emitted < 64 {
      try checkDeadline(deadline, cancelled)
      var chunk = STAT_CHUNK()
      let status = filter.raw.pointee.lpVtbl.pointee.GetChunk(filter.raw, &chunk)
      if status == HRESULT(bitPattern: 0x80041700) { break } // FILTER_E_END_OF_CHUNKS
      try check(status, "Read document filter chunk")
      calls += 1
      guard chunk.flags.rawValue & CHUNK_TEXT.rawValue != 0 else { continue }
      var reads = 0
      while reads < 64, emitted < 64 {
        try checkDeadline(deadline, cancelled)
        var text = [WCHAR](repeating: 0, count: 2048), length = ULONG(text.count)
        let result = filter.raw.pointee.lpVtbl.pointee.GetText(filter.raw, &length, &text)
        if result == HRESULT(bitPattern: 0x80041701) || result == HRESULT(bitPattern: 0x80041705) { break }
        try check(result, "Read document text")
        guard length <= text.count else { throw WindowsError.unsupported("Invalid document filter output.") }
        if length > 0 {
          let value = String(decoding: text.prefix(Int(length)), as: UTF16.self)
          guard !value.utf16.contains(0) else { throw WindowsError.unsupported("Invalid document text.") }
          try emit(SearchContentFragment(kind: "document", text: value))
          emitted += 1
        }
        reads += 1
        if result == HRESULT(0x00041709) { break } // FILTER_S_LAST_TEXT
      }
    }
    // IFilter's chunk ids are not page numbers; never invent a PDF page locator.
    return SearchContentReport(status: emitted > 0 ? "Installed document filter" : "No extractable document text",
      truncated: calls == 512 || emitted == 64)
  }

  static func selfCheck() throws {
    let split = chunks("first\n" + String(repeating: "x", count: 4500) + "\nlast")
    guard split.count == 3, split[0].line == 1, split[1].line == 2,
      split.map(\.text).joined(separator: "").containsText("last"),
      chunks(String(repeating: "x", count: 200_000)).count == 64,
      supports("C:\\fixture\\document.PDF"), supports("C:\\fixture\\video.mp4"),
      !supports("C:\\fixture\\binary.exe") else {
      throw WindowsError.unsupported("Content chunk and format bounds failed.")
    }
    Console.writeLine("PASS: bounded content chunks, line locators and format recognition")
  }
}

final class SearchContentReference<T> {
  let raw: UnsafeMutablePointer<T>
  init(_ pointer: UnsafeMutablePointer<T>) { raw = pointer }
  deinit {
    let pointer = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: IUnknown.self)
    _ = pointer.pointee.lpVtbl.pointee.Release(pointer)
  }
}
