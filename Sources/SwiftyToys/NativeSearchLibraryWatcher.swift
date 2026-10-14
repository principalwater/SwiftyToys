// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

private final class NativeSearchLibraryWatch {
    let root: String
    private var directory: HANDLE?
    private var event: HANDLE?
    private let bytes = UnsafeMutableRawPointer.allocate(byteCount: 32768, alignment: 4)
    private let operation = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
    private var pending = false
    private var stopped = false
    private var drainedOnStop = true
    private var released = false

    init(root: String) throws {
        self.root = root
        operation.initialize(to: OVERLAPPED())
        guard NativeSearchFiles.validFolder(root), NativeSearchLibraryScanner.permitted(root) else {
            throw WindowsError.unsupported("A search watcher root is not a safe local folder.")
        }
        let type = withWideString(String(root.prefix(3))) { GetDriveTypeW($0) }
        guard type == UINT(DRIVE_FIXED) || type == UINT(DRIVE_REMOVABLE) else {
            throw WindowsError.unsupported("Search change notifications require a local drive.")
        }
        directory = withWideString(try NativeFiles.windowsPath(root)) {
            CreateFileW($0, DWORD(FILE_LIST_DIRECTORY),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED |
                    FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let directory, directory != INVALID_HANDLE_VALUE else {
            self.directory = nil
            throw WindowsError.api("Open local search change notifications", GetLastError())
        }
        event = CreateEventW(nil, true, false, nil)
        guard let event else { throw WindowsError.api("Create search change event", GetLastError()) }
        operation.pointee.hEvent = event
        try start()
    }
    deinit { _ = stop() }
    private func start() throws {
        guard let directory, let event, !stopped else { return }
        _ = ResetEvent(event)
        operation.pointee = OVERLAPPED()
        operation.pointee.hEvent = event
        let filters = DWORD(FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
            FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_ATTRIBUTES)
        let result = ReadDirectoryChangesW(directory, bytes, 32768, true, filters, nil, operation, nil)
        guard result || GetLastError() == DWORD(ERROR_IO_PENDING) else {
            throw WindowsError.api("Start local search change notifications", GetLastError())
        }
        pending = true
    }
    func poll() throws -> [String]? {
        guard let directory, let event, pending, !stopped,
            WaitForSingleObject(event, 0) == DWORD(WAIT_OBJECT_0) else { return [] }
        var count: DWORD = 0
        let completed = GetOverlappedResult(directory, operation, &count, false)
        let error = completed ? 0 : GetLastError()
        if !completed, error == DWORD(ERROR_IO_INCOMPLETE) { return [] }
        pending = false
        if !completed { try start(); return nil }
        guard count >= 12, count <= 32768 else { try start(); return nil }
        var names: [String] = [], offset = 0
        let length = Int(count)
        var valid = true
        while offset <= length - 12 {
            let next = Int(bytes.loadUnaligned(fromByteOffset: offset, as: DWORD.self))
            let nameBytes = Int(bytes.loadUnaligned(fromByteOffset: offset + 8, as: DWORD.self))
            guard nameBytes > 0, nameBytes % 2 == 0, nameBytes <= length - offset - 12 else {
                valid = false
                break
            }
            let words = bytes.advanced(by: offset + 12).assumingMemoryBound(to: WCHAR.self)
            guard let name = String(validating: UnsafeBufferPointer(start: words, count: nameBytes / 2),
                as: UTF16.self), !name.utf16.contains(0) else { valid = false; break }
            names.append(name)
            if next == 0 { break }
            guard next >= 12 + nameBytes, next % 4 == 0, next <= length - offset - 12 else {
                valid = false
                break
            }
            offset += next
        }
        try start()
        return valid ? names : nil
    }
    @discardableResult func stop() -> Bool {
        guard !stopped else { return finishStopped() }
        stopped = true
        var drained = true
        if pending, let directory, let event {
            _ = CancelIoEx(directory, operation)
            _ = WaitForSingleObject(event, 500)
            var ignored: DWORD = 0
            let result = GetOverlappedResult(directory, operation, &ignored, false)
            drained = result || GetLastError() != DWORD(ERROR_IO_INCOMPLETE)
        }
        if let directory { _ = CloseHandle(directory); self.directory = nil }
        drainedOnStop = drained
        if drained {
            releaseStorage()
        }
        // The supervisor retains an undrained watcher and polls completion before freeing I/O storage.
        return drained
    }
    func finishStopped() -> Bool {
        guard stopped else { return false }
        if drainedOnStop { return true }
        guard let event, WaitForSingleObject(event, 0) == DWORD(WAIT_OBJECT_0) else { return false }
        // This private event is signalled only by the completed async operation, after cancellation.
        drainedOnStop = true
        releaseStorage()
        return true
    }
    private func releaseStorage() {
        guard !released else { return }
        released = true
        if let event { _ = CloseHandle(event); self.event = nil }
        operation.deinitialize(count: 1)
        operation.deallocate()
        bytes.deallocate()
    }
}

/// Metadata-only asynchronous notifications, polled by the existing low-priority worker step.
final class NativeSearchLibraryWatcher {
    private var watches: [NativeSearchLibraryWatch] = []
    private let excludedPaths: [String]
    private var deferredRoots = Set<String>()
    private var stopped = false
    private(set) var overflowCount = 0
    private(set) var unavailableRoots = 0
    init(roots: [String], excludedPaths: [String] = []) throws {
        guard roots.count <= 128, excludedPaths.count <= 128,
            roots.allSatisfy({ NativeSearchLibraryScanner.canonical($0) != nil }),
            excludedPaths.allSatisfy({ NativeSearchLibraryScanner.canonical($0) != nil }) else {
            throw WindowsError.unsupported("Invalid local search change-notification locations.")
        }
        self.excludedPaths = excludedPaths.compactMap(NativeSearchLibraryScanner.canonical)
        for root in Set(roots.compactMap(NativeSearchLibraryScanner.canonical)).sorted() {
            guard NativeSearchLibraryScanner.permitted(root, excludedPaths: self.excludedPaths) else { continue }
            do { watches.append(try NativeSearchLibraryWatch(root: root)) }
            catch { unavailableRoots += 1 }
        }
    }
    deinit { _ = stop() }
    func pollChangedDirectories(maximum: Int = 128) -> [String] {
        guard !stopped else { return [] }
        var changed = Set<String>()
        let limit = max(1, min(128, maximum))
        for root in deferredRoots.sorted().prefix(limit) {
            changed.insert(root)
            deferredRoots.remove(root)
        }
        func rescan(_ root: String) {
            if changed.count < limit { changed.insert(root) }
            else { deferredRoots.insert(root) }
        }
        for watch in watches {
            do {
                guard let names = try watch.poll() else {
                    overflowCount += 1
                    rescan(watch.root)
                    continue
                }
                for name in names {
                    let path = watch.root + (watch.root.hasSuffix("\\") ? "" : "\\") + name
                    guard NativeSearchLibraryScanner.permitted(path, excludedPaths: excludedPaths),
                        let separator = path.lastIndex(of: "\\"),
                        let parent = NativeSearchLibraryScanner.canonical(String(path[...separator])) else { continue }
                    if changed.count == limit && !changed.contains(parent) {
                        deferredRoots.insert(watch.root)
                        overflowCount += 1
                        break
                    }
                    changed.insert(parent)
                }
            } catch {
                unavailableRoots += 1
                rescan(watch.root)
                _ = watch.stop()
            }
        }
        return Array(changed.sorted().prefix(limit))
    }
    @discardableResult func stop() -> Bool {
        stopped = true
        watches = watches.filter { !$0.stop() }
        return watches.isEmpty
    }
    func finishStopped() -> Bool {
        guard stopped else { return false }
        watches.removeAll(where: { $0.finishStopped() })
        return watches.isEmpty
    }
}
