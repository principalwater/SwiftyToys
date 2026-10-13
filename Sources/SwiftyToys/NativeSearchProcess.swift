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
    private static func perform(_ query: String, operation: String, timeout: UInt64, cancelled: () -> Bool) throws -> [UInt8] {
        guard query.utf8.count <= 4096, !query.utf8.contains(0) else { throw WindowsError.unsupported("Search query is too long.") }
        var guid = GUID(), characters = [WCHAR](repeating: 0, count: 40)
        guard CoCreateGuid(&guid) >= 0, StringFromGUID2(&guid, &characters, Int32(characters.count)) > 0 else { throw WindowsError.unsupported("Create search job identity.") }
        let name = String(decoding: characters.prefix(while: { $0 != 0 }), as: UTF16.self).filter { $0.isHexDigit || $0 == "-" }
        let folder = try jobs() + "\\" + name
        guard try !NativeFiles.exists(folder) else { throw WindowsError.unsupported("Search job identity already exists.") }
        try NativeEmbeddingAssets.privateDirectory(folder)
        let request = folder + "\\query.txt", result = folder + "\\result.bin"
        defer { try? NativeFiles.remove(request); try? NativeFiles.remove(result); _ = withWideString(folder) { RemoveDirectoryW($0) } }
        try NativeFiles.write(Array(query.utf8), to: request)
        let executable = executablePath()
        var command = Array(([quoteArgument(executable), operation, quoteArgument(folder)]).joined(separator: " ").utf16) + [0]
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION(); startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        let job = try OwnedHandle(CreateJobObjectW(nil, nil))
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_PROCESS_MEMORY)
        limits.ProcessMemoryLimit = 268_435_456
        guard SetInformationJobObject(job.raw, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout.size(ofValue: limits))) else { throw WindowsError.api("Limit search worker", GetLastError()) }
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
        guard GetExitCodeProcess(process.raw, &code), code == 0 else { throw WindowsError.unsupported("Windows Search is unavailable. Local filename results remain available.") }
        return try NativeFiles.read(result, maximum: 1_048_576)
    }
    static func runWorker(folder: String, rates:Bool = false, applications:Bool = false) throws -> Int32 {
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
