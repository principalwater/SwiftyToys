// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK
import WindowsDisplayABI

enum NativeSearchRates {
  private enum Failure: Error { case missingPair, invalidResponse }
  private static let maximumBytes = 4096
  private static let freshTicks: UInt64 = 6 * 3600 * 10_000_000
  private static let staleTicks: UInt64 = 7 * 24 * 3600 * 10_000_000

  static func today() -> String {
    var time = SYSTEMTIME()
    GetSystemTime(&time)
    func padded(_ value: WORD, width: Int) -> String {
      let text = String(value)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    return padded(time.wYear, width: 4) + "-" + padded(time.wMonth, width: 2)
      + "-" + padded(time.wDay, width: 2)
  }

  private static func ticks(_ time: FILETIME) -> UInt64 {
    UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)
  }

  /// Sends only a normalized currency pair; amounts and user queries remain local.
  static func current(from: String, to: String) throws -> (ReferenceRates, cached: Bool) {
    guard ReferenceRates.currency(from) == from, ReferenceRates.currency(to) == to else {
      throw WindowsError.unsupported("Choose two valid currency codes.")
    }
    let directory = try NativeFiles.path("SearchRates-v2")
    let cache = directory + "\\" + from + "-" + to + ".json"
    let date = today()
    let previous = cached(from: from, to: to)
    var attributes = WIN32_FILE_ATTRIBUTE_DATA(), now = FILETIME()
    GetSystemTimeAsFileTime(&now)
    if let previous,
      withWideString(cache, { GetFileAttributesExW($0, GetFileExInfoStandard, &attributes) }),
      isFresh(fetched: ticks(attributes.ftLastWriteTime), now: ticks(now)) {
      return (previous, true)
    }
    do {
      let bytes = try fetch(from: from, to: to)
      let rates = try parse(bytes, from: from, to: to, onDate: date)
      try? save(bytes, from: from, to: to, directory: directory)
      return (rates, false)
    } catch Failure.missingPair {
      throw WindowsError.unsupported("No daily reference rate is available for " + from + "/" + to + ".")
    } catch Failure.invalidResponse {
      throw WindowsError.unsupported("The daily rate response is invalid or stale. Check the system date and retry.")
    } catch {
      if let previous { return (previous, true) }
      throw WindowsError.unsupported("Daily reference rates are unavailable. Connect to the internet and retry.")
    }
  }

  private static func isFresh(fetched: UInt64, now: UInt64) -> Bool {
    now >= fetched && now - fetched < freshTicks
  }

  /// Reads only the bounded pair cache, including after an owned worker's network timeout.
  static func cached(from: String, to: String) -> ReferenceRates? {
    guard ReferenceRates.currency(from) == from, ReferenceRates.currency(to) == to,
      let directory = try? NativeFiles.path("SearchRates-v2"),
      (try? NativeEmbeddingAssets.inspect(directory, directory: true)) != nil else { return nil }
    let path = directory + "\\" + from + "-" + to + ".json"
    guard (try? NativeEmbeddingAssets.inspect(path, directory: false)) != nil else { return nil }
    var attributes = WIN32_FILE_ATTRIBUTE_DATA(), now = FILETIME()
    GetSystemTimeAsFileTime(&now)
    guard withWideString(path, { GetFileAttributesExW($0, GetFileExInfoStandard, &attributes) }),
      ticks(now) >= ticks(attributes.ftLastWriteTime),
      ticks(now) - ticks(attributes.ftLastWriteTime) <= staleTicks else { return nil }
    return try? parse(NativeFiles.read(path, maximum: maximumBytes),
      from: from, to: to, onDate: today())
  }

  private static func parse(_ bytes: [UInt8], from: String, to: String,
    onDate: String) throws -> ReferenceRates {
    do {
      guard bytes.count <= maximumBytes else { throw Failure.invalidResponse }
      let result = try bytes.withUnsafeBufferPointer { pointer in
        var reader = TokenizerJSONReader(bytes: pointer)
        let result = try reader.smallValue()
        reader.whitespace()
        guard reader.offset == pointer.count else { throw Failure.invalidResponse }
        return result
      }
      let rate: Double
      switch result["rate"] {
      case .number(let value): rate = value
      case .integer(let value): rate = Double(value)
      default: throw Failure.invalidResponse
      }
      guard result.object?.count == 4, result["base"]?.string == from,
        result["quote"]?.string == to, let date = result["date"]?.string else {
        throw Failure.invalidResponse
      }
      let rates = try ReferenceRates(date: date, base: from, rates: [to: rate])
      guard let age = rates.ageInDays(onDate: onDate), (-1...7).contains(age) else {
        throw Failure.invalidResponse
      }
      return rates
    } catch { throw Failure.invalidResponse }
  }

  private static func save(_ bytes: [UInt8], from: String, to: String,
    directory: String) throws {
    let app = try NativeFiles.directory()
    try NativeFiles.createDirectory(app)
    try NativeEmbeddingAssets.inspect(app, directory: true)
    try NativeEmbeddingAssets.privateDirectory(directory)
    let operation = try OwnedHandle(withWideString("Local\\SwiftyToys.ReferenceRates-"
      + NativeEmbeddingAssets.identity()) { CreateMutexW(nil, false, $0) })
    let ownership = WaitForSingleObject(operation.raw, 0)
    guard ownership == DWORD(WAIT_OBJECT_0) || ownership == 0x80 else { return }
    defer { ReleaseMutex(operation.raw) }
    var data = WIN32_FIND_DATAW()
    var entries: [(name: String, tick: UInt64)] = []
    var visited = 0
    let pattern = try NativeFiles.windowsPath(directory + "\\*.json")
    if let find = withWideString(pattern, { FindFirstFileW($0, &data) }),
      find != INVALID_HANDLE_VALUE {
      defer { _ = FindClose(find) }
      repeat {
        visited += 1
        guard visited <= 256 else { return }
        let name = withUnsafePointer(to: &data.cFileName) {
          $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(MAX_PATH))
              .prefix(while: { $0 != 0 }), as: UTF16.self)
          }
        }
        let parts = name.split(separator: "-")
        if parts.count == 2, parts[1].hasSuffix(".json"),
          ReferenceRates.currency(String(parts[0])) == String(parts[0]),
          ReferenceRates.currency(String(parts[1].dropLast(5))) == String(parts[1].dropLast(5)),
          data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0 {
          entries.append((name, ticks(data.ftLastWriteTime)))
        }
      } while FindNextFileW(find, &data)
    }
    let name = from + "-" + to + ".json"
    let others = entries.filter { $0.name != name }
    for entry in others.sorted(by: { $0.tick < $1.tick }).prefix(max(0, others.count - 31)) {
      try NativeFiles.remove(directory + "\\" + entry.name)
    }
    try NativeFiles.write(bytes, to: directory + "\\" + name)
  }

  private static func fetch(from: String, to: String) throws -> [UInt8] {
    guard let session = withWideString("SwiftyToys/" + AppVersion.string, {
      WinHttpOpen($0, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0)
    }) else { throw WindowsError.api("Connect to daily reference rates", GetLastError()) }
    defer { WinHttpCloseHandle(session) }
    guard WinHttpSetTimeouts(session, 3000, 3000, 3000, 3000) else {
      throw WindowsError.api("Bound the reference-rate request", GetLastError())
    }
    guard let connection = withWideString("api.frankfurter.dev", {
      WinHttpConnect(session, $0, INTERNET_PORT(443), 0)
    }) else { throw WindowsError.api("Connect to daily reference rates", GetLastError()) }
    defer { WinHttpCloseHandle(connection) }
    let route = "/v2/rate/" + from + "/" + to
    guard let request = withWideString("GET", { verb in withWideString(route, {
      WinHttpOpenRequest(connection, verb, $0, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE))
    }) }) else { throw WindowsError.api("Request daily reference rates", GetLastError()) }
    defer { WinHttpCloseHandle(request) }
    var redirect = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
    guard WinHttpSetOption(request, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &redirect,
      DWORD(MemoryLayout<DWORD>.size)), WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0),
      WinHttpReceiveResponse(request, nil) else {
      throw WindowsError.api("Fetch daily reference rates", GetLastError())
    }
    var status: DWORD = 0, size = DWORD(MemoryLayout<DWORD>.size)
    guard WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER),
      nil, &status, &size, nil) else {
      throw WindowsError.api("Read reference-rate status", GetLastError())
    }
    if status == 404 || status == 422 { throw Failure.missingPair }
    guard status == 200 else {
      throw WindowsError.unsupported("Daily reference rates are unavailable. Retry when online.")
    }
    var bytes: [UInt8] = [], chunk = [UInt8](repeating: 0, count: maximumBytes)
    let deadline = GetTickCount64() + 6000
    while true {
      var count: DWORD = 0
      guard GetTickCount64() < deadline else {
        throw WindowsError.unsupported("The reference-rate request exceeded its time or size limit.")
      }
      guard WinHttpReadData(request, &chunk, DWORD(chunk.count), &count) else {
        throw WindowsError.api("Read daily reference rates", GetLastError())
      }
      guard bytes.count + Int(count) <= maximumBytes else { throw Failure.invalidResponse }
      if count == 0 { return bytes }
      bytes += chunk.prefix(Int(count))
    }
  }

  static func selfCheck() throws {
    let valid = Array("{\"date\":\"2026-10-14\",\"base\":\"USD\",\"quote\":\"GBP\",\"rate\":0.75}".utf8)
    let rate = try parse(valid, from: "USD", to: "GBP", onDate: "2026-10-14")
    guard rate.rates["GBP"] == 0.75, rate.source == ReferenceRates.sourceName,
      isFresh(fetched: 0, now: freshTicks - 1), !isFresh(fetched: 0, now: freshTicks),
      !isFresh(fetched: 2, now: 1) else {
      throw WindowsError.unsupported("Reference-rate parsing or six-hour cache boundary failed.")
    }
    for date in ["2026-10-12", "2026-10-22"] {
      do {
        _ = try parse(valid, from: "USD", to: "GBP", onDate: date)
        throw WindowsError.unsupported("Future or expired reference rates were accepted.")
      } catch Failure.invalidResponse {}
    }
    for input in [valid + [0], Array("{\"date\":\"2026-10-14\",\"base\":\"USD\",\"quote\":\"GBP\",\"rate\":0}".utf8)] {
      do {
        _ = try parse(input, from: "USD", to: "GBP", onDate: "2026-10-14")
        throw WindowsError.unsupported("Invalid reference rates were accepted.")
      } catch Failure.invalidResponse {}
    }
    do {
      _ = try parse(valid, from: "EUR", to: "GBP", onDate: "2026-10-14")
      throw WindowsError.unsupported("A mismatched reference-rate pair was accepted.")
    } catch Failure.invalidResponse {}
    Console.writeLine("PASS: daily pair JSON, positive finite rate, exact pair/source/date validation and bounded cache age; no network or installed cache changed")
  }

  /// Generated cache fixtures use a caller-owned private directory and make no requests.
  static func selfCheckCache(directory: String) throws {
    let root = directory + "\\SearchRates-v2"
    var codes: [String] = []
    for index in 0..<33 {
      codes.append("X" + String(UnicodeScalar(65 + index / 26)!)
        + String(UnicodeScalar(65 + index % 26)!))
    }
    defer {
      for code in codes { try? NativeFiles.remove(root + "\\USD-" + code + ".json") }
      _ = withWideString(root) { RemoveDirectoryW($0) }
    }
    for code in codes {
      let bytes = StateJSON.encode(["date": .string(today()), "base": .string("USD"),
        "quote": .string(code), "rate": .unsigned(1)])
      try save(bytes, from: "USD", to: code, directory: root)
    }
    var count = 0
    for code in codes where try NativeFiles.exists(root + "\\USD-" + code + ".json") { count += 1 }
    guard count == 32, try NativeFiles.exists(root + "\\USD-" + codes[32] + ".json") else {
      throw WindowsError.unsupported("The currency pair cache exceeded its 32-pair capacity.")
    }
    Console.writeLine("PASS: generated native pair cache retained 32 of 33 pairs and latest pair; fixture files removed")
  }

  /// Verifies the actual native HTTPS path without reading or writing the application cache.
  static func selfCheckLive() throws {
    for quote in ["RUB", "GBP", "JPY", "INR"] {
      let rate = try parse(fetch(from: "USD", to: quote), from: "USD", to: quote, onDate: today())
      guard rate.rates[quote] != nil else { throw Failure.invalidResponse }
      Console.writeLine("PASS: HTTPS daily pair USD/" + quote + " · " + rate.date)
    }
    do {
      _ = try fetch(from: "USD", to: "XYZ")
      throw WindowsError.unsupported("Unavailable pair unexpectedly returned a rate.")
    } catch Failure.missingPair {}
    Console.writeLine("PASS: unavailable HTTPS pair returns a distinct bounded error; no application cache changed")
  }
}
