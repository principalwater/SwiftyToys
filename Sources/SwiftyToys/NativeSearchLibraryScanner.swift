// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

/// Restart-safe directory queue; an open enumeration is retained only between bounded slices.
final class NativeSearchLibraryScanner {
    private let store: NativeSearchLibraryStore
    private var roots: [String]
    private var excludedPaths: [String]
    private var volumes: [String: DWORD] = [:]
    private var current: (path: String, generation: String, handle: HANDLE)?
    private var entry = WIN32_FIND_DATAW()
    private(set) var finished = false
    private static let excludedDirectories: Set<String> = [
        "windows", "program files", "program files (x86)", "programdata", "appdata",
        "$recycle.bin", "system volume information", "recovery", "config.msi", "msocache",
        ".git", ".svn", ".hg", ".build", ".swiftpm", "node_modules", "target",
        "deriveddata", "build", "dist", "bin", "obj", "packages", ".venv", "venv",
        "__pycache__", ".cache", "cache", "caches", ".npm", ".nuget", ".cargo",
        ".agent-private", "agent-rules", ".ssh", ".gnupg", ".aws", ".azure", ".kube",
        ".codex", ".claude", ".config", ".local", "credentials", "secrets"
    ]
    private static let excludedFiles: Set<String> = [
        "agents.md", "claude.md", ".env", "credentials", "credentials.json", "secrets.json",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "authorized_keys", "known_hosts",
        "ntuser.dat", "usrclass.dat", "pagefile.sys", "hiberfil.sys", "swapfile.sys"
    ]

    init(store: NativeSearchLibraryStore, roots: [String]? = nil,
        excludedPaths: [String] = [], resume: Bool = false) throws {
        self.store = store
        self.roots = []
        self.excludedPaths = []
        try beginRefresh(roots: roots, excludedPaths: excludedPaths, resume: resume)
    }
    deinit { if let current { _ = FindClose(current.handle) } }
    static func localDrives() -> [String] {
        let drives = GetLogicalDrives()
        return (0..<26).compactMap { index in
            guard drives & DWORD(1 << index) != 0 else { return nil }
            let root = String(UnicodeScalar(65 + index)!) + ":\\"
            let kind = withWideString(root) { GetDriveTypeW($0) }
            return kind == UINT(DRIVE_FIXED) || kind == UINT(DRIVE_REMOVABLE) ? root : nil
        }
    }
    static func defaultRoots() -> [String] { localDrives() }
    static func metadata(path: String) throws -> (size: Int64, modified: String) {
        guard Self.canonical(path) != nil, Self.permitted(path),
            let separator = path.lastIndex(of: "\\"),
            NativeSearchFiles.validFolder(String(path[...separator])) else {
            throw WindowsError.unsupported("The indexed file is outside a safe local folder.")
        }
        let handle = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) {
            CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        })
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle.raw, &info),
            info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY |
                FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM) == 0,
            info.dwFileAttributes & DWORD(0x00400000 | 0x00040000) == 0 else {
            throw WindowsError.unsupported("The indexed file is linked, offline or unavailable.")
        }
        let size = (UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow)
        guard size <= UInt64(Int64.max) else { throw WindowsError.unsupported("The indexed file is too large.") }
        let modified = (UInt64(info.ftLastWriteTime.dwHighDateTime) << 32) |
            UInt64(info.ftLastWriteTime.dwLowDateTime)
        return (Int64(size), fingerprint(volume: info.dwVolumeSerialNumber, modified: modified))
    }
    private static func fingerprint(volume: DWORD, modified: UInt64) -> String {
        "\(volume):\(modified)"
    }
    /// Validation is lexical here; traversal separately verifies every native parent component.
    static func canonical(_ path: String) -> String? {
        let bytes = Array(path.utf8.prefix(3))
        guard bytes.count == 3, ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
            bytes[1] == 58, bytes[2] == 92, path.utf16.count < 32760,
            !path.utf16.contains(0), !path.dropFirst(2).contains(":"), !path.contains("/") else {
            return nil
        }
        let parts = path.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == "." || $0 == ".." || $0.hasSuffix(" ") ||
            $0.hasSuffix(".") || $0.contains("*") || $0.contains("?") }) else { return nil }
        var normalized = path.lowercased()
        while normalized.count > 3 && normalized.hasSuffix("\\") { normalized.removeLast() }
        return normalized
    }
    static func permitted(_ path: String, excludedPaths: [String] = []) -> Bool {
        guard let value = canonical(path) else { return false }
        let parts = value.dropFirst(3).split(separator: "\\")
        guard !parts.contains(where: { excludedDirectories.contains(String($0)) }) else { return false }
        let name = String(parts.last ?? "")
        if excludedFiles.contains(name) || name.hasPrefix(".env.") || name.hasSuffix(".pem") ||
            name.hasSuffix(".key") || name.hasSuffix(".pfx") || name.hasSuffix(".p12") ||
            name.hasSuffix(".kdbx") || name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") ||
            name.hasSuffix(".db") { return false }
        return !excludedPaths.contains(where: { value == $0 || value.hasPrefix($0 + "\\") })
    }
    private func inScope(_ path: String) -> Bool {
        guard let value = Self.canonical(path), Self.permitted(path, excludedPaths: excludedPaths)
        else { return false }
        return roots.contains { root in
            value == root || value.hasPrefix(root.hasSuffix("\\") ? root : root + "\\")
        }
    }
    func enqueueDirectory(_ path: String) throws {
        guard inScope(path) else { return }
        try store.queueDirectory(path)
        finished = false
    }
    func beginRefresh(roots: [String]? = nil, excludedPaths: [String] = [], resume: Bool = false) throws {
        if let current { _ = FindClose(current.handle); self.current = nil }
        let requested = roots ?? Self.localDrives()
        guard requested.count <= 128, excludedPaths.count <= 128,
            requested.allSatisfy({ path in
                guard Self.canonical(path) != nil, Self.permitted(path) else { return false }
                let type = withWideString(String(path.prefix(3))) { GetDriveTypeW($0) }
                return type == UINT(DRIVE_FIXED) || type == UINT(DRIVE_REMOVABLE)
            }),
            excludedPaths.allSatisfy({ Self.canonical($0) != nil }) else {
            throw WindowsError.unsupported("Search locations must be local absolute paths outside excluded directories.")
        }
        self.roots = Array(Set(requested.compactMap(Self.canonical))).sorted()
        self.excludedPaths = excludedPaths.compactMap(Self.canonical)
        volumes.removeAll(keepingCapacity: true)
        for root in self.roots {
            let drive = String(root.prefix(3))
            var serial: DWORD = 0
            if withWideString(drive, { GetVolumeInformationW($0, nil, 0, &serial, nil, nil, nil, 0) }) {
                volumes[drive] = serial
            }
        }
        // Removed/remapped/offline drives remain indexed until explicitly excluded or re-enumerated.
        let configuredRoots = self.roots
        if !resume {
        try store.pruneScope { path in
            guard let value = Self.canonical(path), Self.permitted(path, excludedPaths: self.excludedPaths)
            else { return false }
            if roots == nil { return true }
            return configuredRoots.contains { value == $0 || value.hasPrefix($0.hasSuffix("\\") ? $0 : $0 + "\\") }
        }
        }
        try store.trackRoots(self.roots.map { (path: $0, volume: String(volumes[String($0.prefix(3))] ?? 0)) },
            refresh: !resume)
        finished = try store.nextDirectory() == nil
    }
    func scanSlice(maximumEntries: Int = 128, milliseconds: UInt64 = 40,
        cancelled: () -> Bool) throws -> Int {
        guard !finished, !(try store.paused) else { return 0 }
        var count = 0
        do {
            try store.transaction {
                count = try scanEntries(maximumEntries: maximumEntries, milliseconds: milliseconds,
                    cancelled: cancelled)
            }
        } catch {
            // A rolled-back slice must restart enumeration, or its unseen entries could be pruned.
            if let current { _ = FindClose(current.handle); self.current = nil }
            finished = false
            throw error
        }
        return count
    }
    private func scanEntries(maximumEntries: Int, milliseconds: UInt64,
        cancelled: () -> Bool) throws -> Int {
        let deadline = GetTickCount64() + min(milliseconds, 250)
        var visited = 0
        while visited < max(1, min(512, maximumEntries)), GetTickCount64() < deadline {
            if cancelled() {
                if let current { _ = FindClose(current.handle); self.current = nil }
                return visited
            }
            if current == nil {
                guard let path = try store.nextDirectory() else { finished = true; return visited }
                visited += 1
                guard inScope(path) else { try store.abandonDirectory(path); continue }
                guard NativeSearchFiles.validFolder(path) else {
                    let attributes = withWideString(path) { GetFileAttributesW($0) }
                    let error = GetLastError()
                    if attributes == DWORD(INVALID_FILE_ATTRIBUTES),
                        error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND),
                        let separator = path.lastIndex(of: "\\"), separator > path.startIndex,
                        NativeSearchFiles.validFolder(String(path[...separator])) {
                        try store.pruneMissingDirectory(path)
                    } else { try store.abandonDirectory(path) }
                    continue
                }
                guard let native = try? NativeFiles.windowsPath(path + (path.hasSuffix("\\") ? "*" : "\\*"))
                else { try store.abandonDirectory(path); continue }
                let attributes = withWideString(try NativeFiles.windowsPath(path)) { GetFileAttributesW($0) }
                let unavailable = DWORD(FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_REPARSE_POINT |
                    FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_HIDDEN) | DWORD(0x00400000 | 0x00040000)
                guard attributes != DWORD(INVALID_FILE_ATTRIBUTES), attributes & unavailable == 0 else {
                    try store.abandonDirectory(path)
                    continue
                }
                let generation = try store.nextGeneration()
                guard let handle = withWideString(native, { FindFirstFileW($0, &entry) }),
                    handle != INVALID_HANDLE_VALUE else {
                    let error = GetLastError()
                    if error == DWORD(ERROR_FILE_NOT_FOUND) {
                        try store.finishDirectory(path, generation: generation)
                    } else { try store.abandonDirectory(path) }
                    continue
                }
                current = (path, generation, handle)
            }
            guard let current else { continue }
            visited += 1
            let name = withUnsafePointer(to: &entry.cFileName) {
                $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: Int(MAX_PATH))
                        .prefix(while: { $0 != 0 }), as: UTF16.self)
                }
            }
            let attributes = entry.dwFileAttributes
            let path = current.path + (current.path.hasSuffix("\\") ? "" : "\\") + name
            let blocked = DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_SYSTEM |
                FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_TEMPORARY) |
                DWORD(0x00400000 | 0x00040000) // Cloud placeholders must not trigger recall/download.
            if name != ".", name != "..", attributes & blocked == 0, inScope(path) {
                if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                    try store.queueDirectory(path, parent: current.path, generation: current.generation)
                } else {
                    let size = (UInt64(entry.nFileSizeHigh) << 32) | UInt64(entry.nFileSizeLow)
                    if size <= UInt64(Int64.max) {
                        let modified = (UInt64(entry.ftLastWriteTime.dwHighDateTime) << 32) |
                            UInt64(entry.ftLastWriteTime.dwLowDateTime)
                        try store.observe(path: path, parent: current.path, size: Int64(size),
                            modified: Self.fingerprint(volume: volumes[String(path.prefix(3))] ?? 0,
                                modified: modified),
                            generation: current.generation)
                    }
                }
            }
            if !FindNextFileW(current.handle, &entry) {
                let error = GetLastError()
                _ = FindClose(current.handle)
                self.current = nil
                if error == DWORD(ERROR_NO_MORE_FILES) {
                    try store.finishDirectory(current.path, generation: current.generation)
                } else { try store.abandonDirectory(current.path) }
            }
        }
        return visited
    }
}
