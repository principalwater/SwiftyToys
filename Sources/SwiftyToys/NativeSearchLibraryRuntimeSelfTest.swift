// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

extension NativeSearchLibraryRuntime {
  /// Explicit private-asset fixture: checks real worker leases without deleting caller assets.
  static func selfCheckModels(gemmaDirectory: String, miniLMDirectory: String) throws {
    NativeEmbedding.closeForRemoval()
    defer { NativeEmbedding.closeForRemoval() }
    let gemmaGraph = gemmaDirectory + "\\" + NativeSearchModelDescriptor.recommended.graph.name
    let miniGraph = miniLMDirectory + "\\" + NativeSearchModelDescriptor.miniLM.graph.name
    let first = try NativeEmbedding.queryVector("find my dog", model: .recommended,
      assetDirectory: gemmaDirectory, cancelled: { false })
    guard first.count == 128 else { throw WindowsError.unsupported("Gemma worker returned the wrong dimensions.") }
    try libraryFixtureLease(gemmaGraph, locked: true)
    let second = try NativeEmbedding.queryVector("find my dog", model: .miniLM,
      assetDirectory: miniLMDirectory, cancelled: { false })
    guard second.count == 384 else { throw WindowsError.unsupported("Model switching reused the wrong vector dimensions.") }
    try libraryFixtureLease(gemmaGraph, locked: false)
    try libraryFixtureLease(miniGraph, locked: true)
    NativeEmbedding.closeForRemoval()
    try libraryFixtureLease(miniGraph, locked: false)
    let began = GetTickCount64()
    do {
      _ = try NativeEmbedding.queryVector("find my dog", model: .recommended,
        assetDirectory: gemmaDirectory, cancelled: { GetTickCount64() - began >= 100 })
      throw WindowsError.unsupported("Cold model worker ignored cancellation.")
    } catch let error as WindowsError {
      guard case .api(_, let code) = error, code == DWORD(ERROR_CANCELLED) else { throw error }
    }
    guard GetTickCount64() - began < 1500 else {
      throw WindowsError.unsupported("Owned model cancellation exceeded its fixture deadline.")
    }
    NativeEmbedding.closeForRemoval()
    try libraryFixtureLease(gemmaGraph, locked: false)
    Console.writeLine("PASS: actual Gemma/MiniLM model switching, held-file delete-access denial, released leases after swap/close, and owned cold-worker cancellation; caller assets preserved")
  }

  /// Uses only generated fixture files and a process-local child storage directory.
  static func selfCheckSupervisor() throws {
    let root = try NativeSearchFiles.knownFolder(FOLDERID_Profile)
      + "\\SwiftyToys-Library-Worker-" + NativeEmbeddingAssets.guid()
    let documents = root + "\\documents", local = root + "\\local", app = local + "\\SwiftyToys"
    let database = app + "\\search-library.sqlite3", source = documents + "\\sample.swift"
    let gapSource = documents + "\\saved-during-restart.swift"
    for path in [root, documents, local, app] { try NativeEmbeddingAssets.privateDirectory(path) }
    defer {
      try? NativeFiles.remove(source)
      try? NativeFiles.remove(gapSource)
      for suffix in ["", "-journal", "-wal", "-shm"] { try? NativeFiles.remove(database + suffix) }
      for path in [documents, app, local, root] { _ = withWideString(path) { RemoveDirectoryW($0) } }
    }
    try NativeFiles.write(Array("let answer = 42\n".utf8), to: source)
    var previous = [WCHAR](repeating: 0, count: 32768)
    let length = withWideString("LOCALAPPDATA") { GetEnvironmentVariableW($0, &previous, DWORD(previous.count)) }
    guard length < previous.count else { throw WindowsError.unsupported("Fixture environment value exceeds its limit.") }
    let old = length > 0 ? String(decoding: previous.prefix(Int(length)), as: UTF16.self) : nil
    defer {
      _ = withWideString("LOCALAPPDATA") { key in
        old.map { value in withWideString(value) { SetEnvironmentVariableW(key, $0) } }
          ?? SetEnvironmentVariableW(key, nil)
      }
    }
    guard withWideString("LOCALAPPDATA", { key in withWideString(local) { SetEnvironmentVariableW(key, $0) } }) else {
      throw WindowsError.api("Configure private child fixture storage", GetLastError())
    }
    let watcher = try NativeSearchLibraryWatcher(roots: [documents])
    defer { _ = watcher.stop() }
    func scanUntilFiles(_ files: Int, worker: LibraryRuntimeFixtureChild,
      directories: [String] = []) throws -> String {
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      let deadline = GetTickCount64() + 10000
      var notice = try worker.step(heavy: false, directories: directories)
      var observed = try check.status()
      // A 40 ms slice may yield; subsequent steps must continue the original delivery without re-enqueuing it.
      while observed.directories > 0 && GetTickCount64() < deadline {
        Sleep(10)
        notice = try worker.step(heavy: false)
        observed = try check.status()
      }
      guard observed.files == files, observed.directories == 0 else {
        throw WindowsError.unsupported("Library metadata fixture expected \(files) files and a drained queue; "
          + "observed files \(observed.files), queued directories \(observed.directories). Worker: \(notice)")
      }
      return notice
    }
    do {
      let worker = try LibraryRuntimeFixtureChild()
      defer { worker.child.stop(wait: true) }
      _ = try worker.configure(folder: documents, reset: true, refresh: true)
      let indexed = try scanUntilFiles(1, worker: worker)
      guard indexed.containsText("files 1") else { throw WindowsError.unsupported("Owned library worker did not index its generated file.") }
      let extracted = try worker.step(heavy: true)
      guard extracted.containsText("fragments 1") else { throw WindowsError.unsupported("Owned library worker failed its bounded text fixture.") }
      worker.child.stop(wait: true)
      guard worker.child.ended else { throw WindowsError.unsupported("Owned library job did not exit.") }
    }
    _ = watcher.pollChangedDirectories()
    try NativeFiles.write(Array("let restartSaved = true\n".utf8), to: gapSource)
    var dirty: [String] = []
    let notificationDeadline = GetTickCount64() + 2000
    while dirty.isEmpty && GetTickCount64() < notificationDeadline {
      dirty = watcher.pollChangedDirectories()
      if dirty.isEmpty { Sleep(10) }
    }
    guard !dirty.isEmpty else { throw WindowsError.unsupported("Supervisor notifications missed a save while its child was stopped.") }
    var pendingID: Int64 = 0
    do {
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      guard try check.status().files == 1, let pending = try check.pendingFragments(limit: 1).first else {
        throw WindowsError.unsupported("Terminated library job lost committed progress.")
      }
      pendingID = pending.id
    }
    do {
      let worker = try LibraryRuntimeFixtureChild()
      defer { worker.child.stop(wait: true) }
      let resumed = try worker.configure(folder: documents, reset: false, refresh: false,
        failedFragment: pendingID)
      guard resumed.containsText("fragments 1"), resumed.containsText("skipped 1") else {
        throw WindowsError.unsupported("Restarted library worker lost terminal task state.")
      }
      let catchup = try scanUntilFiles(2, worker: worker, directories: dirty)
      guard catchup.containsText("files 2") else {
        throw WindowsError.unsupported("Restarted child did not apply retained supervisor notifications.")
      }
      var malformed = NativeEmbeddingWriter()
      malformed.integer(11); malformed.integer(2); malformed.integer(0)
      guard try worker.exchange(malformed.bytes).code == 3 else {
        throw WindowsError.unsupported("Library worker accepted unsafe step flags.")
      }
      let began = GetTickCount64()
      do {
        _ = try worker.channel.receive(deadline: began + 100, cancelled: { false })
        throw WindowsError.unsupported("Library worker wait ignored its hard deadline.")
      } catch WindowsError.unsupported(let reason) {
        guard reason.containsText("timed out") else { throw WindowsError.unsupported(reason) }
      }
      worker.child.stop(wait: true)
      guard GetTickCount64() - began < 2000 else { throw WindowsError.unsupported("Owned library deadline cleanup was too slow.") }
    }
    do {
      let rawWindow = withWideString("STATIC") { name in
        CreateWindowExW(0, name, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil, nil, nil)
      }
      guard let rawWindow else { throw WindowsError.api("Create paused library fixture destination", GetLastError()) }
      defer { _ = DestroyWindow(rawWindow) }
      var preferences = SearchPreferences(contents: "enabled=1\nsemantic=0\nallLocalDrives=0\nindexPaused=1\n")
      preferences.folder = documents
      let manager = try NativeSearchLibraryManager(destination: MessageDestination(rawWindow), preferences: preferences)
      defer { manager.stop() }
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      func waitForPausedFiles(_ files: Int) throws {
        let deadline = GetTickCount64() + 10000
        var notice = "No supervisor delivery", observed = "No readable index status"
        repeat {
          if let current = manager.take() { notice = current }
          if let status = try? check.status() {
            observed = "files \(status.files), fragments \(status.fragments), paused \(status.paused)"
            if status.paused, status.files == files { return }
          }
          Sleep(10)
        } while GetTickCount64() < deadline
        throw WindowsError.unsupported("Paused library scope expected \(files) files; \(observed). Supervisor: \(notice)")
      }
      try waitForPausedFiles(2)
      preferences.exclusions = documents
      manager.apply(preferences)
      try waitForPausedFiles(0)
      guard try check.status().fragments == 0,
        try check.searchText("answer", cancelled: { false }).isEmpty,
        try NativeFiles.exists(source), try NativeFiles.exists(gapSource) else {
        throw WindowsError.unsupported("Paused scope changes retained excluded results or changed source files.")
      }
    }
    do {
      let worker = try LibraryRuntimeFixtureChild()
      defer { worker.child.stop(wait: true) }
      _ = try worker.configure(folder: documents, reset: true, refresh: true, paused: true)
      let check = try NativeSearchLibraryStore(databasePath: database, readOnly: true)
      guard try check.status().files == 0, try check.paused, try NativeFiles.exists(source) else {
        throw WindowsError.unsupported("Paused owned-worker reset affected source files.")
      }
    }
    Console.writeLine("PASS: actual owned library jobs, retained notifications across child restart, committed progress, terminal task replay, malformed-message rejection, hard IPC deadline cleanup, paused scope pruning and derived-only reset; generated fixture corpus only")
  }
}

private func libraryFixtureLease(_ path: String, locked: Bool) throws {
  let deadline = GetTickCount64() + 2000
  while true {
    let raw = withWideString(try NativeFiles.windowsPath(path)) {
      CreateFileW($0, DWORD(DELETE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
    }
    if let raw, raw != INVALID_HANDLE_VALUE {
      _ = CloseHandle(raw)
      guard !locked else { throw WindowsError.unsupported("An active model worker did not hold its verified file lease.") }
      return
    }
    let error = GetLastError()
    guard error == DWORD(ERROR_SHARING_VIOLATION) else { throw WindowsError.api("Check model fixture sharing lease", error) }
    if locked { return }
    guard GetTickCount64() < deadline else { throw WindowsError.unsupported("Stopped model worker retained a file lease.") }
    Sleep(20)
  }
}

private final class LibraryRuntimeFixtureChild {
  let channel: NativeEmbeddingChannel
  let child: NativeEmbeddingProcess
  init() throws {
    let name = NativeEmbeddingChannel.prefix + (try NativeEmbeddingAssets.guid())
    channel = try NativeEmbeddingChannel(serverName: name)
    child = try NativeEmbeddingProcess(executable: executablePath(), arguments: ["--library-worker", name])
    do { try channel.connect(child: child, cancelled: { false }) }
    catch { child.stop(wait: true); throw error }
    guard child.id != GetCurrentProcessId() else { throw WindowsError.unsupported("Library fixture job reached its parent process.") }
  }
  func exchange(_ bytes: [UInt8]) throws -> (code: UInt32, text: String) {
    let deadline = GetTickCount64() + 60000
    try channel.send(bytes, deadline: deadline)
    while true {
      var reader = NativeEmbeddingReader(bytes: try channel.receive(deadline: deadline))
      let code = try reader.integer()
      if code == 4 { _ = try reader.integer(); _ = try reader.string(maximum: 32); try reader.finished(); continue }
      guard code == 2 || code == 3 else { throw WindowsError.unsupported("Fixture worker returned an invalid response.") }
      let text = try reader.string(maximum: 2048)
      if code == 2 { _ = try reader.integer() }
      try reader.finished()
      return (code, text)
    }
  }
  func configure(folder: String, reset: Bool, refresh: Bool, paused: Bool = false,
    failedFragment: Int64? = nil) throws -> String {
    var writer = NativeEmbeddingWriter()
    writer.integer(10); writer.integer(paused ? 17 : 1)
    writer.integer((reset ? 1 : 0) | (refresh ? 2 : 0))
    try writer.string(NativeSearchModelDescriptor.recommended.repositoryID, maximum: 192)
    try writer.string(folder, maximum: 24000); try writer.string("", maximum: 24000)
    writer.integer(failedFragment == nil ? 0 : 2)
    try writer.string(failedFragment.map(String.init) ?? "", maximum: 32)
    let result = try exchange(writer.bytes)
    guard result.code == 2 else { throw WindowsError.unsupported(result.text) }
    return result.text
  }
  func step(heavy: Bool, directories: [String] = []) throws -> String {
    var writer = NativeEmbeddingWriter()
    writer.integer(11); writer.integer(heavy ? 1 : 0); writer.integer(UInt32(directories.count))
    for path in directories { try writer.string(path, maximum: 65536) }
    let result = try exchange(writer.bytes)
    guard result.code == 2 else { throw WindowsError.unsupported(result.text) }
    return result.text
  }
}
