// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK

/// Read-only Shell/index providers run in a disposable child. A stalled COM provider never owns the UI or input thread.
enum NativeSearchProcess {
    private static func jobs() throws -> String {
        let root = try NativeFiles.path("SearchJobs")
        try NativeFiles.createDirectory(root)
        guard NativeSearchFiles.validFolder(root) else { throw WindowsError.unsupported("Search jobs require a local, unlinked folder.") }
        return root
    }
    static func query(_ query: String, cancelled: () -> Bool) throws -> (items: [SearchItem], status: String) {
        try SearchWire.decode(perform(query,operation:"--search-worker",timeout:2500,cancelled:cancelled))
    }
    static func applications(_ query:String,cancelled:()->Bool) throws -> [SearchItem] {
        try SearchWire.decode(perform(query,operation:"--search-apps-worker",timeout:2000,cancelled:cancelled)).items
    }
    static func rates(cancelled: () -> Bool) throws -> (ReferenceRates, cached: Bool) {
        let fields = try StateJSON.decode(perform("",operation:"--search-rates-worker",timeout:6000,cancelled:cancelled))
        guard let date = fields["date"]?.string, let cached = fields["cached"]?.bool else { throw WindowsError.unsupported("Invalid reference-rate result.") }
        var rates: [String:Double] = [:]
        for (key,value) in fields where key != "date" && key != "cached" {
            guard let text = value.string, let rate = Double(text) else { throw WindowsError.unsupported("Invalid currency reference rate.") }; rates[key] = rate
        }
        return (try ReferenceRates(date:date,rates:rates),cached)
    }
    static func library(_ query: String, namespace: String = "", vector: [Float] = [],
        cancelled: () -> Bool) throws -> (items: [SearchItem], status: String) {
        guard vector.count <= 1024, vector.allSatisfy(\.isFinite) else { throw WindowsError.unsupported("Invalid library query vector.") }
        var payload = NativeEmbeddingWriter()
        try payload.string(query, maximum: 4096); try payload.string(namespace, maximum: 1024)
        payload.integer(UInt32(vector.count))
        for value in vector { payload.integer(value.bitPattern) }
        return try SearchWire.decode(perform("", operation: "--search-library-worker", timeout: 2500,
            cancelled: cancelled, payload: payload.bytes))
    }
    private static func perform(_ query: String, operation: String, timeout: UInt64, cancelled: () -> Bool,
        payload: [UInt8]? = nil) throws -> [UInt8] {
        guard query.utf8.count <= 4096, !query.utf8.contains(0) else { throw WindowsError.unsupported("Search query is too long.") }
        guard payload == nil || payload!.count <= 16384 else { throw WindowsError.unsupported("Library request exceeds its size limit.") }
        guard !cancelled() else { throw WindowsError.unsupported("Search cancelled.") }
        var guid = GUID(), characters = [WCHAR](repeating: 0, count: 40)
        guard CoCreateGuid(&guid) >= 0, StringFromGUID2(&guid, &characters, Int32(characters.count)) > 0 else { throw WindowsError.unsupported("Create search job identity.") }
        let name = String(decoding: characters.prefix(while: { $0 != 0 }), as: UTF16.self).filter { $0.isHexDigit || $0 == "-" }
        let folder = try jobs() + "\\" + name
        guard try !NativeFiles.exists(folder) else { throw WindowsError.unsupported("Search job identity already exists.") }
        try NativeEmbeddingAssets.privateDirectory(folder)
        let request = folder + "\\query.txt", result = folder + "\\result.bin"
        defer { try? NativeFiles.remove(request); try? NativeFiles.remove(result); _ = withWideString(folder) { RemoveDirectoryW($0) } }
        try NativeFiles.write(payload ?? Array(query.utf8), to: request)
        let executable = executablePath()
        var command = Array(([quoteArgument(executable), operation, quoteArgument(folder)]).joined(separator: " ").utf16) + [0]
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION(); startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        let job = try OwnedHandle(CreateJobObjectW(nil, nil))
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_PROCESS_MEMORY)
        limits.ProcessMemoryLimit = 268_435_456
        guard SetInformationJobObject(job.raw, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout.size(ofValue: limits))) else { throw WindowsError.api("Limit search worker", GetLastError()) }
        guard !cancelled() else { throw WindowsError.unsupported("Search cancelled.") }
        guard withWideString(executable, { CreateProcessW($0, &command, nil, nil, false,
            DWORD(CREATE_NO_WINDOW | CREATE_SUSPENDED | BELOW_NORMAL_PRIORITY_CLASS), nil, nil, &startup, &information) }) else { throw WindowsError.api("Start search worker", GetLastError()) }
        let process = try OwnedHandle(information.hProcess), thread = try OwnedHandle(information.hThread)
        guard AssignProcessToJobObject(job.raw, process.raw) else { TerminateProcess(process.raw, DWORD(ERROR_CANCELLED)); throw WindowsError.api("Isolate search worker", GetLastError()) }
        guard ResumeThread(thread.raw) != DWORD.max else { throw WindowsError.api("Resume search worker", GetLastError()) }
        let deadline = GetTickCount64() + timeout
        while true {
            if WaitForSingleObject(process.raw, 25) == DWORD(WAIT_OBJECT_0) { break }
            if cancelled() || GetTickCount64() >= deadline {
                TerminateJobObject(job.raw, DWORD(ERROR_CANCELLED)); _ = WaitForSingleObject(process.raw, 1000)
                throw WindowsError.unsupported(cancelled() ? "Search cancelled." : "Windows Search is taking too long. Local filename results remain available.")
            }
        }
        var code: DWORD = 0
        guard GetExitCodeProcess(process.raw, &code), code == 0 else {
            throw WindowsError.unsupported(operation == "--search-library-worker"
                ? "The local library is not ready. Check Index status in Search settings; basic results remain available."
                : "Windows Search is unavailable. Local filename results remain available.")
        }
        return try NativeFiles.read(result, maximum: 1_048_576)
    }
    static func selfCheck() throws {
        var preferences = SearchPreferences(contents: "semantic=1\nallLocalDrives=0\nfolder=C:\\fixture\n")
        guard preferences.semanticSetupMessage(folderAvailable: true, documentCount: 0).lowercased().containsText("no supported text"),
            preferences.semanticSetupMessage(folderAvailable: false, documentCount: 1).containsText("Choose"),
            preferences.semanticSetupMessage(folderAvailable: true, documentCount: 1).containsText("indexed") else {
            throw WindowsError.unsupported("Semantic folder readiness was misreported.")
        }
        preferences.semantic = false
        guard preferences.semanticSetupMessage(folderAvailable: true, documentCount: 1).containsText("Enable") else {
            throw WindowsError.unsupported("Disabled semantic search was reported ready.")
        }
        let variable = "LOCALAPPDATA"
        var previous = [WCHAR](repeating: 0, count: 32768)
        let length = withWideString(variable) { GetEnvironmentVariableW($0, &previous, DWORD(previous.count)) }
        guard length < previous.count else { throw WindowsError.unsupported("Search fixture environment is too large.") }
        let original = length > 0 ? String(decoding: previous.prefix(Int(length)), as: UTF16.self) : nil
        defer {
            _ = withWideString(variable) { name in
                original.map { value in withWideString(value) { SetEnvironmentVariableW(name, $0) } }
                    ?? SetEnvironmentVariableW(name, nil)
            }
        }
        // An invalid process-local path makes any accidental provider I/O fail before cancellation.
        guard withWideString(variable, { name in withWideString("\"") { SetEnvironmentVariableW(name, $0) } }) else {
            throw WindowsError.api("Prepare cancelled Search fixture", GetLastError())
        }
        for operation in ["--search-worker", "--search-apps-worker", "--search-rates-worker", "--search-library-worker"] {
            var checks = 0
            do {
                _ = try perform("test", operation: operation, timeout: 1, cancelled: { checks += 1; return true })
                throw WindowsError.unsupported("Cancelled provider was accepted.")
            } catch WindowsError.unsupported(let text) {
                guard text == "Search cancelled.", checks == 1 else { throw WindowsError.unsupported("Cancelled provider performed setup work.") }
            }
        }
        Console.writeLine("PASS: cancelled Search providers stop before filesystem or child-process setup")
    }
    static func runWorker(folder: String, rates:Bool = false, applications:Bool = false, library:Bool = false) throws -> Int32 {
        let root = try jobs()
        guard let last = folder.lastIndex(of: "\\"), equalWindowsNames(String(folder[..<last]), root),
            folder[folder.index(after: last)...].utf8.count == 36,
            folder[folder.index(after: last)...].allSatisfy({ $0.isHexDigit || $0 == "-" }), NativeSearchFiles.validFolder(folder) else { throw WindowsError.unsupported("Invalid search job folder.") }
        if rates {
            let current = try NativeSearchRates.current()
            var fields: [String:StateField] = ["date":.string(current.0.date),"cached":.bool(current.cached)]
            for (currency,value) in current.0.rates { fields[currency] = .string(String(value)) }
            try NativeFiles.write(StateJSON.encode(fields),to:folder + "\\result.bin")
            return 0
        }
        if library {
            var request = NativeEmbeddingReader(bytes: try NativeFiles.read(folder + "\\query.txt", maximum: 16384))
            let query = try request.string(maximum: 4096), namespace = try request.string(maximum: 1024)
            let count = Int(try request.integer())
            guard count <= 1024 else { throw WindowsError.unsupported("Invalid library request dimensions.") }
            var vector: [Float] = []
            for _ in 0..<count { vector.append(Float(bitPattern: try request.integer())) }
            try request.finished()
            guard vector.allSatisfy(\.isFinite) else { throw WindowsError.unsupported("Invalid library vector values.") }
            let store = try NativeSearchLibraryStore(databasePath: NativeSearchLibraryStore.databasePath(), readOnly: true)
            var partial = false
            let items: [SearchItem]
            if vector.isEmpty {
                items = try store.searchText(query, progress: { _, incomplete in partial = incomplete }, cancelled: { false })
            } else {
                items = try store.searchVector(vector, namespace: namespace, kind: NativeSearchLibraryStore.parsedQuery(query).kind,
                    progress: { _, incomplete in partial = incomplete }, cancelled: { false })
            }
            try NativeFiles.write(SearchWire.encode(items, status: partial ? "Local library · partial results within query budget" : "Local library"),
                to: folder + "\\result.bin")
            return 0
        }
        guard let query = String(validating: try NativeFiles.read(folder + "\\query.txt", maximum: 4096), as: UTF8.self), !query.utf8.contains(0) else { throw WindowsError.unsupported("Invalid search query.") }
        if applications {
            var status = "Applications"
            let catalog = try NativeIndexedSearch.applications(onDegraded:{ status = $0 })
            let apps = SearchRanking.results(catalog,query:query,limit:32)
            try NativeFiles.write(SearchWire.encode(apps,status:status),to:folder + "\\result.bin"); return 0
        }
        var items: [SearchItem] = []
        var status = "Windows Index"
        if !query.isEmpty {
            do { items += try NativeIndexedSearch.query(query) }
            catch { status = "Windows Index unavailable · local filenames and apps" }
        }
        // Index content matches are retained even when their filenames do not contain the query.
        let apps = SearchRanking.results(items.filter { $0.kind == "Application" }, query: query, limit: 20)
        let files = items.filter { $0.kind != "Application" }.prefix(32)
        try NativeFiles.write(SearchWire.encode(Array((apps + files).prefix(48)), status: status), to: folder + "\\result.bin")
        return 0
    }
}
