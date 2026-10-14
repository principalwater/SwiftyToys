// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import SearchIndexABI
import WinSDK

struct NativeSearchLibraryFile {
    let id: Int64
    let path: String
    let size: Int64
    let modified: String
    let continuation: Int64
    func matchesCurrent() -> Bool {
        guard let current = try? NativeSearchLibraryScanner.metadata(path: path) else { return false }
        return current.size == size && current.modified == modified
    }
}
struct NativeSearchLibraryFragment {
    let text: String
    let kind: String
    let location: String
}
struct NativeSearchLibraryPendingFragment {
    let id: Int64
    let file: NativeSearchLibraryFile
    let fragment: NativeSearchLibraryFragment
}
struct NativeSearchLibraryStatus {
    let files: Int
    let fragments: Int
    let vectors: Int
    let pendingFiles: Int
    let pendingVectors: Int
    let directories: Int
    let paused: Bool
    let budgetReached: Bool
    let fullTextAvailable: Bool
    let skippedVectors: Int
    let failedFiles: Int
    let partialFiles: Int
    let budgetReason: String
    let fileLimitReached: Bool
    let fragmentLimitReached: Bool
    let storageFull: Bool
}
private enum NativeSearchLibraryBudgetError: Error { case full }

private final class NativeSearchLibraryQueryGuard {
    let deadline: UInt64
    let cancelled: () -> Bool
    var timedOut = false
    init(deadline: UInt64, cancelled: @escaping () -> Bool) {
        self.deadline = deadline
        self.cancelled = cancelled
    }
    func interrupt() -> Int32 {
        if cancelled() { return 1 }
        timedOut = GetTickCount64() >= deadline
        return timedOut ? 1 : 0
    }
}

private final class NativeSearchLibraryModule {
    let raw: HMODULE
    init() throws {
        guard let raw = withWideString("winsqlite3.dll", {
            LoadLibraryExW($0, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32))
        }) else { throw WindowsError.api("Load Windows SQLite", GetLastError()) }
        self.raw = raw
    }
    deinit { _ = FreeLibrary(raw) }
}

/// One serial worker owns each connection. Queries stream rows instead of loading the corpus.
final class NativeSearchLibraryStore {
    static let maximumFiles = 200_000
    static let maximumFragments = 400_000
    private let module: NativeSearchLibraryModule
    private var database: OpaquePointer?
    private let open: STSqliteOpen
    private let close: STSqliteClose
    private let prepare: STSqlitePrepare
    private let step: STSqliteStep
    private let finalize: STSqliteFinalize
    private let bindText: STSqliteBindText
    private let bindInteger: STSqliteBindInt64
    private let bindBlob: STSqliteBindBlob
    private let columnText: STSqliteColumnText
    private let columnInteger: STSqliteColumnInt64
    private let columnBlob: STSqliteColumnBlob
    private let columnBytes: STSqliteColumnBytes
    private let changes: STSqliteChanges
    private let progressHandler: STSqliteProgressHandler
    private var queryGuard: NativeSearchLibraryQueryGuard?
    private var namespace = ""
    private var dimensions = 0
    var activeNamespace: String { namespace }
    var activeDimensions: Int { dimensions }
    private var inTransaction = false
    private var fullTextAvailable = false
    private var cachedFileCount: Int?
    private var cachedFragmentCount: Int?
    private var recordingStorageFull = false
    private var maximumPageCount = 262144
    private static var transient: STSqliteDestructor {
        unsafeBitCast(Int(-1), to: STSqliteDestructor.self)
    }

    static func databasePath() throws -> String {
        let directory = try NativeFiles.directory()
        try NativeFiles.createDirectory(directory)
        return directory + "\\search-library.sqlite3"
    }
    init(databasePath: String, readOnly: Bool = false) throws {
        guard NativeSearchLibraryScanner.canonical(databasePath) != nil,
            let separator = databasePath.lastIndex(of: "\\"),
            NativeSearchFiles.validFolder(String(databasePath[...separator])) else {
            throw WindowsError.unsupported("The search index must be on a local drive.")
        }
        let attributes = withWideString(try NativeFiles.windowsPath(databasePath)) { GetFileAttributesW($0) }
        let blocked = DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_DIRECTORY)
        guard attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & blocked == 0 else {
            throw WindowsError.unsupported("Linked and offline index databases are excluded.")
        }
        let library = try NativeSearchLibraryModule()
        module = library
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let value = name.withCString({ GetProcAddress(library.raw, $0) }) else {
                throw WindowsError.unsupported("Windows SQLite is missing a required API.")
            }
            return unsafeBitCast(value, to: type)
        }
        open = try symbol("sqlite3_open_v2", STSqliteOpen.self)
        close = try symbol("sqlite3_close", STSqliteClose.self)
        prepare = try symbol("sqlite3_prepare_v2", STSqlitePrepare.self)
        step = try symbol("sqlite3_step", STSqliteStep.self)
        finalize = try symbol("sqlite3_finalize", STSqliteFinalize.self)
        bindText = try symbol("sqlite3_bind_text", STSqliteBindText.self)
        bindInteger = try symbol("sqlite3_bind_int64", STSqliteBindInt64.self)
        bindBlob = try symbol("sqlite3_bind_blob", STSqliteBindBlob.self)
        columnText = try symbol("sqlite3_column_text", STSqliteColumnText.self)
        columnInteger = try symbol("sqlite3_column_int64", STSqliteColumnInt64.self)
        columnBlob = try symbol("sqlite3_column_blob", STSqliteColumnBlob.self)
        columnBytes = try symbol("sqlite3_column_bytes", STSqliteColumnBytes.self)
        changes = try symbol("sqlite3_changes", STSqliteChanges.self)
        progressHandler = try symbol("sqlite3_progress_handler", STSqliteProgressHandler.self)
        do {
            let timeout = try symbol("sqlite3_busy_timeout", STSqliteBusyTimeout.self)
            // FULLMUTEX protects SQLite if a caller accidentally shares the connection.
            let result = databasePath.withCString { open($0, &database, readOnly ? 0x10001 : 0x10006, nil) }
            guard result == 0 else { throw Self.failure(result) }
            _ = timeout(database, 250)
        } catch { _ = close(database); database = nil; throw error }
        do {
            if readOnly {
                try run("PRAGMA query_only=ON")
                try run("PRAGMA cache_size=-2048")
                guard try meta("schema") == "1" else {
                    throw WindowsError.unsupported("The search index schema requires a newer application.")
                }
                namespace = try meta("namespace") ?? ""
                dimensions = Int(try meta("dimensions") ?? "0") ?? 0
                fullTextAvailable = try count("SELECT count(*) FROM sqlite_master WHERE name='fulltext' AND type='table'") == 1
                return
            }
            try run("PRAGMA foreign_keys=ON")
            try run("PRAGMA journal_mode=DELETE")
            try run("PRAGMA synchronous=FULL")
            try run("PRAGMA cache_size=-2048")
            try run("PRAGMA page_size=4096")
            try run("PRAGMA max_page_count=262144") // 1 GiB at the fixed 4 KiB page size.
            try run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            let schema = try meta("schema")
            guard schema == nil || schema == "1" else {
                throw WindowsError.unsupported("The search index schema requires a newer application.")
            }
            try run("""
                CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE COLLATE NOCASE,parent TEXT NOT NULL COLLATE NOCASE,
                name TEXT NOT NULL,
                size INTEGER NOT NULL,modified TEXT NOT NULL,seen TEXT NOT NULL,
                pending INTEGER NOT NULL DEFAULT 1,continuation INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending',partial INTEGER NOT NULL DEFAULT 0)
                """)
            try run("CREATE INDEX IF NOT EXISTS files_parent ON files(parent)")
            try run("CREATE INDEX IF NOT EXISTS files_name ON files(name)")
            try run("CREATE INDEX IF NOT EXISTS files_pending ON files(pending,id)")
            try run("CREATE INDEX IF NOT EXISTS files_status ON files(status)")
            try run("CREATE INDEX IF NOT EXISTS files_partial ON files(partial)")
            try run("""
                CREATE TABLE IF NOT EXISTS fragments(id INTEGER PRIMARY KEY AUTOINCREMENT,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                text TEXT NOT NULL,kind TEXT NOT NULL,location TEXT NOT NULL,vector BLOB,
                state TEXT NOT NULL DEFAULT 'pending',reason TEXT NOT NULL DEFAULT '',
                window INTEGER NOT NULL DEFAULT 0)
                """)
            try run("CREATE INDEX IF NOT EXISTS fragments_file ON fragments(file)")
            try run("CREATE INDEX IF NOT EXISTS fragments_state ON fragments(state,id)")
            do {
                try transaction {
                try run("CREATE VIRTUAL TABLE IF NOT EXISTS fulltext USING fts5(text,content='fragments',content_rowid='id')")
                try run("""
                    CREATE TRIGGER IF NOT EXISTS fragment_insert AFTER INSERT ON fragments WHEN new.window=0 BEGIN
                    INSERT INTO fulltext(rowid,text) VALUES(new.id,new.text); END
                    """)
                try run("""
                    CREATE TRIGGER IF NOT EXISTS fragment_delete AFTER DELETE ON fragments
                    WHEN old.window=0 AND NOT EXISTS(SELECT 1 FROM meta WHERE key='resetting' AND value='1') BEGIN
                    INSERT INTO fulltext(fulltext,rowid,text) VALUES('delete',old.id,old.text); END
                    """)
                }
                fullTextAvailable = true
            } catch {
                // shortcut: Windows SQLite builds without FTS5 use bounded exact-text scans.
                fullTextAvailable = false
            }
            try run("CREATE TABLE IF NOT EXISTS directories(path TEXT PRIMARY KEY COLLATE NOCASE)")
            try run("CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY COLLATE NOCASE,parent TEXT NOT NULL COLLATE NOCASE,seen TEXT NOT NULL)")
            try run("CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent)")
            try run("CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY COLLATE NOCASE,volume TEXT NOT NULL)")
            try setMeta("schema", "1")
            if try meta("budget") == nil { try setMeta("budget", "0") }
            namespace = try meta("namespace") ?? ""
            dimensions = Int(try meta("dimensions") ?? "0") ?? 0
        } catch { _ = close(database); database = nil; throw error }
    }
    deinit { _ = close(database) }
    private static func failure(_ code: Int32) -> any Error {
        if code == 13 { return NativeSearchLibraryBudgetError.full }
        return WindowsError.unsupported("The local search index could not complete a database operation (\(code)).")
    }
    private enum Value { case text(String), integer(Int64), blob([Float]) }
    private func query(_ sql: String, _ values: [Value] = [],
        row: (OpaquePointer) throws -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        let result = sql.withCString { prepare(database, $0, -1, &statement, nil) }
        guard result == 0, let statement else { throw Self.failure(result) }
        defer { _ = finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { bindText(statement, index, $0, -1, Self.transient) }
            case .integer(let integer): result = bindInteger(statement, index, integer)
            case .blob(let vector):
                result = vector.withUnsafeBytes {
                    bindBlob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard result == 0 else { throw Self.failure(result) }
        }
        while true {
            let code = step(statement)
            if code == 101 { return }
            if code == 9, let queryGuard {
                if queryGuard.timedOut { throw QueryStop.budget }
                throw WindowsError.api("Search cancelled", DWORD(ERROR_CANCELLED))
            }
            guard code == 100 else { throw Self.failure(code) }
            try row(statement)
        }
    }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        do { try query(sql, values) }
        catch NativeSearchLibraryBudgetError.full {
            if inTransaction { throw NativeSearchLibraryBudgetError.full }
            markStorageFull()
            throw WindowsError.unsupported("The local search index storage budget is full.")
        }
    }
    private func markStorageFull() {
        guard !recordingStorageFull else { return }
        recordingStorageFull = true
        defer { recordingStorageFull = false }
        try? setMeta("budget", "storage")
    }
    func transaction(_ body: () throws -> Void) throws {
        if inTransaction { try body(); return }
        try run("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do { try body(); try run("COMMIT") }
        catch {
            cachedFileCount = nil
            cachedFragmentCount = nil
            try? run("ROLLBACK")
            if error is NativeSearchLibraryBudgetError {
                inTransaction = false
                markStorageFull()
                throw WindowsError.unsupported("The local search index storage budget is full.")
            }
            throw error
        }
    }
    private func text(_ row: OpaquePointer, _ column: Int32) -> String {
        let length = Int(columnBytes(row, column))
        guard length <= 65536, let value = columnText(row, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: length), as: UTF8.self)
    }
    private func count(_ sql: String, _ values: [Value] = []) throws -> Int {
        var value = 0
        try query(sql, values) { value = Int(columnInteger($0, 0)) }
        return value
    }
    private func meta(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM meta WHERE key=?", [.text(key)]) { value = text($0, 0) }
        return value
    }
    private func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta VALUES(?,?)", [.text(key), .text(value)])
    }
    private func fileCount() throws -> Int {
        if let cachedFileCount { return cachedFileCount }
        let value = try count("SELECT count(*) FROM files")
        cachedFileCount = value
        return value
    }
    private func removeFiles(_ sql: String, _ values: [Value]) throws {
        try run(sql, values)
        if let cachedFileCount { self.cachedFileCount = max(0, cachedFileCount - Int(changes(database))) }
        if changes(database) > 0 {
            cachedFragmentCount = nil
            try clearRecoveredBudget()
        }
    }
    private func fragmentCount() throws -> Int {
        if let cachedFragmentCount { return cachedFragmentCount }
        let value = try count("SELECT count(*) FROM fragments")
        cachedFragmentCount = value
        return value
    }
    private func clearRecoveredBudget() throws {
        let reason = try meta("budget")
        if reason == "files", try fileCount() < Self.maximumFiles {
            try setMeta("budget", "0")
        } else if reason == "fragments", try fragmentCount() < Self.maximumFragments {
            try setMeta("budget", "0")
        }
    }
    private func removeFragments(fileID: Int64) throws {
        try run("DELETE FROM fragments WHERE file=?", [.integer(fileID)])
        if let cachedFragmentCount {
            self.cachedFragmentCount = max(0, cachedFragmentCount - Int(changes(database)))
        }
    }
    func configure(namespace: String, dimensions: Int) throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 2048, !namespace.utf16.contains(0),
            (1...4096).contains(dimensions) else {
            throw WindowsError.unsupported("Invalid search model namespace.")
        }
        guard namespace != self.namespace || dimensions != self.dimensions else { return }
        try transaction {
            try run("DELETE FROM fragments WHERE window=1")
            try run("UPDATE fragments SET vector=NULL,state='pending',reason=''")
            try run("DELETE FROM fragments WHERE file IN(SELECT id FROM files WHERE status IN('failed','unsupported','waiting-media'))")
            cachedFragmentCount = nil
            try run("UPDATE files SET pending=1,continuation=0,status='pending',partial=0 WHERE status IN('failed','unsupported','waiting-media')")
            try setMeta("namespace", namespace)
            try setMeta("dimensions", String(dimensions))
            try clearRecoveredBudget()
        }
        self.namespace = namespace
        self.dimensions = dimensions
    }
    func setPaused(_ paused: Bool) throws { try setMeta("paused", paused ? "1" : "0") }
    func retryWaitingMedia() throws {
        try transaction {
            try run("UPDATE fragments SET state='pending',reason='' WHERE state='waiting-media'")
            try run("DELETE FROM fragments WHERE file IN(SELECT id FROM files WHERE status='waiting-media')")
            cachedFragmentCount = nil
            try run("UPDATE files SET pending=1,continuation=0,status='pending',partial=0 WHERE status='waiting-media'")
        }
    }
    var paused: Bool { get throws { try meta("paused") == "1" } }
    func reset() throws {
        try transaction {
            try setMeta("resetting", "1")
            if fullTextAvailable { try run("INSERT INTO fulltext(fulltext) VALUES('delete-all')") }
            try run("DELETE FROM files")
            cachedFileCount = 0
            cachedFragmentCount = 0
            try run("DELETE FROM directories")
            try run("DELETE FROM folders")
            try run("DELETE FROM roots")
            try setMeta("budget", "0")
            try setMeta("resetting", "0")
        }
    }
    func status() throws -> NativeSearchLibraryStatus {
        let files = try count("SELECT count(*) FROM files")
        let fragments = try count("SELECT count(*) FROM fragments")
        let vectors = try count("SELECT count(*) FROM fragments WHERE state='ready'")
        let reason = try meta("budget") ?? "0"
        let filesFull = files >= Self.maximumFiles || reason == "files"
        let fragmentsFull = fragments >= Self.maximumFragments || reason == "fragments"
        let storageFull = try reason == "storage" || reason == "1" ||
            count("PRAGMA page_count") - count("PRAGMA freelist_count") >= maximumPageCount
        return try NativeSearchLibraryStatus(
            files: files, fragments: fragments, vectors: vectors,
            pendingFiles: count("SELECT count(*) FROM files WHERE pending=1"),
            pendingVectors: count("SELECT count(*) FROM fragments WHERE state IN('pending','waiting-media','waiting-budget')"),
            directories: count("SELECT count(*) FROM directories"),
            paused: paused, budgetReached: filesFull || fragmentsFull || storageFull,
            fullTextAvailable: fullTextAvailable,
            skippedVectors: count("SELECT count(*) FROM fragments WHERE state='skipped'"),
            failedFiles: count("SELECT count(*) FROM files WHERE status IN('failed','unsupported','waiting-media')"),
            partialFiles: count("SELECT count(*) FROM files WHERE partial=1"),
            budgetReason: storageFull ? "storage" : fragmentsFull ? "fragments" : filesFull ? "files" : "",
            fileLimitReached: filesFull, fragmentLimitReached: fragmentsFull, storageFull: storageFull)
    }
    func queueDirectory(_ path: String, parent: String? = nil, generation: String? = nil) throws {
        if let parent, let generation {
            try run("INSERT OR REPLACE INTO folders(path,parent,seen) VALUES(?,?,?)",
                [.text(path), .text(parent), .text(generation)])
        }
        try run("INSERT OR IGNORE INTO directories VALUES(?)", [.text(path)])
    }
    func trackRoots(_ roots: [(path: String, volume: String)], refresh: Bool) throws {
        var previous: [String: String] = [:]
        try query("SELECT path,volume FROM roots") { previous[text($0, 0)] = text($0, 1) }
        let present = Set(roots.map(\.path))
        try transaction {
            for path in previous.keys where !present.contains(path) {
                try run("DELETE FROM roots WHERE path=?", [.text(path)])
            }
            for root in roots {
                let changed = previous[root.path] != root.volume
                if changed {
                    try run("INSERT OR REPLACE INTO roots VALUES(?,?)", [.text(root.path), .text(root.volume)])
                }
                if refresh || changed { try queueDirectory(root.path) }
            }
        }
    }
    func nextDirectory() throws -> String? {
        var path: String?
        try query("SELECT path FROM directories ORDER BY rowid LIMIT 1") { path = text($0, 0) }
        return path
    }
    func finishDirectory(_ path: String, generation: String) throws {
        try transaction {
            var missing: [String] = []
            try query("SELECT path FROM folders WHERE parent=? AND seen<>?",
                [.text(path), .text(generation)]) { missing.append(text($0, 0)) }
            for child in missing { try pruneMissingDirectory(child) }
            try removeFiles("DELETE FROM files WHERE parent=? AND seen<>?", [.text(path), .text(generation)])
            try run("DELETE FROM directories WHERE path=?", [.text(path)])
        }
    }
    func abandonDirectory(_ path: String) throws {
        // An inaccessible directory/drive is not evidence that its files were deleted.
        try run("DELETE FROM directories WHERE path=?", [.text(path)])
    }
    func observe(path: String, parent: String, size: Int64, modified: String,
        generation: String) throws {
        var previous: NativeSearchLibraryFile?
        try query("SELECT id,path,size,modified,continuation FROM files WHERE path=?", [.text(path)]) {
            previous = record($0)
        }
        if let previous, previous.size == size, previous.modified == modified {
            try run("UPDATE files SET seen=? WHERE id=?", [.text(generation), .integer(previous.id)])
            return
        }
        if previous == nil, try fileCount() >= Self.maximumFiles {
            try setMeta("budget", "files")
            return
        }
        try transaction {
            if let previous {
                try removeFragments(fileID: previous.id)
                try run("UPDATE files SET size=?,modified=?,seen=?,pending=1,continuation=0,status='pending',partial=0 WHERE id=?",
                    [.integer(size), .text(modified), .text(generation), .integer(previous.id)])
            } else {
                let name = String(path.split(separator: "\\").last ?? "").lowercased()
                try run("INSERT INTO files(path,parent,name,size,modified,seen) VALUES(?,?,?,?,?,?)",
                    [.text(path), .text(parent), .text(name), .integer(size), .text(modified), .text(generation)])
                if let cachedFileCount { self.cachedFileCount = cachedFileCount + 1 }
            }
        }
    }
    private func record(_ row: OpaquePointer, offset: Int32 = 0) -> NativeSearchLibraryFile {
        NativeSearchLibraryFile(id: columnInteger(row, offset), path: text(row, offset + 1),
            size: columnInteger(row, offset + 2), modified: text(row, offset + 3),
            continuation: columnInteger(row, offset + 4))
    }
    func pendingFiles(limit: Int = 2) throws -> [NativeSearchLibraryFile] {
        var files: [NativeSearchLibraryFile] = []
        try query("SELECT id,path,size,modified,continuation FROM files WHERE pending=1 ORDER BY id LIMIT ?",
            [.integer(Int64(max(0, min(32, limit))))]) { files.append(record($0)) }
        return files
    }
    @discardableResult func replaceFragments(file: NativeSearchLibraryFile,
        fragments: [NativeSearchLibraryFragment]) throws -> Bool {
        try saveFragments(file: file, fragments: fragments, continuation: nil, replacing: true)
    }
    @discardableResult func appendFragments(file: NativeSearchLibraryFile,
        fragments: [NativeSearchLibraryFragment], continuation: Int64?) throws -> Bool {
        try saveFragments(file: file, fragments: fragments, continuation: continuation, replacing: false)
    }
    private func saveFragments(file: NativeSearchLibraryFile,
        fragments: [NativeSearchLibraryFragment], continuation: Int64?, replacing: Bool) throws -> Bool {
        guard fragments.count <= 256,
            continuation == nil || continuation! > file.continuation,
            fragments.allSatisfy({ $0.text.utf8.count <= 32768 && $0.kind.utf8.count <= 128 &&
                $0.location.utf8.count <= 1024 && !($0.text + $0.kind + $0.location).utf16.contains(0) })
        else { throw WindowsError.unsupported("Extracted search fragments exceed their limits.") }
        var current: NativeSearchLibraryFile?
        try query("SELECT id,path,size,modified,continuation FROM files WHERE id=?", [.integer(file.id)]) {
            current = record($0)
        }
        guard let current, current.modified == file.modified, current.size == file.size,
            current.continuation == file.continuation else { return false }
        let existing = try (replacing ? count("SELECT count(*) FROM fragments WHERE file=?", [.integer(file.id)]) : 0)
        let nonempty = fragments.filter { !$0.text.isEmpty || ["pdf", "image", "audio", "video"].contains($0.kind) }
        if try fragmentCount() + nonempty.count - existing > Self.maximumFragments {
            try setMeta("budget", "fragments")
            return false
        }
        try transaction {
            if replacing { try removeFragments(fileID: file.id) }
            for fragment in nonempty {
                try run("INSERT INTO fragments(file,text,kind,location) VALUES(?,?,?,?)",
                    [.integer(file.id), .text(fragment.text), .text(fragment.kind), .text(fragment.location)])
            }
            if let cachedFragmentCount { self.cachedFragmentCount = cachedFragmentCount + nonempty.count }
            try run("UPDATE files SET pending=?,continuation=?,status=? WHERE id=?",
                [.integer(continuation == nil ? 0 : 1), .integer(continuation ?? 0),
                    .text(continuation == nil ? "finished" : "pending"), .integer(file.id)])
        }
        return true
    }
    @discardableResult func splitPendingFragment(fragmentID: Int64, texts: [String]) throws -> Bool {
        guard (2...256).contains(texts.count), texts.allSatisfy({ !$0.isEmpty &&
            $0.utf8.count <= 32768 && !$0.utf16.contains(0) }) else {
            throw WindowsError.unsupported("Invalid semantic text windows.")
        }
        var original: (file: Int64, text: String, kind: String, location: String)?
        try query("SELECT file,text,kind,location FROM fragments WHERE id=? AND state='pending' AND vector IS NULL",
            [.integer(fragmentID)]) {
            original = (columnInteger($0, 0), text($0, 1), text($0, 2), text($0, 3))
        }
        guard let original else { return false }
        guard texts.joined(separator: "").utf8.elementsEqual(original.text.utf8) else {
            throw WindowsError.unsupported("Semantic windows must preserve every source character.")
        }
        guard try fragmentCount() + texts.count <= Self.maximumFragments else {
            try setMeta("budget", "fragments")
            return false
        }
        try transaction {
            // Keep original full text for exact strings spanning semantic window boundaries.
            try run("UPDATE fragments SET state='lexical' WHERE id=?", [.integer(fragmentID)])
            var precedingLines = 0
            for value in texts {
                var location = original.location
                if location.hasPrefix("Line ") {
                    let pieces = location.dropFirst(5).split(separator: " ", maxSplits: 1)
                    if let first = pieces.first, let line = Int(first), line > 0 {
                        let adjusted = line.addingReportingOverflow(precedingLines)
                        if !adjusted.overflow {
                            location = "Line \(adjusted.partialValue)" +
                                (pieces.count == 2 ? " " + pieces[1] : "")
                        }
                    }
                }
                try run("INSERT INTO fragments(file,text,kind,location,window) VALUES(?,?,?,?,1)",
                    [.integer(original.file), .text(value), .text(original.kind), .text(location)])
                precedingLines += value.unicodeScalars.lazy.filter { $0 == "\n" }.count
            }
            if let cachedFragmentCount { self.cachedFragmentCount = cachedFragmentCount + texts.count }
        }
        return true
    }
    func pendingFragments(limit: Int = 4, fileID: Int64? = nil) throws -> [NativeSearchLibraryPendingFragment] {
        var fragments: [NativeSearchLibraryPendingFragment] = []
        let sql = """
            SELECT s.id,f.id,f.path,f.size,f.modified,f.continuation,s.text,s.kind,s.location
            FROM fragments s JOIN files f ON s.file=f.id WHERE s.vector IS NULL AND s.state='pending'
            """ + (fileID == nil ? "" : " AND s.file=?") + " ORDER BY s.id LIMIT ?"
        var arguments: [Value] = fileID.map { [.integer($0)] } ?? []
        arguments.append(.integer(Int64(max(0, min(256, limit)))))
        try query(sql, arguments) {
            fragments.append(NativeSearchLibraryPendingFragment(id: columnInteger($0, 0),
                file: record($0, offset: 1), fragment: NativeSearchLibraryFragment(
                    text: text($0, 6), kind: text($0, 7), location: text($0, 8))))
        }
        return fragments
    }
    func commitVector(fragmentID: Int64, namespace: String, vector: [Float]) throws {
        guard namespace == self.namespace, vector.count == dimensions,
            vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
            throw WindowsError.unsupported("The search vector does not match the active model.")
        }
        try run("UPDATE fragments SET vector=?,state='ready',reason='' WHERE id=?", [.blob(vector), .integer(fragmentID)])
    }
    func skipVector(fragmentID: Int64, reason: String) throws {
        guard reason.utf8.count <= 256, !reason.utf16.contains(0) else {
            throw WindowsError.unsupported("Invalid search-vector outcome.")
        }
        try run("UPDATE fragments SET state='skipped',reason=? WHERE id=? AND vector IS NULL",
            [.text(reason), .integer(fragmentID)])
    }
    func waitForMedia(fragmentID: Int64) throws {
        try run("UPDATE fragments SET state='waiting-media',reason='Waiting for compatible media encoders' WHERE id=? AND vector IS NULL",
            [.integer(fragmentID)])
    }
    func deferBudgetVector(fragmentID: Int64, requiredFragments: Int = 2) throws {
        guard (2...256).contains(requiredFragments) else {
            throw WindowsError.unsupported("Invalid semantic window capacity requirement.")
        }
        try run("UPDATE fragments SET state='waiting-budget',reason=? WHERE id=? AND vector IS NULL",
            [.text(String(requiredFragments)), .integer(fragmentID)])
    }
    func retryWaitingBudget() throws {
        let available = Self.maximumFragments - (try fragmentCount())
        guard available >= 2 else { return }
        try run("UPDATE fragments SET state='pending',reason='' WHERE state='waiting-budget' AND CAST(reason AS INTEGER)<=?",
            [.integer(Int64(available))])
        if changes(database) > 0 { try clearRecoveredBudget() }
    }
    func setFileStatus(file: NativeSearchLibraryFile, status: String, partial: Bool) throws {
        guard ["pending", "finished", "failed", "unsupported", "waiting-media"].contains(status) else {
            throw WindowsError.unsupported("Invalid file extraction outcome.")
        }
        try run("UPDATE files SET status=?,partial=?,pending=? WHERE id=? AND size=? AND modified=?",
            [.text(status), .integer(partial ? 1 : 0), .integer(status == "pending" ? 1 : 0),
                .integer(file.id), .integer(file.size), .text(file.modified)])
    }
    private func item(path: String, location: String = "", kind: String = "",
        fragmentID: Int64? = nil) -> SearchItem {
        let title = String(path.split(separator: "\\").last ?? "")
        let subtitle = location.isEmpty ? path : kind + " · " + location + " · " + path
        return SearchItem(id: fragmentID.map { "library-fragment:\($0)" } ?? path,
            title: title, subtitle: subtitle, path: path, kind: "File")
    }
    private enum QueryStop: Error { case budget }
    private func boundedQuery<T>(deadline: UInt64, cancelled: () -> Bool,
        body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(cancelled) { callback in
            let snapshot = !inTransaction
            if snapshot { try run("BEGIN") }
            defer { if snapshot { try? run("ROLLBACK") } }
            let guardState = NativeSearchLibraryQueryGuard(deadline: deadline, cancelled: callback)
            queryGuard = guardState
            let pointer = Unmanaged.passUnretained(guardState).toOpaque()
            progressHandler(database, 4096, { context in
                guard let context else { return 1 }
                return Unmanaged<NativeSearchLibraryQueryGuard>.fromOpaque(context)
                    .takeUnretainedValue().interrupt()
            }, pointer)
            defer { progressHandler(database, 0, nil, nil); queryGuard = nil }
            return try body()
        }
    }
    static func parsedQuery(_ query: String) -> (text: String, kind: String?) {
        guard let separator = query.firstIndex(of: ":") else { return (query, nil) }
        let prefix = query[..<separator].lowercased()
        let kinds = ["code": "code", "pdf": "pdf", "image": "image", "photo": "image",
            "audio": "audio", "video": "video"]
        guard let kind = kinds[prefix] else { return (query, nil) }
        return (query[query.index(after: separator)...].trimmingWhitespace(), kind)
    }
    func searchText(_ query: String, limit: Int = 32,
        milliseconds: UInt64 = 150, progress: (([SearchItem], Bool) -> Void)? = nil,
        cancelled: () -> Bool) throws -> [SearchItem] {
        guard !query.isEmpty, query.utf8.count <= 4096 else { return [] }
        let parsed = Self.parsedQuery(query)
        let terms = parsed.text.lowercased().split(whereSeparator: \.isWhitespace).prefix(16).map(String.init)
        var best: [(SearchItem, Int, String)] = []
        let deadline = GetTickCount64() + max(1, min(2000, milliseconds))
        var rows = 0, incomplete = false
        func check() throws {
            if cancelled() { throw WindowsError.api("Search cancelled", DWORD(ERROR_CANCELLED)) }
            if GetTickCount64() >= deadline { throw QueryStop.budget }
            rows += 1
            if rows % 512 == 0 { progress?(best.map(\.0), true) }
        }
        do {
        try boundedQuery(deadline: deadline, cancelled: cancelled) {
        var contentsSQL = "SELECT f.path,s.text,s.kind,s.location,s.id FROM fragments s JOIN files f ON s.file=f.id"
        var arguments: [Value] = []
        if fullTextAvailable, !terms.isEmpty {
            contentsSQL += " JOIN fulltext ON fulltext.rowid=s.id WHERE fulltext MATCH ? AND s.window=0"
            let match = terms.map { "\"" + $0.split(separator: "\"", omittingEmptySubsequences: false)
                .joined(separator: "\"\"") + "\"" }.joined(separator: " AND ")
            arguments.append(.text(match))
            if let kind = parsed.kind { contentsSQL += " AND s.kind=?"; arguments.append(.text(kind)) }
        } else if let kind = parsed.kind { contentsSQL += " WHERE s.kind=? AND s.window=0"; arguments.append(.text(kind)) }
        else { contentsSQL += " WHERE s.window=0" }
        try self.query(contentsSQL, arguments) { row in
            try check()
            let contents = text(row, 1).lowercased()
            if !terms.isEmpty, terms.allSatisfy({ contents.containsText($0) }) {
                insert(item(path: text(row, 0), location: text(row, 3), kind: text(row, 2),
                    fragmentID: columnInteger(row, 4)),
                    score: 1100, limit: limit, into: &best)
            }
        }
        if best.count == max(0, min(64, limit)), let lowest = best.last?.1, lowest > 1000 { return }
        let filenames = parsed.kind == nil ? "SELECT path FROM files" :
            "SELECT DISTINCT f.path FROM files f JOIN fragments s ON s.file=f.id WHERE s.kind=?"
        let filenameArguments: [Value] = parsed.kind.map { [.text($0)] } ?? []
        if !terms.isEmpty {
            let field = parsed.kind == nil ? "name" : "f.name"
            let matches = terms.map { _ in "instr(\(field),?)>0" }.joined(separator: " AND ")
            let candidates = filenames + (parsed.kind == nil ? " WHERE " : " AND ") + matches
            try self.query(candidates, filenameArguments + terms.map(Value.text)) { row in
                try check()
                let candidate = item(path: text(row, 0))
                let score = SearchRanking.score(candidate.title, query: parsed.text)
                if score > 0 { insert(candidate, score: score, limit: limit, into: &best) }
            }
        }
        if best.count == max(0, min(64, limit)), let lowest = best.last?.1, lowest >= 600 { return }
        // Exact terms are considered first; the bounded fallback preserves abbreviated filename search.
        try self.query(filenames, filenameArguments) { row in
            try check()
            let candidate = item(path: text(row, 0))
            let score = SearchRanking.score(candidate.title, query: parsed.text)
            if score > 0 { insert(candidate, score: score, limit: limit, into: &best) }
        }
        }
        } catch QueryStop.budget { incomplete = true }
        progress?(best.map(\.0), incomplete)
        return best.map(\.0)
    }
    private func insert(_ item: SearchItem, score: Int, limit: Int,
        into best: inout [(SearchItem, Int, String)]) {
        let maximum = max(0, min(64, limit))
        guard maximum > 0 else { return }
        let key = item.path.lowercased()
        if let position = best.firstIndex(where: { $0.2 == key }) {
            guard score > best[position].1 else { return }
            best.remove(at: position)
        }
        if best.count == maximum, let last = best.last,
            score < last.1 || (score == last.1 && item.path >= last.0.path) { return }
        best.append((item, score, key))
        best.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        if best.count > maximum { best.removeLast() }
    }
    func searchVector(_ vector: [Float], namespace: String, limit: Int = 32,
        kind: String? = nil, milliseconds: UInt64 = 150,
        progress: (([SearchItem], Bool) -> Void)? = nil,
        cancelled: () -> Bool) throws -> [SearchItem] {
        guard namespace == self.namespace, vector.count == dimensions,
            vector.allSatisfy(\.isFinite) else { return [] }
        let norm = vector.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { return [] }
        var best: [(SearchItem, Int, String)] = []
        let deadline = GetTickCount64() + max(1, min(2000, milliseconds))
        var rows = 0, incomplete = false
        // shortcut: linear exact cosine search; measure corpus latency before adding an ANN index.
        do {
        try boundedQuery(deadline: deadline, cancelled: cancelled) {
        guard try meta("namespace") == namespace,
            Int(try meta("dimensions") ?? "0") == vector.count else { return }
        let sql = "SELECT f.path,s.kind,s.location,s.vector,s.id FROM fragments s JOIN files f ON s.file=f.id WHERE s.vector IS NOT NULL" +
            (kind == nil ? "" : " AND s.kind=?")
        try query(sql, kind.map { [.text($0)] } ?? []) { row in
            if cancelled() { throw WindowsError.api("Search cancelled", DWORD(ERROR_CANCELLED)) }
            if GetTickCount64() >= deadline { throw QueryStop.budget }
            rows += 1
            if rows % 512 == 0 { progress?(best.map(\.0), true) }
            guard columnBytes(row, 3) == dimensions * MemoryLayout<Float>.size,
                let bytes = columnBlob(row, 3) else { return }
            var dot = Double(0), length = Double(0)
            for index in vector.indices {
                let value = bytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                guard value.isFinite else { return }
                dot += Double(value) * Double(vector[index])
                length += Double(value) * Double(value)
            }
            guard length > 0 else { return }
            let score = Int(max(-1, min(1, dot / (norm * length.squareRoot()))) * 1_000_000)
            if score > 0 {
                insert(item(path: text(row, 0), location: text(row, 2), kind: text(row, 1),
                    fragmentID: columnInteger(row, 4)),
                    score: score, limit: limit, into: &best)
            }
        }
        }
        } catch QueryStop.budget { incomplete = true }
        progress?(best.map(\.0), incomplete)
        return best.map(\.0)
    }
    func fragment(itemID: String) throws -> NativeSearchLibraryFragment? {
        var result: NativeSearchLibraryFragment?
        let prefix = "library-fragment:"
        let fragmentID = itemID.hasPrefix(prefix) ? Int64(itemID.dropFirst(prefix.count)) : nil
        let sql = "SELECT s.text,s.kind,s.location FROM fragments s JOIN files f ON f.id=s.file WHERE " +
            (fragmentID == nil ? "f.path=? ORDER BY s.id LIMIT 1" : "s.id=?")
        try query(sql, [fragmentID.map(Value.integer) ?? .text(itemID)]) {
            result = NativeSearchLibraryFragment(text: text($0, 0), kind: text($0, 1), location: text($0, 2))
        }
        return result
    }
    func pruneMissingDirectory(_ path: String) throws {
        let prefix = path.hasSuffix("\\") ? path : path + "\\"
        try transaction {
            try removeFiles("DELETE FROM files WHERE substr(path,1,?)=? COLLATE NOCASE",
                [.integer(Int64(prefix.unicodeScalars.count)), .text(prefix)])
            try run("DELETE FROM directories WHERE path=? OR substr(path,1,?)=? COLLATE NOCASE",
                [.text(path), .integer(Int64(prefix.unicodeScalars.count)), .text(prefix)])
            try run("DELETE FROM folders WHERE path=? OR substr(path,1,?)=? COLLATE NOCASE",
                [.text(path), .integer(Int64(prefix.unicodeScalars.count)), .text(prefix)])
        }
    }
    func nextGeneration() throws -> String {
        let previous = Int64(try meta("generation") ?? "0") ?? 0
        guard previous < Int64.max else { throw WindowsError.unsupported("Search refresh counter overflow.") }
        let value = String(previous + 1)
        try setMeta("generation", value)
        return value
    }
    func pruneScope(keeping allowed: (String) -> Bool) throws {
        var remove: [Int64] = []
        try query("SELECT id,path FROM files") {
            if !allowed(text($0, 1)) { remove.append(columnInteger($0, 0)) }
        }
        try transaction {
            for id in remove { try removeFiles("DELETE FROM files WHERE id=?", [.integer(id)]) }
        }
    }
    static func checkStorageBudgetRecovery(databasePath: String) throws {
        func expect(_ value: Bool) throws {
            guard value else { throw WindowsError.unsupported("SQLite storage-budget recovery fixture failed.") }
        }
        var allocated = 0
        do {
            let store = try NativeSearchLibraryStore(databasePath: databasePath)
            try store.run("PRAGMA max_page_count=32")
            store.maximumPageCount = 32
            try expect(try store.count("PRAGMA max_page_count") == 32)
            var full = false
            for index in 0..<64 {
                do {
                    try store.observe(path: databasePath + "-source\(index).txt", parent: "fixture",
                        size: 32768, modified: "fixture", generation: "fixture")
                    guard let file = try store.pendingFiles(limit: 1).first else {
                        throw WindowsError.unsupported("SQLite budget fixture pending file is missing.")
                    }
                    try store.replaceFragments(file: file, fragments: [.init(
                        text: String(repeating: "bounded fixture text ", count: 180),
                        kind: "text", location: "Line 1")])
                } catch {
                    try expect(try store.status().storageFull && store.status().budgetReason == "storage")
                    full = true
                    break
                }
            }
            try expect(full)
            allocated = try store.count("PRAGMA page_count")
        }
        do {
            let reopened = try NativeSearchLibraryStore(databasePath: databasePath)
            try expect(try reopened.status().storageFull)
            try reopened.reset()
            reopened.maximumPageCount = 32
            try expect(try !reopened.status().storageFull && reopened.count("PRAGMA page_count") == allocated &&
                reopened.count("PRAGMA freelist_count") > 0)
            try reopened.observe(path: databasePath + "-reused.txt", parent: "fixture", size: 10,
                modified: "fixture", generation: "fixture")
            guard let file = try reopened.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("SQLite budget fixture could not reuse free pages.")
            }
            try expect(try reopened.replaceFragments(file: file,
                fragments: [.init(text: "reused", kind: "text", location: "Line 1")]))
        }
    }
}
