// SPDX-License-Identifier: MIT
import BrightnessCore
import Synchronization
import WinSDK

let searchLibraryMessage: UINT = 0x8062

enum NativeSearchLibraryActivity {
  private static let last = Mutex(UInt64(0))
  static func touch() { last.withLock { $0 = GetTickCount64() } }
  static func age() -> UInt64 {
    let tick = last.withLock { $0 }, now = GetTickCount64()
    return now >= tick ? now - tick : 0
  }
}

private struct SearchLibraryFailure: Sendable {
  let kind: UInt32
  let id: Int64
}

private struct SearchLibraryConfiguration {
  var preferences: SearchPreferences
  var reset = false
  var refresh = true
  var failure: SearchLibraryFailure?
  func encoded() throws -> [UInt8] {
    var writer = NativeEmbeddingWriter()
    writer.integer(10)
    let flags: UInt32 = (preferences.enabled ? 1 : 0) | (preferences.semantic ? 2 : 0)
      | (preferences.media ? 4 : 0) | (preferences.allLocalDrives ? 8 : 0)
      | (preferences.indexPaused ? 16 : 0)
    writer.integer(flags)
    writer.integer((reset ? 1 : 0) | (refresh ? 2 : 0))
    try writer.string(preferences.modelRepository, maximum: 192)
    try writer.string(preferences.folder, maximum: 24000)
    try writer.string(preferences.exclusions, maximum: 24000)
    writer.integer(failure?.kind ?? 0)
    try writer.string(failure.map { String($0.id) } ?? "", maximum: 32)
    return writer.bytes
  }
  static func decoded(_ reader: inout NativeEmbeddingReader) throws -> Self {
    let flags = try reader.integer(), reset = try reader.integer()
    guard flags & ~31 == 0, reset & ~3 == 0 else {
      throw WindowsError.unsupported("Invalid library configuration flags.")
    }
    var preferences = SearchPreferences(contents: "")
    preferences.enabled = flags & 1 != 0
    preferences.semantic = flags & 2 != 0
    preferences.media = flags & 4 != 0
    preferences.allLocalDrives = flags & 8 != 0
    preferences.indexPaused = flags & 16 != 0
    preferences.modelRepository = try reader.string(maximum: 192)
    preferences.folder = try reader.string(maximum: 24000)
    preferences.exclusions = try reader.string(maximum: 24000)
    let kind = try reader.integer(), id = try reader.string(maximum: 32)
    try reader.finished()
    guard NativeSearchModelCatalog.validRepositoryID(preferences.modelRepository),
      preferences.folders.count <= 32, preferences.excludedPaths.count <= 64,
      preferences.folder.utf8.count + preferences.exclusions.utf8.count <= 24000,
      preferences.folders.allSatisfy({ NativeSearchLibraryScanner.canonical($0) != nil }),
      preferences.excludedPaths.allSatisfy({ NativeSearchLibraryScanner.canonical($0) != nil }),
      kind <= 2, kind == 0 ? id.isEmpty : (Int64(id) ?? 0) > 0 else {
      throw WindowsError.unsupported("Invalid local library locations or task identity.")
    }
    return .init(preferences: preferences, reset: reset & 1 != 0, refresh: reset & 2 != 0,
      failure: kind == 0 ? nil : .init(kind: kind, id: Int64(id)!))
  }
}

private final class SearchLibraryChild: @unchecked Sendable {
  let channel: NativeEmbeddingChannel
  let child: NativeEmbeddingProcess
  init(cancelled: @escaping @Sendable () -> Bool) throws {
    let name = NativeEmbeddingChannel.prefix + (try NativeEmbeddingAssets.guid())
    channel = try NativeEmbeddingChannel(serverName: name)
    child = try NativeEmbeddingProcess(executable: executablePath(),
      arguments: ["--library-worker", name])
    do { try channel.connect(child: child, cancelled: cancelled) }
    catch { child.stop(wait: true); throw error }
  }
}

private final class RetiredLibraryWatch: @unchecked Sendable {
  let watcher: NativeSearchLibraryWatcher
  init(_ watcher: NativeSearchLibraryWatcher) { self.watcher = watcher }
}

private enum RetiredLibraryWatches {
  private static let pending = Mutex<[RetiredLibraryWatch]>([])
  static func stop(_ watcher: NativeSearchLibraryWatcher) {
    if !watcher.stop() { pending.withLock { $0.append(RetiredLibraryWatch(watcher)) } }
  }
  static func reap() -> Int {
    pending.withLock { watches in
      watches.removeAll { $0.watcher.finishStopped() }
      return watches.count
    }
  }
}

/// The supervisor owns only its isolated job. UI and physical-input work never waits for indexing.
final class NativeSearchLibraryManager: @unchecked Sendable {
  private struct State: Sendable {
    var preferences: SearchPreferences
    var generation: UInt64 = 0
    var reset = false
    var refresh = true
    var stopped = false
    var posted = false
    var pending: String?
    var worker: SearchLibraryChild?
  }
  private let state: Mutex<State>
  private let destination: MessageDestination
  private let wake: OwnedHandle
  private let finished: OwnedHandle
  private var thread: NativeThread?
  init(destination: MessageDestination, preferences: SearchPreferences) throws {
    self.destination = destination
    state = Mutex(State(preferences: preferences))
    wake = try OwnedHandle(CreateEventW(nil, false, false, nil))
    finished = try OwnedHandle(CreateEventW(nil, true, false, nil))
    thread = try NativeThread(name: "SwiftyToys library supervisor") { self.run() }
  }
  func take() -> String? {
    state.withLock {
      let result = $0.pending
      $0.pending = nil; $0.posted = false
      return result
    }
  }
  private func publish(_ text: String) {
    state.withLock {
      guard !$0.stopped else { return }
      $0.pending = text
      if !$0.posted { $0.posted = destination.post(searchLibraryMessage) }
    }
  }
  func apply(_ preferences: SearchPreferences) {
    let worker = state.withLock { state -> SearchLibraryChild? in
      guard !state.stopped else { return nil }
      state.refresh = state.refresh || state.preferences.allLocalDrives != preferences.allLocalDrives
        || state.preferences.folders != preferences.folders
        || state.preferences.excludedPaths != preferences.excludedPaths
      state.preferences = preferences; state.generation &+= 1
      let worker = state.worker; state.worker = nil; return worker
    }
    worker?.child.stop()
    _ = SetEvent(wake.raw)
  }
  func refresh() {
    let worker = state.withLock { state -> SearchLibraryChild? in
      guard !state.stopped else { return nil }
      state.generation &+= 1; state.refresh = true
      let worker = state.worker; state.worker = nil; return worker
    }
    worker?.child.stop()
    _ = SetEvent(wake.raw)
  }
  func requestReset() {
    state.withLock { if !$0.stopped { $0.reset = true } }
    refresh()
  }
  func stop() {
    let worker = state.withLock { state -> SearchLibraryChild? in
      state.stopped = true; state.pending = nil; state.posted = false
      let worker = state.worker; state.worker = nil; return worker
    }
    _ = SetEvent(wake.raw)
    worker?.child.stop()
    _ = waitForWindowEvent(finished.raw, timeout: 6000)
    if let worker { _ = waitForWindowEvent(worker.child.process.raw, timeout: 5000) }
  }
  private func changed(_ generation: UInt64) -> Bool {
    state.withLock { $0.stopped || $0.generation != generation }
  }
  private func run() {
    var watcher: NativeSearchLibraryWatcher?
    var activeWorker: SearchLibraryChild?
    func stopWorker() {
      let stored = state.withLock { state -> SearchLibraryChild? in
        let worker = state.worker; state.worker = nil; return worker
      }
      let active = activeWorker; activeWorker = nil
      // Settings can detach the active child before cancellation reaches this backend thread.
      active?.child.stop(wait: true)
      if stored !== active { stored?.child.stop(wait: true) }
    }
    defer {
      stopWorker()
      if let watcher { RetiredLibraryWatches.stop(watcher) }
      _ = SetEvent(finished.raw)
    }
    _ = SetThreadPriority(GetCurrentThread(), Int32(-1))
    var configured: UInt64?, failed: SearchLibraryFailure?, failedGeneration: UInt64?
    var watchedScope = "", dirty = Set<String>()
    while true {
      let snapshot = state.withLock { ($0.preferences, $0.generation, $0.reset, $0.stopped, $0.refresh) }
      if snapshot.3 { return }
      let preferences = snapshot.0, generation = snapshot.1
      if failedGeneration != generation { failed = nil }
      // A pending scope change still needs one configuration to prune excluded rows while paused.
      if !snapshot.2 && (!preferences.enabled || (preferences.indexPaused && !snapshot.4)) {
        stopWorker(); configured = nil
        if !preferences.enabled, let existing = watcher {
          RetiredLibraryWatches.stop(existing); watcher = nil
          watchedScope = ""; dirty.removeAll()
        }
        publish(preferences.enabled ? "Library indexing is paused." : "Search library is disabled.")
        _ = WaitForSingleObject(wake.raw, DWORD(INFINITE))
        continue
      }
      var currentTask: SearchLibraryFailure?
      var heavy = false
      var intentionallyCancelled = false
      let userInterrupted = Mutex(false)
      do {
        let roots = (preferences.allLocalDrives ? NativeSearchLibraryScanner.localDrives()
          : preferences.folders).compactMap(NativeSearchLibraryScanner.canonical)
        let scope = roots.sorted().joined(separator: "\n") + "\0"
          + preferences.excludedPaths.sorted().joined(separator: "\n")
        if watchedScope != scope { configured = nil }
        var retired = RetiredLibraryWatches.reap()
        if watchedScope != scope, let existing = watcher {
          for path in existing.pollChangedDirectories() { dirty.insert(path) }
          RetiredLibraryWatches.stop(existing); watcher = nil
          retired = RetiredLibraryWatches.reap()
        }
        if watcher == nil, retired < 4, preferences.enabled {
          watcher = try NativeSearchLibraryWatcher(roots: roots, excludedPaths: preferences.excludedPaths)
          watchedScope = scope
          // Subscribe before catch-up: edits during a retired/restarted scope are covered by this pass.
          dirty = Set(roots)
        }
        for path in watcher?.pollChangedDirectories() ?? [] {
          dirty.insert(path)
          if dirty.count > 128 {
            let affected = dirty.compactMap { path in
              roots.first { path == $0 || path.hasPrefix($0.hasSuffix("\\") ? $0 : $0 + "\\") }
            }
            dirty = Set(affected)
          }
        }
        let worker: SearchLibraryChild
        if let existing = state.withLock({ $0.worker }), !existing.child.ended {
          worker = existing; activeWorker = existing
        } else {
          stopWorker()
          worker = try SearchLibraryChild(cancelled: { self.changed(generation) })
          activeWorker = worker
          let accepted = state.withLock { state -> Bool in
            guard !state.stopped, state.generation == generation else { return false }
            state.worker = worker; return true
          }
          guard accepted else { stopWorker(); continue }
          configured = nil
        }
        let request: [UInt8]
        var delivered: [String] = []
        if configured != generation || snapshot.2 {
          request = try SearchLibraryConfiguration(preferences: preferences,
            reset: snapshot.2, refresh: snapshot.4, failure: failed).encoded()
        } else {
          heavy = NativeSearchLibraryRuntime.mayDoHeavyWork()
          var writer = NativeEmbeddingWriter()
          writer.integer(11); writer.integer(heavy ? 1 : 0)
          var bytes = 0
          for path in dirty.sorted().prefix(128) {
            guard bytes + path.utf8.count + 4 <= 524288 else { break }
            delivered.append(path); bytes += path.utf8.count + 4
          }
          writer.integer(UInt32(delivered.count))
          for path in delivered { try writer.string(path, maximum: 65536) }
          request = writer.bytes
        }
        let deadline = GetTickCount64() + 60000
        let heavyRequest = heavy
        let gate = Mutex((tick: GetTickCount64(), allowed: true))
        let cancelled: @Sendable () -> Bool = {
          if self.changed(generation) { return true }
          guard heavyRequest else { return false }
          if NativeSearchLibraryRuntime.inputAge() < 30000 || NativeSearchLibraryActivity.age() < 10000 {
            userInterrupted.withLock { $0 = true }; return true
          }
          return gate.withLock {
            let now = GetTickCount64()
            if now - $0.tick >= 1000 {
              $0.tick = now; $0.allowed = NativeSearchLibraryRuntime.mayDoHeavyWork()
            }
            if !$0.allowed { userInterrupted.withLock { $0 = true } }
            return !$0.allowed
          }
        }
        try worker.channel.send(request, deadline: deadline, cancelled: cancelled)
        var delay: DWORD = 2000
        while true {
          var response = NativeEmbeddingReader(bytes: try worker.channel.receive(
            deadline: deadline, cancelled: cancelled))
          let code = try response.integer()
          if code == 4 {
            let kind = try response.integer(), id = try response.string(maximum: 32)
            guard (1...2).contains(kind), let id = Int64(id), id > 0 else {
              throw WindowsError.unsupported("Invalid library worker task identity.")
            }
            try response.finished(); currentTask = .init(kind: kind, id: id)
            continue
          }
          if code == 3 {
            let reason = try response.string(maximum: 2048); try response.finished()
            throw WindowsError.unsupported(reason)
          }
          guard code == 2 else { throw WindowsError.unsupported("Invalid library worker response.") }
          let text = try response.string(maximum: 2048)
          delay = try response.integer()
          guard delay == 2000 || delay == 20000 else {
            throw WindowsError.unsupported("Invalid library worker pacing.")
          }
          try response.finished()
          guard !changed(generation) else {
            throw WindowsError.api("Library configuration changed", DWORD(ERROR_CANCELLED))
          }
          configured = generation; failed = nil
          state.withLock { if $0.generation == generation { $0.reset = false; $0.refresh = false } }
          for path in delivered { dirty.remove(path) }
          var notice = text
          if let watcher, watcher.unavailableRoots > 0 {
            notice += " · change notifications unavailable for \(watcher.unavailableRoots) locations; Refresh to rescan"
          }
          if retired >= 4 { notice += " · earlier change notifications are still draining" }
          publish(notice)
          break
        }
        _ = WaitForSingleObject(wake.raw, delay)
      } catch {
        intentionallyCancelled = changed(generation) || userInterrupted.withLock({ $0 }) || (heavy &&
          (NativeSearchLibraryRuntime.inputAge() < 30000 || NativeSearchLibraryActivity.age() < 10000))
        stopWorker(); configured = nil
        if intentionallyCancelled {
          let memory = !NativeSearchLibraryRuntime.hasMemoryHeadroom()
          publish(memory ? "Library saved. Content work waits for available memory."
            : "Library saved. Content indexing resumes after user activity stops.")
          _ = WaitForSingleObject(wake.raw, memory ? 20000 : 2000)
        } else {
          failed = currentTask; failedGeneration = generation
          let reason = String(decoding: String(describing: error).utf8.prefix(512), as: UTF8.self)
          publish("Library worker stopped safely. " + reason + " Completed index data is retained; retrying in 20 seconds.")
          _ = WaitForSingleObject(wake.raw, 20000)
        }
      }
    }
  }
}

enum NativeSearchLibraryRuntime {
  static func namespace(preferences: SearchPreferences, model: NativeSearchModelDescriptor) -> String {
    model.fingerprint + ":content-v2:tokenwindows:" + (preferences.media
      ? "media:" + NativeEmbeddingMediaEngine.fingerprint
      : "text")
  }
  static func inputAge() -> UInt64 {
    var value = LASTINPUTINFO()
    value.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
    guard GetLastInputInfo(&value) else { return 0 }
    return UInt64(DWORD(truncatingIfNeeded: GetTickCount64()) &- value.dwTime)
  }
  private static func fullscreen() -> Bool {
    guard let window = GetForegroundWindow(), !IsIconic(window) else { return false }
    var name = [WCHAR](repeating: 0, count: 64)
    let count = GetClassNameW(window, &name, Int32(name.count))
    let kind = String(decoding: name.prefix(Int(max(0, count))), as: UTF16.self)
    if ["Progman", "WorkerW", "Shell_TrayWnd"].contains(kind) { return false }
    var rectangle = RECT(), monitor = MONITORINFO()
    monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    guard GetWindowRect(window, &rectangle),
      GetMonitorInfoW(MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) else { return true }
    return rectangle.left <= monitor.rcMonitor.left && rectangle.top <= monitor.rcMonitor.top
      && rectangle.right >= monitor.rcMonitor.right && rectangle.bottom >= monitor.rcMonitor.bottom
  }
  static func mayDoHeavyWork() -> Bool {
    var power = SYSTEM_POWER_STATUS()
    guard GetSystemPowerStatus(&power), power.SystemStatusFlag != 1 else { return false }
    return inputAge() >= 30000 && NativeSearchLibraryActivity.age() >= 10000
      && hasMemoryHeadroom() && !fullscreen()
  }
  static func hasMemoryHeadroom(minimum: UInt64 = 512 * 1024 * 1024) -> Bool {
    var memory = MEMORYSTATUSEX()
    memory.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
    guard GlobalMemoryStatusEx(&memory) else { return false }
    return memory.dwMemoryLoad < 90 && memory.ullAvailPhys >= minimum
      && memory.ullAvailPageFile >= minimum
  }
  static func idleModelsMayBeReleased(pendingFile: Bool, pendingVector: Bool,
    fragmentLimitReached: Bool) -> Bool {
    !pendingVector && (!pendingFile || fragmentLimitReached)
  }
  static func selfCheck() throws {
    var preferences = SearchPreferences(contents: "enabled=0\nsemantic=0\nallLocalDrives=0\nfolder=C:\\fixture\nexclude=C:\\fixture\\excluded\n")
    let configuration = SearchLibraryConfiguration(preferences: preferences, reset: true,
      refresh: false, failure: .init(kind: 2, id: 42))
    var reader = NativeEmbeddingReader(bytes: try configuration.encoded())
    guard try reader.integer() == 10 else { throw WindowsError.unsupported("Library configuration header failed.") }
    let decoded = try SearchLibraryConfiguration.decoded(&reader)
    guard decoded.reset, !decoded.refresh, decoded.preferences.folder == preferences.folder,
      decoded.failure?.id == 42 else { throw WindowsError.unsupported("Library configuration roundtrip failed.") }
    var malformed = try configuration.encoded()
    malformed[4] = 255
    var rejected = false
    do {
      var value = NativeEmbeddingReader(bytes: malformed)
      _ = try value.integer(); _ = try SearchLibraryConfiguration.decoded(&value)
    } catch { rejected = true }
    guard rejected else { throw WindowsError.unsupported("Library accepted unsafe configuration flags.") }
    let model = NativeSearchModelDescriptor.recommended
    let plainNamespace = namespace(preferences: preferences, model: model)
    preferences.media = true
    guard namespace(preferences: preferences, model: model) != plainNamespace,
      namespace(preferences: preferences, model: model).containsText(NativeEmbeddingAssets.mediaFiles[0].sha256)
    else { throw WindowsError.unsupported("Media index namespace omitted its encoder identity.") }
    NativeSearchLibraryActivity.touch()
    guard !mayDoHeavyWork() else { throw WindowsError.unsupported("Active Search did not block heavy indexing.") }
    for (file, vector, limit, release) in [
      (true, false, true, true), (true, true, true, false), (true, false, false, false),
      (false, false, false, true), (false, true, false, false),
    ] {
      guard idleModelsMayBeReleased(pendingFile: file, pendingVector: vector,
        fragmentLimitReached: limit) == release else {
        throw WindowsError.unsupported("Library model retirement ignored actionable work or the fragment budget.")
      }
    }
    let window = try OwnedLibraryFixtureWindow(withWideString("STATIC") { name in
      CreateWindowExW(0, name, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil, nil, nil)
    })
    let manager = try NativeSearchLibraryManager(destination: MessageDestination(window.raw),
      preferences: SearchPreferences(contents: "enabled=0\n"))
    manager.stop()
    manager.refresh()
    manager.apply(SearchPreferences(contents: "enabled=0\n"))
    guard manager.take() == nil else { throw WindowsError.unsupported("Stopped library supervisor retained a delivery.") }
    try fixtureIndex()
    Console.writeLine("PASS: library protocol trust bounds, model/media namespaces, activity gating, stopped/disabled supervisor, bounded text extraction, terminal unsupported files and derived-only reset; no corpus scanned or model loaded")
  }
  private static func fixtureIndex() throws {
    let root = try NativeSearchFiles.knownFolder(FOLDERID_Profile)
      + "\\SwiftyToys-Library-" + NativeEmbeddingAssets.guid()
    let documents = root + "\\documents", database = root + "\\library.sqlite3"
    try NativeEmbeddingAssets.privateDirectory(root)
    try NativeEmbeddingAssets.privateDirectory(documents)
    defer {
      for name in ["sample.swift", "binary.txt", "unsupported.dat"] { try? NativeFiles.remove(documents + "\\" + name) }
      for suffix in ["", "-journal", "-wal", "-shm"] { try? NativeFiles.remove(database + suffix) }
      _ = withWideString(documents) { RemoveDirectoryW($0) }
      _ = withWideString(root) { RemoveDirectoryW($0) }
    }
    try NativeFiles.write(Array("let answer = 42\n".utf8), to: documents + "\\sample.swift")
    try NativeFiles.write([255], to: documents + "\\binary.txt")
    try NativeFiles.write([0], to: documents + "\\unsupported.dat")
    var preferences = SearchPreferences(contents: "enabled=1\nsemantic=0\nallLocalDrives=0\n")
    preferences.folder = documents
    do {
      let work = try SearchLibraryWork(configuration: .init(preferences: preferences), databasePath: database)
      defer { _ = work.stop() }
      for _ in 0..<8 { try work.step(heavy: true, deadline: GetTickCount64() + 60000, report: { _ in }) }
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      let status = try check.status()
      guard status.files == 3, status.fragments == 1, status.pendingFiles == 0,
        status.failedFiles == 2, status.vectors == 0,
        try check.searchText("answer", cancelled: { false }).count == 1 else {
        throw WindowsError.unsupported("Bounded library fixture content or terminal outcomes failed.")
      }
      for _ in 0..<3 { try work.step(heavy: true, deadline: GetTickCount64() + 60000, report: { _ in }) }
      guard try check.status().pendingFiles == 0 else { throw WindowsError.unsupported("Unsupported library files were retried.") }
    }
    preferences.indexPaused = true
    do {
      let work = try SearchLibraryWork(configuration: .init(preferences: preferences, reset: true), databasePath: database)
      defer { _ = work.stop() }
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      let status = try check.status()
      guard status.files == 0, status.fragments == 0, status.paused,
        try NativeFiles.exists(documents + "\\sample.swift"),
        try NativeFiles.exists(documents + "\\binary.txt") else {
        throw WindowsError.unsupported("Paused derived-index reset affected fixture source files.")
      }
    }
  }
  static func runWorker(pipeName: String) -> Int32 {
    do {
      guard SetPriorityClass(GetCurrentProcess(), DWORD(PROCESS_MODE_BACKGROUND_BEGIN)) else {
        throw WindowsError.api("Set library background priority", GetLastError())
      }
      defer { _ = SetPriorityClass(GetCurrentProcess(), DWORD(PROCESS_MODE_BACKGROUND_END)) }
      let channel = try NativeEmbeddingChannel(clientName: pipeName)
      var library: SearchLibraryWork?
      while true {
        let body: [UInt8]
        do { body = try channel.receive(deadline: GetTickCount64() + 60000) }
        catch { return 0 }
        let deadline = GetTickCount64() + 60000
        var operation: UInt32 = 0
        do {
          var request = NativeEmbeddingReader(bytes: body)
          operation = try request.integer()
          if operation == 10 {
            let configuration = try SearchLibraryConfiguration.decoded(&request)
            if let previous = library, !previous.stop() { return 0 }
            library = try SearchLibraryWork(configuration: configuration)
          } else if operation == 11 {
            let heavy = try request.integer(), count = try request.integer()
            guard heavy <= 1, count <= 128, let library else { throw WindowsError.unsupported("Invalid library step.") }
            var directories: [String] = []
            for _ in 0..<count {
              let path = try request.string(maximum: 65536)
              guard NativeSearchLibraryScanner.canonical(path) != nil else { throw WindowsError.unsupported("Invalid library change location.") }
              directories.append(path)
            }
            try request.finished()
            try library.step(heavy: heavy != 0, directories: directories, deadline: deadline) { task in
              var progress = NativeEmbeddingWriter()
              progress.integer(4); progress.integer(task.kind)
              try progress.string(String(task.id), maximum: 32)
              try channel.send(progress.bytes, deadline: deadline)
            }
          } else { throw WindowsError.unsupported("Invalid library operation.") }
          guard let library else { throw WindowsError.unsupported("Library configuration is unavailable.") }
          let status = try library.status()
          var response = NativeEmbeddingWriter(); response.integer(2)
          try response.string(status.text, maximum: 2048); response.integer(status.delay)
          try channel.send(response.bytes, deadline: deadline)
        } catch {
          var response = NativeEmbeddingWriter(); response.integer(3)
          // Configuration errors describe metadata/database operations; filter diagnostics may contain private paths.
          let reason = operation == 10
            ? String(decoding: String(describing: error).utf8.prefix(512), as: UTF8.self) : ""
          try response.string("The local library could not complete this step. " + reason, maximum: 2048)
          try channel.send(response.bytes, deadline: deadline)
        }
      }
    } catch { return 1 }
  }
}

private struct OwnedLibraryFixtureWindow: ~Copyable {
  let raw: HWND
  init(_ raw: HWND?) throws {
    guard let raw else { throw WindowsError.api("Create isolated library fixture window", GetLastError()) }
    self.raw = raw
  }
  deinit { _ = DestroyWindow(raw) }
}

private final class SearchLibraryWork {
  private let preferences: SearchPreferences
  private let model: NativeSearchModelDescriptor?
  private let namespace: String
  private let store: NativeSearchLibraryStore
  private var scanner: NativeSearchLibraryScanner?
  private var engine: NativeEmbeddingEngine?
  private var mediaEngine: NativeEmbeddingMediaEngine?
  private var phase = "Library configured"
  private var modelReady = false
  private var mediaReady = false
  private var fragmentLimitReached = false
  private var storageFull = false
  private var memoryWaiting = false
  private var slowWait = false
  init(configuration: SearchLibraryConfiguration, databasePath: String? = nil) throws {
    let preferences = configuration.preferences
    self.preferences = preferences
    let model = try? NativeSearchModelCatalog.descriptor(repositoryID: preferences.modelRepository)
    self.model = model
    namespace = model.map { NativeSearchLibraryRuntime.namespace(preferences: preferences, model: $0) }
      ?? ("unavailable:" + preferences.modelRepository + ":content-v2:tokenwindows:" + String(preferences.media))
    store = try NativeSearchLibraryStore(databasePath: databasePath ?? NativeSearchLibraryStore.databasePath())
    if configuration.reset { try store.reset() }
    try store.configure(namespace: namespace, dimensions: model?.dimensions ?? 128)
    try store.setPaused(preferences.indexPaused || !preferences.enabled)
    if let failure = configuration.failure {
      if failure.kind == 2 { try store.skipVector(fragmentID: failure.id, reason: "The owned worker exceeded its processing deadline.") }
      else if let file = try store.pendingFiles(limit: 32).first(where: { $0.id == failure.id }) {
        try store.setFileStatus(file: file, status: "failed", partial: true)
      }
    }
    if let model {
      modelReady = try NativeEmbeddingAssets.status(model: model) == .downloaded
      mediaReady = try preferences.media && model.adapter == .gemmaBPE
        && NativeEmbeddingAssets.mediaStatus(model: model) == .downloaded
    }
    if mediaReady { try store.retryWaitingMedia() }
    if preferences.enabled {
      // Construction validates/prunes scope; the persisted pause flag prevents scanSlice from doing work.
      let roots = preferences.allLocalDrives ? nil : preferences.folders
      scanner = try NativeSearchLibraryScanner(store: store, roots: roots,
        excludedPaths: preferences.excludedPaths, resume: !configuration.refresh)
    }
    try store.retryWaitingBudget()
  }
  func stop() -> Bool { releaseModels(); return true }
  func status() throws -> (text: String, delay: DWORD) {
    let status = try store.status()
    fragmentLimitReached = status.fragmentLimitReached
    storageFull = status.storageFull
    let vectorWork: Bool
    if preferences.semantic && modelReady { vectorWork = try !store.pendingFragments(limit: 1).isEmpty }
    else { vectorWork = false }
    if NativeSearchLibraryRuntime.idleModelsMayBeReleased(pendingFile: status.pendingFiles > 0,
      pendingVector: vectorWork, fragmentLimitReached: status.fragmentLimitReached) { releaseModels() }
    let queued = (!status.fragmentLimitReached && status.pendingFiles > 0) || vectorWork
      || scanner?.finished == false
    var text = phase + " · files \(status.files) · fragments \(status.fragments) · vectors \(status.vectors)"
      + " · pending \(status.pendingFiles) files / \(status.pendingVectors) vectors"
      + " · skipped \(status.skippedVectors) · partial \(status.partialFiles) · failed \(status.failedFiles)"
      + (status.fullTextAvailable ? " · FTS5" : " · bounded text scan")
    if status.budgetReached { text += " · index \(status.budgetReason) budget reached" }
    return (text, queued && !status.storageFull && !slowWait
      && (!memoryWaiting || scanner?.finished == false) ? 2000 : 20000)
  }
  func step(heavy: Bool, directories: [String] = [], deadline: UInt64, report: (SearchLibraryFailure) throws -> Void) throws {
    if !heavy || !preferences.enabled || preferences.indexPaused || storageFull { releaseModels() }
    guard preferences.enabled, !preferences.indexPaused else { phase = "Library indexing is paused"; return }
    if storageFull { phase = "Library storage budget reached; narrow locations and reset the derived index"; return }
    for path in directories { try scanner?.enqueueDirectory(path) }
    let scanned = try scanner?.scanSlice(maximumEntries: 128, milliseconds: 40,
      cancelled: { GetTickCount64() >= deadline }) ?? 0
    if scanned > 0 || !directories.isEmpty { try store.retryWaitingBudget() }
    slowWait = !heavy && scanner?.finished == true
    phase = scanner?.finished == false ? "Indexing local file metadata" : "Watching local file changes"
    guard heavy else {
      phase += NativeSearchLibraryRuntime.hasMemoryHeadroom()
        ? "; content work waits for user idle" : "; content work waits for available memory"
      return
    }
    if preferences.semantic, modelReady,
      let pending = try store.pendingFragments(limit: 1).first {
      try report(.init(kind: 2, id: pending.id))
      try embed(pending, deadline: deadline)
    } else if !fragmentLimitReached, let file = try store.pendingFiles(limit: 1).first {
      try report(.init(kind: 1, id: file.id))
      try extract(file, deadline: deadline)
    } else if !modelReady && preferences.semantic { phase = "Content indexed; waiting for the selected model download" }
    if try NativeSearchLibraryRuntime.idleModelsMayBeReleased(
      pendingFile: !store.pendingFiles(limit: 1).isEmpty,
      pendingVector: !store.pendingFragments(limit: 1).isEmpty,
      fragmentLimitReached: fragmentLimitReached) { releaseModels() }
  }
  private func releaseModels() { mediaEngine = nil; engine = nil }
  private func changed(_ file: NativeSearchLibraryFile) throws -> Bool {
    guard !file.matchesCurrent() else { return false }
    if let separator = file.path.lastIndex(of: "\\") {
      try scanner?.enqueueDirectory(String(file.path[...separator]))
    }
    return true
  }
  private static let codeExtensions: Set<String> = [
    "swift", "rs", "c", "h", "cpp", "hpp", "m", "mm", "py", "js", "jsx", "ts", "tsx",
    "java", "kt", "cs", "go", "rb", "sh", "ps1", "sql", "css", "scss", "lua", "vue", "svelte", "dart",
  ]
  private static func location(_ fragment: SearchContentFragment) -> String {
    if let page = fragment.page { return "Page \(page)" }
    if let time = fragment.milliseconds { return "Time \(time) ms" }
    if let line = fragment.line { return "Line \(line)" }
    return "Content"
  }
  private func extract(_ file: NativeSearchLibraryFile, deadline: UInt64) throws {
    guard NativeSearchLibraryRuntime.hasMemoryHeadroom() else {
      memoryWaiting = true; releaseModels(); phase = "Content work waits for available memory"; return
    }
    memoryWaiting = false
    if try changed(file) {
      try store.setFileStatus(file: file, status: "finished", partial: true); return
    }
    guard NativeSearchContent.supports(file.path) else {
      try store.setFileStatus(file: file, status: "unsupported", partial: false); return
    }
    let ext = NativeSearchContent.fileExtension(file.path)
    let audiovisual = NativeSearchContent.audioExtensions.contains(ext) || NativeSearchContent.videoExtensions.contains(ext)
    if audiovisual && !mediaReady {
      try store.setFileStatus(file: file, status: "waiting-media", partial: false); return
    }
    var fragments: [NativeSearchLibraryFragment] = []
    do {
      let report = try NativeSearchContent.extract(path: file.path, deadline: deadline,
        startMilliseconds: ext == "pdf" ? 0 : file.continuation,
        startPage: ext == "pdf" ? max(1, Int(file.continuation)) : 1,
        includeMedia: mediaReady, cancelled: { GetTickCount64() >= deadline }) { fragment in
        guard fragments.count < 256 else { throw WindowsError.unsupported("The content fragment budget is full.") }
        let kind = ext == "pdf" ? "pdf" : (Self.codeExtensions.contains(ext) ? "code" : fragment.kind)
        let location = Self.location(fragment)
        if !fragment.text.trimmingWhitespace().isEmpty {
          var piece = "", bytes = 0, newlines = 0, precedingNewlines = 0
          func textLocation() -> String {
            if let line = fragment.line { return "Line \(line + precedingNewlines) · text" }
            return location + " · text"
          }
          for scalar in fragment.text.unicodeScalars {
            let size = scalar.value < 128 ? 1 : scalar.value < 2048 ? 2 : scalar.value < 65536 ? 3 : 4
            if bytes + size > 16384 {
              guard fragments.count < 255 else { throw WindowsError.unsupported("The content fragment budget is full.") }
              fragments.append(.init(text: piece, kind: kind, location: textLocation()))
              precedingNewlines += newlines
              piece = ""; bytes = 0; newlines = 0
            }
            piece.unicodeScalars.append(scalar); bytes += size
            if scalar.value == 10 { newlines += 1 }
          }
          if !piece.isEmpty { fragments.append(.init(text: piece, kind: kind, location: textLocation())) }
        }
        if fragment.image != nil || fragment.audio != nil {
          fragments.append(.init(text: "", kind: kind, location: location + " · media"))
        }
      }
      if try changed(file) {
        try store.setFileStatus(file: file, status: "finished", partial: true); return
      }
      let continuation = report.continuationMilliseconds ?? report.continuationPage.map(Int64.init)
      try store.transaction {
        guard try store.appendFragments(file: file, fragments: fragments, continuation: continuation) else {
          phase = "Content slice remains pending; index capacity or file metadata changed"
          return
        }
        let status = fragments.isEmpty && continuation == nil ? "unsupported" : (continuation == nil ? "finished" : "pending")
        try store.setFileStatus(file: file, status: status, partial: report.truncated)
      }
      if phase != "Content slice remains pending; index capacity or file metadata changed" {
        phase = "Indexed a bounded content slice"
      }
    } catch {
      if GetTickCount64() >= deadline { throw error }
      if try changed(file) { try store.setFileStatus(file: file, status: "finished", partial: true) }
      else { try store.setFileStatus(file: file, status: "failed", partial: !fragments.isEmpty || file.continuation > 0) }
      phase = "Skipped unavailable content; metadata retained"
    }
  }
  private enum Reconstruction: Error { case found }
  private func reconstruct(_ pending: NativeSearchLibraryPendingFragment, deadline: UInt64) throws -> SearchContentFragment? {
    let location = pending.fragment.location.split(separator: "·").first?.trimmingWhitespace() ?? ""
    let page = location.hasPrefix("Page ") ? Int(location.dropFirst(5)) : nil
    let time = location.hasPrefix("Time ") ? Int64(location.dropFirst(5).split(separator: " ").first ?? "") : nil
    var result: SearchContentFragment?
    do {
      _ = try NativeSearchContent.extract(path: pending.file.path, deadline: deadline,
        startMilliseconds: time ?? 0, startPage: page ?? 1, includeMedia: true,
        cancelled: { GetTickCount64() >= deadline }) { fragment in
        guard (page == nil || fragment.page == page), (time == nil || fragment.milliseconds == time),
          (pending.fragment.kind != "audio" || fragment.audio != nil),
          (pending.fragment.kind != "video" || fragment.kind == "video"),
          fragment.image != nil || fragment.audio != nil else { return }
        result = fragment
        throw Reconstruction.found
      }
    } catch Reconstruction.found {}
    return result
  }
  private func embed(_ pending: NativeSearchLibraryPendingFragment, deadline: UInt64) throws {
    if try changed(pending.file) {
      try store.skipVector(fragmentID: pending.id, reason: "File changed; metadata refresh queued."); return
    }
    let rawMedia = pending.fragment.location.hasSuffix(" · media")
    if rawMedia && !mediaReady {
      if preferences.media, model?.adapter == .gemmaBPE {
        try store.waitForMedia(fragmentID: pending.id)
        phase = "Media fragments retained; waiting for the optional encoder download"
      } else {
        try store.skipVector(fragmentID: pending.id, reason: "The selected configuration has no compatible media encoders.")
      }
      return
    }
    guard let model else { return }
    // Reserve both cold sessions together, rather than repeatedly loading text when media cannot fit.
    let minimum: UInt64 = engine == nil
      ? (model.adapter == .gemmaBPE ? 1280 : 768) + (rawMedia ? 1024 : 0)
      : rawMedia && mediaEngine == nil ? 1024 : 512
    guard NativeSearchLibraryRuntime.hasMemoryHeadroom(minimum: minimum * 1024 * 1024) else {
      memoryWaiting = true; releaseModels(); phase = "Model work waits for available memory"; return
    }
    memoryWaiting = false
    if engine == nil {
      do {
        let loaded = try NativeEmbeddingEngine(model: model)
        try loaded.validateInference(); engine = loaded
      } catch {
        if GetTickCount64() >= deadline { throw error }
        if !NativeSearchLibraryRuntime.hasMemoryHeadroom() {
          memoryWaiting = true; releaseModels(); phase = "Model work waits for available memory"; return
        }
        modelReady = false
        phase = "Model could not validate; content and pending vectors retained"
        return
      }
    }
    do {
      guard let engine else { return }
      let vector: [Float]
      if rawMedia {
        guard let fragment = try reconstruct(pending, deadline: deadline) else {
          try store.skipVector(fragmentID: pending.id, reason: "The requested media fragment is unavailable."); return
        }
        if mediaEngine == nil { mediaEngine = try NativeEmbeddingMediaEngine(engine: engine) }
        vector = try mediaEngine!.vector(fragment)
      } else {
        guard !pending.fragment.text.isEmpty else {
          try store.skipVector(fragmentID: pending.id, reason: "The fragment contains no readable text."); return
        }
        let segments = try engine.documentSegments(pending.fragment.text)
        if segments.count > 1 {
          if try store.splitPendingFragment(fragmentID: pending.id, texts: segments) {
            phase = "Prepared complete token-fitting document segments"
          } else {
            try store.deferBudgetVector(fragmentID: pending.id, requiredFragments: segments.count)
            phase = "Document segments wait for available index capacity"
          }
          return
        }
        // Filenames are identifiers, not evidence of a document or recording's meaning.
        vector = try engine.documentVector(.init(id: String(pending.id), title: "", text: pending.fragment.text))
      }
      if try changed(pending.file) {
        try store.skipVector(fragmentID: pending.id, reason: "File changed; metadata refresh queued."); return
      }
      try store.commitVector(fragmentID: pending.id, namespace: namespace, vector: vector)
      phase = rawMedia ? "Indexed an actual media fragment" : "Indexed a document meaning"
    } catch {
      if GetTickCount64() >= deadline { throw error }
      if !NativeSearchLibraryRuntime.hasMemoryHeadroom() {
        memoryWaiting = true; releaseModels(); phase = "Model work waits for available memory"; return
      }
      try store.skipVector(fragmentID: pending.id, reason: "Native decoding or inference could not process this fragment.")
      phase = "Skipped an unsupported fragment; text and metadata retained"
    }
  }
}
