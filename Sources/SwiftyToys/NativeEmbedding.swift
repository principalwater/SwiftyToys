// SPDX-License-Identifier: MIT
import Synchronization
import BrightnessCore
import WinSDK
import WindowsDisplayABI
import EmbeddingABI

/// Only processes created by this object enter its job; cancellation cannot reach a resident or watchdog.
final class NativeEmbeddingProcess: @unchecked Sendable {
    let process: OwnedHandle
    let job: OwnedHandle
    let id: DWORD
    init(executable: String, arguments: [String], memoryMiB: Int = 1536) throws {
        guard (64...1536).contains(memoryMiB), arguments.allSatisfy({ !$0.utf16.contains(0) }) else { throw WindowsError.unsupported("Invalid local search worker limits.") }
        job = try OwnedHandle(CreateJobObjectW(nil, nil))
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_ACTIVE_PROCESS)
        limits.BasicLimitInformation.ActiveProcessLimit = 1
        limits.ProcessMemoryLimit = SIZE_T(memoryMiB * 1024 * 1024)
        guard SetInformationJobObject(job.raw, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)) else { throw WindowsError.api("Bound local search worker", GetLastError()) }
        var command = Array(([quoteArgument(executable)] + arguments.map(quoteArgument)).joined(separator: " ").utf16) + [0]
        guard command.count <= 32767 else { throw WindowsError.unsupported("Local search worker command is too long.") }
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        guard withWideString(try NativeFiles.windowsPath(executable), { CreateProcessW($0, &command, nil, nil, false, DWORD(CREATE_SUSPENDED | CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS), nil, nil, &startup, &information) }) else { throw WindowsError.api("Start local search worker", GetLastError()) }
        process = try OwnedHandle(information.hProcess)
        let thread = try OwnedHandle(information.hThread)
        id = information.dwProcessId
        guard AssignProcessToJobObject(job.raw, process.raw), ResumeThread(thread.raw) != DWORD.max else {
            _ = TerminateProcess(process.raw, DWORD(ERROR_CANCELLED)); throw WindowsError.api("Start bounded local search worker", GetLastError())
        }
    }
    var ended: Bool { WaitForSingleObject(process.raw, 0) == DWORD(WAIT_OBJECT_0) }
    func stop(wait: Bool = false) {
        _ = TerminateJobObject(job.raw, DWORD(ERROR_CANCELLED))
        if wait { _ = WaitForSingleObject(process.raw, 5000) }
    }
    func wait(milliseconds: DWORD, cancelled: @Sendable () -> Bool) throws {
        let deadline = GetTickCount64() + UInt64(milliseconds)
        while true {
            if cancelled() { stop(wait: true); throw WindowsError.api("Local search operation cancelled", DWORD(ERROR_CANCELLED)) }
            let remaining = deadline > GetTickCount64() ? deadline - GetTickCount64() : 0
            guard remaining > 0 else { stop(wait: true); throw WindowsError.unsupported("The local search component timed out.") }
            let result = WaitForSingleObject(process.raw, DWORD(min(remaining, 100)))
            if result == DWORD(WAIT_TIMEOUT) { continue }
            guard result == DWORD(WAIT_OBJECT_0) else { throw WindowsError.api("Wait for local search component", GetLastError()) }
            var code: DWORD = 1
            guard GetExitCodeProcess(process.raw, &code), code == 0 else { throw WindowsError.unsupported("The local search component could not finish (status \(code)).") }
            return
        }
    }
}

struct NativeEmbeddingWriter {
    var bytes: [UInt8] = []
    mutating func integer(_ value: UInt32) { for shift in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
    mutating func string(_ value: String, maximum: Int) throws {
        guard value.utf8.count <= maximum else { throw WindowsError.unsupported("The local search text exceeds its limit.") }
        integer(UInt32(value.utf8.count)); bytes += value.utf8
    }
}
struct NativeEmbeddingReader {
    let bytes: [UInt8]
    var cursor = 0
    mutating func integer() throws -> UInt32 {
        guard cursor <= bytes.count, bytes.count - cursor >= 4 else { throw WindowsError.unsupported("The local search worker returned an incomplete message.") }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[cursor + index]) << (index * 8) }
        cursor += 4; return value
    }
    mutating func string(maximum: Int) throws -> String {
        let length = Int(try integer())
        guard length <= maximum, cursor <= bytes.count, length <= bytes.count - cursor,
            let value = String(validating: bytes[cursor..<(cursor + length)], as: UTF8.self) else { throw WindowsError.unsupported("The local search worker returned invalid text.") }
        cursor += length; return value
    }
    func finished() throws {
        guard cursor == bytes.count else { throw WindowsError.unsupported("The local search worker returned unexpected data.") }
    }
}

/// Overlapped I/O sleeps on events. Buffers and OVERLAPPED storage live until completion or drained cancellation.
final class NativeEmbeddingChannel: @unchecked Sendable {
    static let prefix = "\\\\.\\pipe\\SwiftyToys.Embedding."
    let pipe: OwnedHandle
    let event: OwnedHandle
    init(serverName: String) throws {
        let descriptor = try NativeEmbeddingAssets.descriptor(); defer { LocalFree(descriptor) }
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
        pipe = try OwnedHandle(withWideString(serverName) { CreateNamedPipeW($0, DWORD(PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE), DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS), 1, 65536, 65536, 0, &attributes) })
        event = try OwnedHandle(CreateEventW(nil, true, false, nil))
    }
    init(clientName: String) throws {
        guard Self.validName(clientName) else { throw WindowsError.unsupported("Invalid local search pipe.") }
        pipe = try OwnedHandle(withWideString(clientName) { CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OVERLAPPED), nil) })
        event = try OwnedHandle(CreateEventW(nil, true, false, nil))
    }
    static func validName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.utf8.count == 32 && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    func connect(child: NativeEmbeddingProcess, cancelled: @escaping @Sendable () -> Bool) throws {
        var operation = OVERLAPPED(); operation.hEvent = event.raw
        let connected = ConnectNamedPipe(pipe.raw, &operation)
        if !connected {
            let code = GetLastError()
            if code == DWORD(ERROR_IO_PENDING) { _ = try completion(&operation, deadline: GetTickCount64() + 15000, cancelled: cancelled) }
            else if code != DWORD(ERROR_PIPE_CONNECTED) { throw WindowsError.api("Connect local search worker", code) }
        }
        var client: ULONG = 0
        guard GetNamedPipeClientProcessId(pipe.raw, &client), client == child.id else { throw WindowsError.unsupported("The local search connection belongs to another process.") }
    }
    private func completion(_ operation: inout OVERLAPPED, deadline: UInt64, cancelled: (@Sendable () -> Bool)?) throws -> DWORD {
        var result: DWORD = 0
        while true {
            let now = GetTickCount64(), remaining = deadline > now ? deadline - now : 0
            // Active requests check the caller's generation while sleeping; idle workers wait once for60seconds.
            result = WaitForSingleObject(event.raw, DWORD(min(remaining, cancelled == nil ? UInt64(DWORD.max) : 50)))
            if cancelled?() == true { result = DWORD(WAIT_TIMEOUT); break }
            if result == DWORD(WAIT_TIMEOUT), GetTickCount64() < deadline { continue }
            break
        }
        guard result == DWORD(WAIT_OBJECT_0) else {
            _ = CancelIoEx(pipe.raw, &operation)
            var ignored: DWORD = 0
            _ = GetOverlappedResult(pipe.raw, &operation, &ignored, true)
            if cancelled?() == true { throw WindowsError.api("Local semantic search cancelled", DWORD(ERROR_CANCELLED)) }
            if result == DWORD(WAIT_TIMEOUT) { throw WindowsError.unsupported("Local semantic search timed out. Text search remains available.") }
            throw WindowsError.api("Wait for local search message", GetLastError())
        }
        var transferred: DWORD = 0
        guard GetOverlappedResult(pipe.raw, &operation, &transferred, false) else { throw WindowsError.api("Receive local search message", GetLastError()) }
        return transferred
    }
    private func transfer(_ data: UnsafeMutableRawBufferPointer, write: Bool, deadline: UInt64, cancelled: (@Sendable () -> Bool)?) throws {
        var cursor = 0
        while cursor < data.count {
            if cancelled?() == true { throw WindowsError.api("Local semantic search cancelled", DWORD(ERROR_CANCELLED)) }
            var operation = OVERLAPPED(); operation.hEvent = event.raw
            guard ResetEvent(event.raw) else { throw WindowsError.api("Reset local search event", GetLastError()) }
            var transferred: DWORD = 0
            let start = data.baseAddress!.advanced(by: cursor)
            let count = DWORD(data.count - cursor)
            let result = write ? WriteFile(pipe.raw, start, count, &transferred, &operation) : ReadFile(pipe.raw, start, count, &transferred, &operation)
            if !result {
                let code = GetLastError()
                guard code == DWORD(ERROR_IO_PENDING) else { throw WindowsError.api("Exchange local search message", code) }
                transferred = try completion(&operation, deadline: deadline, cancelled: cancelled)
            }
            guard transferred > 0, transferred <= count else { throw WindowsError.unsupported("The local search connection ended unexpectedly.") }
            cursor += Int(transferred)
        }
    }
    func send(_ body: [UInt8], deadline: UInt64, cancelled: (@Sendable () -> Bool)? = nil) throws {
        guard !body.isEmpty, body.count <= 1_048_576 else { throw WindowsError.unsupported("Invalid local search message length.") }
        var header = NativeEmbeddingWriter(); header.integer(0x31424D45); header.integer(UInt32(body.count))
        var message = header.bytes + body
        try message.withUnsafeMutableBytes { try transfer($0, write: true, deadline: deadline, cancelled: cancelled) }
    }
    func receive(deadline: UInt64, cancelled: (@Sendable () -> Bool)? = nil) throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 8)
        try header.withUnsafeMutableBytes { try transfer($0, write: false, deadline: deadline, cancelled: cancelled) }
        var reader = NativeEmbeddingReader(bytes: header)
        guard try reader.integer() == 0x31424D45 else { throw WindowsError.unsupported("The local search worker uses an incompatible protocol.") }
        let count = Int(try reader.integer())
        guard (1...1_048_576).contains(count) else { throw WindowsError.unsupported("Invalid local search message length.") }
        var message = [UInt8](repeating: 0, count: count)
        try message.withUnsafeMutableBytes { try transfer($0, write: false, deadline: deadline, cancelled: cancelled) }
        return message
    }
}

private final class NativeEmbeddingWorker: @unchecked Sendable {
    let channel: NativeEmbeddingChannel
    let child: NativeEmbeddingProcess
    init(assetDirectory: String?, cancelled: @escaping @Sendable () -> Bool) throws {
        let name = NativeEmbeddingChannel.prefix + (try NativeEmbeddingAssets.guid())
        channel = try NativeEmbeddingChannel(serverName: name)
        let arguments = assetDirectory.map { ["--embedding-worker-test", name, $0] } ?? ["--embedding-worker", name]
        child = try NativeEmbeddingProcess(executable: executablePath(), arguments: arguments)
        do { try channel.connect(child: child, cancelled: cancelled) } catch { child.stop(); throw error }
    }
}

enum NativeEmbedding {
    private struct State: Sendable { var worker: NativeEmbeddingWorker?; var busy = false }
    private static let state = Mutex(State())
    static func cancel() { close() }
    static func close() {
        let worker = state.withLock { state in let worker = state.worker; state.worker = nil; return worker }
        worker?.child.stop()
    }
    static func closeForRemoval() {
        let worker = state.withLock { state in let worker = state.worker; state.worker = nil; return worker }
        worker?.child.stop(wait: true)
    }
    static func rank(query: String, documents: [NativeEmbeddingDocument], progress: @Sendable (String) -> Void = { _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [NativeEmbeddingMatch] {
        try rank(query: query, documents: documents, assetDirectory: nil, progress: progress, cancelled: cancelled)
    }
    private static func rank(query: String, documents: [NativeEmbeddingDocument], assetDirectory: String?, progress: @Sendable (String) -> Void, cancelled: @escaping @Sendable () -> Bool) throws -> [NativeEmbeddingMatch] {
        guard !query.isEmpty, query.utf8.count <= 4096, (1...8).contains(documents.count), documents.allSatisfy({ $0.title.utf8.count <= 4096 && $0.text.utf8.count <= 65536 }) else { throw WindowsError.unsupported("The local search request exceeds its text budget.") }
        try NativeEmbeddingAssets.cancelled(cancelled)
        if assetDirectory == nil {
            guard try NativeEmbeddingAssets.status() == .downloaded else { throw WindowsError.unsupported("Download the optional local search model first. Text search remains available.") }
        }
        guard state.withLock({ state in if state.busy { return false }; state.busy = true; return true }) else { throw WindowsError.unsupported("Local semantic search is busy. Text search remains available.") }
        defer { state.withLock { $0.busy = false } }
        let worker: NativeEmbeddingWorker
        if let current = state.withLock({ $0.worker }), !current.child.ended { worker = current }
        else {
            let created = try NativeEmbeddingWorker(assetDirectory: assetDirectory, cancelled: cancelled)
            if cancelled() { created.child.stop(); throw WindowsError.api("Local semantic search cancelled", DWORD(ERROR_CANCELLED)) }
            state.withLock { $0.worker = created }; worker = created
        }
        do {
            var request = NativeEmbeddingWriter(); request.integer(1); try request.string(query, maximum: 4096); request.integer(UInt32(documents.count))
            for document in documents { try request.string(document.title, maximum: 4096); try request.string(document.text, maximum: 65536) }
            let deadline = GetTickCount64() + 30000
            try worker.channel.send(request.bytes, deadline: deadline, cancelled: cancelled)
            while true {
                try NativeEmbeddingAssets.cancelled(cancelled)
                var response = NativeEmbeddingReader(bytes: try worker.channel.receive(deadline: deadline, cancelled: cancelled))
                switch try response.integer() {
                case 2:
                    let count = Int(try response.integer())
                    guard count == documents.count else { throw WindowsError.unsupported("The local search worker returned an unexpected result count.") }
                    var result: [NativeEmbeddingMatch] = [], indices: Set<Int> = []
                    for _ in 0..<count {
                        let index = Int(try response.integer()), score = Float(bitPattern: try response.integer())
                        guard documents.indices.contains(index), indices.insert(index).inserted, score.isFinite, (-1.001...1.001).contains(score) else { throw WindowsError.unsupported("The local search worker returned invalid scores.") }
                        result.append(.init(id: documents[index].id, score: score))
                    }
                    try response.finished(); return result
                case 3:
                    let reason = try response.string(maximum: 4096); try response.finished(); throw WindowsError.unsupported(reason)
                case 4:
                    let message = try response.string(maximum: 1024); try response.finished(); progress(message)
                default: throw WindowsError.unsupported("The local search worker returned an invalid response.")
                }
            }
        } catch { worker.child.stop(); state.withLock { $0.worker = nil }; throw error }
    }
    static func runWorker(pipeName: String, assetDirectory: String? = nil) -> Int32 {
        do {
            let channel = try NativeEmbeddingChannel(clientName: pipeName)
            var engine: NativeEmbeddingEngine?
            while true {
                let body: [UInt8]
                do { body = try channel.receive(deadline: GetTickCount64() + 60000) } catch { return 0 }
                let deadline = GetTickCount64() + 30000
                do {
                    var request = NativeEmbeddingReader(bytes: body)
                    guard try request.integer() == 1 else { throw WindowsError.unsupported("Invalid local search request.") }
                    let query = try request.string(maximum: 4096), count = Int(try request.integer())
                    guard (1...8).contains(count) else { throw WindowsError.unsupported("Too many local documents.") }
                    var documents: [NativeEmbeddingDocument] = []
                    for index in 0..<count { documents.append(.init(id: String(index), title: try request.string(maximum: 4096), text: try request.string(maximum: 65536))) }
                    try request.finished()
                    func report(_ stage: String) throws { var progress = NativeEmbeddingWriter(); progress.integer(4); try progress.string(stage, maximum: 1024); try channel.send(progress.bytes, deadline: deadline) }
                    if engine == nil {
                        try report("Loading and validating the local search model…")
                        let loaded = try NativeEmbeddingEngine(assetDirectory: assetDirectory); try loaded.validateInference(); engine = loaded
                        try report("Local semantic search is ready.")
                    }
                    let scores = try engine!.rank(query: query, documents: documents, progress: report)
                    var response = NativeEmbeddingWriter(); response.integer(2); response.integer(UInt32(scores.count))
                    for (index, score) in scores { response.integer(UInt32(index)); response.integer(score.bitPattern) }
                    try channel.send(response.bytes, deadline: deadline)
                } catch {
                    var response = NativeEmbeddingWriter(); response.integer(3)
                    try response.string(String(describing: error), maximum: 4096)
                    try channel.send(response.bytes, deadline: deadline)
                }
            }
        } catch { return 1 }
    }
    static func selfCheck() throws {
        var encoded = NativeEmbeddingWriter(); encoded.integer(1); try encoded.string("Русский 🌍", maximum: 64)
        var decoded = NativeEmbeddingReader(bytes: encoded.bytes)
        guard try decoded.integer() == 1, try decoded.string(maximum: 64) == "Русский 🌍" else { throw WindowsError.unsupported("Embedding protocol Unicode roundtrip failed.") }
        try decoded.finished()
        for bytes in [[UInt8](repeating: 0, count: 3), [255,255,255,255]] {
            do { var reader = NativeEmbeddingReader(bytes: bytes); _ = try reader.string(maximum: 64); throw WindowsError.unsupported("Embedding protocol accepted invalid length.") } catch let error as WindowsError {
                guard !error.description.containsText("accepted") else { throw error }
            }
        }
        guard NativeEmbeddingChannel.validName(NativeEmbeddingChannel.prefix + "0123456789abcdef0123456789abcdef"), !NativeEmbeddingChannel.validName("\\\\.\\pipe\\other"), !NativeEmbeddingChannel.validName(NativeEmbeddingChannel.prefix + "..\\other") else { throw WindowsError.unsupported("Embedding pipe identity validation failed.") }
        Console.writeLine("PASS: native embedding protocol bounds, Unicode and private pipe name; no model downloaded or loaded")
    }
    static func selfCheck(assetDirectory: String) throws {
        closeForRemoval()
        defer { closeForRemoval() }
        let documents = [NativeEmbeddingDocument(id: "dog", title: "", text: "A dog is playing in the park."), .init(id: "math", title: "", text: "Linear algebra studies matrices and vector spaces.")]
        let began = GetTickCount64()
        let result = try rank(query: "find my dog", documents: documents, assetDirectory: assetDirectory, progress: { Console.writeLine($0) }, cancelled: { false })
        guard result.count == 2, result[0].id == "dog", result[0].score > result[1].score + 0.05 else { throw WindowsError.unsupported("Live native embedding IPC retrieval check failed.") }
        let cold = GetTickCount64() - began, warmStart = GetTickCount64()
        let warm = try rank(query: "find my dog", documents: documents, assetDirectory: assetDirectory, progress: { _ in }, cancelled: { false })
        guard warm.map(\.id) == result.map(\.id), warm.map(\.score) == result.map(\.score) else { throw WindowsError.unsupported("Live native embedding cached batch check failed.") }
        Console.writeLine("PASS: same-executable CPU worker and real retrieval; dog \(result[0].score), math \(result[1].score); cold \(cold)ms, cached query/document batch \(GetTickCount64() - warmStart)ms")
        let paragraph = "A garden needs careful watering during warm weather. Check the soil before adding water, mulch the surface, and water deeply early in the morning so the roots stay healthy. "
        let longDocuments = (0..<10).map { NativeEmbeddingDocument(id: "garden\($0)", title: "Garden \($0)", text: String(repeating: paragraph, count: 12)) }
        do {
            let tokenizer = try GemmaBPETokenizer(path: assetDirectory + "\\" + NativeEmbeddingAssets.tokenizer.name)
            guard try longDocuments.allSatisfy({ try tokenizer.encode(text: GemmaBPETokenizer.document(title: $0.title, content: $0.text), maxTokens: 128).count == 128 }) else { throw WindowsError.unsupported("Live embedding benchmark did not reach its token cap.") }
        }
        for range in [0..<2, 2..<10] {
            let batchStart = GetTickCount64()
            let matches = try rank(query: "How should gardens be watered in summer?", documents: Array(longDocuments[range]), assetDirectory: assetDirectory, progress: { _ in }, cancelled: { false })
            guard matches.count == range.count, matches.allSatisfy({ $0.score.isFinite }) else { throw WindowsError.unsupported("Live embedding capped document batch failed.") }
            Console.writeLine("PASS: \(range.count) real 128-token documents through bounded IPC in \(GetTickCount64() - batchStart)ms")
        }
        closeForRemoval()
        let cancelStart = GetTickCount64()
        do {
            _ = try rank(query: "find my dog", documents: documents, assetDirectory: assetDirectory, progress: { _ in }, cancelled: { GetTickCount64() - cancelStart >= 100 })
            throw WindowsError.unsupported("Live native embedding startup cancellation was ignored.")
        } catch let error as WindowsError {
            guard case .api(_, let code) = error, code == DWORD(ERROR_CANCELLED) else { throw error }
        }
        guard GetTickCount64() - cancelStart <= 1000 else { throw WindowsError.unsupported("Live native embedding startup cancellation was too slow.") }
        closeForRemoval()
        Console.writeLine("PASS: cancellation during cold model startup and owned-worker cleanup in \(GetTickCount64() - cancelStart)ms")
    }
}
