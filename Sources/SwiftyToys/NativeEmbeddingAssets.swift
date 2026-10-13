// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import EmbeddingABI

struct NativeEmbeddingProgress: Sendable { let stage: String; let completed: UInt64; let total: UInt64 }
struct NativeEmbeddingDocument: Sendable { let id: String; let title: String; let text: String }
struct NativeEmbeddingMatch: Sendable { let id: String; let score: Float }

struct NativeEmbeddingAsset: Sendable {
    let name: String
    let host: String
    let remotePath: String
    let bytes: UInt64
    let sha256: String
}

/// A held regular file keeps pinned bytes unchanged through model loading and inference.
final class NativeEmbeddingFile {
    private var owner: OwnedHandle?
    var raw: HANDLE {
        guard let handle = owner?.raw else { preconditionFailure("A closed embedding file has no handle") }
        return handle
    }
    func close() { owner = nil }
    init(_ path: String, asset: NativeEmbeddingAsset) throws {
        owner = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN), nil)
        })
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(raw, &info), info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0,
            UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow) == asset.bytes else {
            throw WindowsError.unsupported("The local search component is incomplete or unsafe. Remove the model and download it again.")
        }
        let digest = try NativeDriverTrust.sha256 { buffer in
            var received: DWORD = 0
            guard ReadFile(raw, buffer.baseAddress, DWORD(buffer.count), &received, nil) else { throw WindowsError.api("Read local search component", GetLastError()) }
            return Int(received)
        }
        guard NativeDriverTrust.hashMatches(digest, expected: asset.sha256) else { throw WindowsError.unsupported("The local search component does not match its verified version. Remove the model and download it again.") }
        guard SetFilePointerEx(raw, LARGE_INTEGER(), nil, DWORD(FILE_BEGIN)) else { throw WindowsError.api("Rewind verified search component", GetLastError()) }
    }
}

enum NativeEmbeddingAssets {
    enum State: Sendable { case unsupported, missing, downloaded }
    private static let modelRoute = "/onnx-community/embeddinggemma-2-ONNX/resolve/daa72c51243991dfcaf9f9137d2c573d8f7790c0/"
    static let tokenizer = NativeEmbeddingAsset(name: "tokenizer.json", host: "huggingface.co", remotePath: modelRoute + "tokenizer.json", bytes: 32170510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4")
    static let graph = NativeEmbeddingAsset(name: "model_quantized.onnx", host: "huggingface.co", remotePath: modelRoute + "onnx/model_quantized.onnx", bytes: 495165, sha256: "d06edd601f851c633a2519304cbeb8dc6170d7ceb61b436625c17fb9b6e74953")
    static let weights = NativeEmbeddingAsset(name: "model_quantized.onnx_data", host: "huggingface.co", remotePath: modelRoute + "onnx/model_quantized.onnx_data", bytes: 313724928, sha256: "278a7ff1248c3618e4bd11a607fc54f7bdc7778854230f3956d3f86bd9db4f3b")
    static let runtime = NativeEmbeddingAsset(name: "onnxruntime.dll", host: "", remotePath: "", bytes: 23086440, sha256: "6c916621c1807eba630388868bff8eb4cc9718b9fa17464fc9368eb14ad0f33e")
    static let package = NativeEmbeddingAsset(name: "winml.zip", host: "api.nuget.org", remotePath: "/v3-flatcontainer/microsoft.windows.ai.machinelearning/2.4.89/microsoft.windows.ai.machinelearning.2.4.89.nupkg", bytes: 51594185, sha256: "5c68ecfb947223267abf159a023f5192ad42725e4e9cc995e7c1470dd54dff63")
    static var downloadBytes: UInt64 { tokenizer.bytes + graph.bytes + weights.bytes + package.bytes }
    static var files: [NativeEmbeddingAsset] { [runtime, tokenizer, graph, weights] }
    static func directory() throws -> String { try NativeFiles.path("EmbeddingGemma2") }
    static func path(_ asset: NativeEmbeddingAsset) throws -> String { try directory() + "\\" + asset.name }
    static func cancelled(_ callback: @Sendable () -> Bool) throws {
        if callback() { throw WindowsError.api("Local search operation cancelled", DWORD(ERROR_CANCELLED)) }
    }
    static func supported() -> Bool {
        guard let ntdll = withWideString("ntdll.dll", { GetModuleHandleW($0) }), let address = "RtlGetVersion".withCString({ GetProcAddress(ntdll, $0) }) else { return false }
        typealias Version = @convention(c) (UnsafeMutablePointer<OSVERSIONINFOW>?) -> NTSTATUS
        var version = OSVERSIONINFOW(); version.dwOSVersionInfoSize = DWORD(MemoryLayout<OSVERSIONINFOW>.size)
        return unsafeBitCast(address, to: Version.self)(&version) >= 0 && version.dwMajorVersion >= 10 && version.dwBuildNumber >= 18362
    }
    /// Downloaded is a presence/length state. Ready requires a validated worker and real inference.
    static func status() throws -> State {
        guard supported() else { return .unsupported }
        let directory = try directory()
        guard try NativeFiles.exists(directory) else { return .missing }
        try inspect(directory, directory: true)
        for asset in files {
            let path = directory + "\\" + asset.name
            guard try NativeFiles.exists(path) else { return .missing }
            let handle = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) { CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil) })
            var info = BY_HANDLE_FILE_INFORMATION()
            guard GetFileInformationByHandle(handle.raw, &info), info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0,
                UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow) == asset.bytes else { return .missing }
        }
        return .downloaded
    }
    static func inspect(_ path: String, directory: Bool) throws {
        let flags = DWORD(FILE_FLAG_OPEN_REPARSE_POINT) | (directory ? DWORD(FILE_FLAG_BACKUP_SEMANTICS) : 0)
        let file = try OwnedHandle(withWideString(try NativeFiles.windowsPath(path)) { CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), flags, nil) })
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(file.raw, &info), info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
            (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0) == directory else { throw WindowsError.unsupported("The local search storage contains an unsafe path.") }
    }
    static func identity() throws -> String {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token) else { throw WindowsError.api("Read search user", GetLastError()) }
        let owned = try OwnedHandle(token)
        var count: DWORD = 0
        _ = GetTokenInformation(owned.raw, TokenUser, nil, 0, &count)
        guard count >= MemoryLayout<TOKEN_USER>.size, count <= 65536 else { throw WindowsError.unsupported("Invalid search user token.") }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(count), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { data.deallocate() }
        guard GetTokenInformation(owned.raw, TokenUser, data, count, &count) else { throw WindowsError.api("Read search user identity", GetLastError()) }
        var text: PWSTR?
        guard ConvertSidToStringSidW(data.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid, &text), let text else { throw WindowsError.api("Encode search user identity", GetLastError()) }
        defer { LocalFree(text) }
        var length = 0
        while length < 256 && text[length] != 0 { length += 1 }
        guard length < 256 else { throw WindowsError.unsupported("Invalid search user identity.") }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }
    static func descriptor() throws -> PSECURITY_DESCRIPTOR {
        let sid = try identity()
        var result: PSECURITY_DESCRIPTOR?
        guard withWideString("O:" + sid + "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + sid + ")", { ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &result, nil) }), let result else { throw WindowsError.api("Protect local search storage", GetLastError()) }
        return result
    }
    static func privateDirectory(_ path: String) throws {
        let descriptor = try descriptor(); defer { LocalFree(descriptor) }
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
        guard withWideString(try NativeFiles.windowsPath(path), { CreateDirectoryW($0, &attributes) }) else {
            if GetLastError() != DWORD(ERROR_ALREADY_EXISTS) { throw WindowsError.api("Create local search storage", GetLastError()) }
            try inspect(path, directory: true)
            return
        }
    }
    static func guid() throws -> String {
        var value = GUID(), text = [WCHAR](repeating: 0, count: 40)
        guard CoCreateGuid(&value) >= 0, StringFromGUID2(&value, &text, Int32(text.count)) == 39 else { throw WindowsError.unsupported("Create local search operation identity.") }
        return String(decoding: text.prefix(38), as: UTF16.self).filter { $0 != "{" && $0 != "}" && $0 != "-" }
    }
    static func download(progress: @Sendable (NativeEmbeddingProgress) -> Void, cancelled: @Sendable () -> Bool) throws {
        guard supported() else { throw WindowsError.unsupported("Local semantic search requires Windows10 version1903 or newer.") }
        try Self.cancelled(cancelled)
        let root = try directory(), app = try NativeFiles.directory()
        try NativeFiles.createDirectory(app); try inspect(app, directory: true); try privateDirectory(root)
        let operation = try OwnedHandle(withWideString("Local\\SwiftyToys.EmbeddingDownload-" + (try identity())) { CreateMutexW(nil, false, $0) })
        let ownership = WaitForSingleObject(operation.raw, 0)
        guard ownership == DWORD(WAIT_OBJECT_0) || ownership == 0x80 else { throw WindowsError.unsupported("A local model download or removal is already running.") }
        defer { ReleaseMutex(operation.raw) }
        let stage = root + "\\stage-" + (try guid())
        try privateDirectory(stage)
        defer { cleanupStage(stage) }
        var completed: UInt64 = 0
        let total = downloadBytes
        for asset in [tokenizer, graph, weights] {
            try Self.cancelled(cancelled)
            let destination = root + "\\" + asset.name
            if try NativeFiles.exists(destination) {
                _ = try NativeEmbeddingFile(destination, asset: asset)
                completed += asset.bytes; progress(.init(stage: "Verified " + asset.name, completed: completed, total: total)); continue
            }
            let temporary = stage + "\\" + asset.name
            try fetch(asset, destination: temporary, completed: completed, total: total, progress: progress, cancelled: cancelled)
            try Self.cancelled(cancelled)
            _ = try NativeEmbeddingFile(temporary, asset: asset)
            try commit(temporary, to: destination)
            completed += asset.bytes
        }
        let runtimePath = root + "\\" + runtime.name
        if try NativeFiles.exists(runtimePath) {
            let locked = try NativeEmbeddingFile(runtimePath, asset: runtime)
            try NativeDriverTrust.verifySignature(runtimePath, signer: .microsoftWindows, fileHandle: locked.raw)
        } else {
            let archive = stage + "\\" + package.name
            try fetch(package, destination: archive, completed: completed, total: total, progress: progress, cancelled: cancelled)
            let archiveLock = try NativeEmbeddingFile(archive, asset: package)
            progress(.init(stage: "Preparing signed Microsoft search component", completed: total, total: total))
            let process = try NativeEmbeddingProcess(executable: systemExecutable("tar.exe"), arguments: ["-xf", archive, "-C", stage, "runtimes/win-x64/native/onnxruntime.dll"], memoryMiB: 256)
            try process.wait(milliseconds: 30000, cancelled: cancelled)
            let extracted = stage + "\\runtimes\\win-x64\\native\\onnxruntime.dll"
            for component in ["runtimes", "runtimes\\win-x64", "runtimes\\win-x64\\native"] { try inspect(stage + "\\" + component, directory: true) }
            let locked = try NativeEmbeddingFile(extracted, asset: runtime)
            try NativeDriverTrust.verifySignature(extracted, signer: .microsoftWindows, fileHandle: locked.raw)
            try Self.cancelled(cancelled)
            withExtendedLifetime((archiveLock, locked)) {}
            locked.close()
            archiveLock.close()
            // Release the verified read handle before committing; the new locked worker revalidates bytes before loading.
            try commit(extracted, to: runtimePath)
        }
        try Self.cancelled(cancelled)
        progress(.init(stage: "Downloaded. The local worker will validate inference when search starts.", completed: total, total: total))
    }
    private static func commit(_ source: String, to destination: String) throws {
        guard try withWideString(NativeFiles.windowsPath(source), { source in try withWideString(NativeFiles.windowsPath(destination)) { MoveFileExW(source, $0, DWORD(MOVEFILE_WRITE_THROUGH)) } }) else { throw WindowsError.api("Commit verified search component", GetLastError()) }
    }
    private static func fetch(_ asset: NativeEmbeddingAsset, destination: String, completed: UInt64, total: UInt64, progress: @Sendable (NativeEmbeddingProgress) -> Void, cancelled: @Sendable () -> Bool) throws {
        guard let session = withWideString("SwiftyToys local search model", { WinHttpOpen($0, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) }) else { throw WindowsError.api("Open model download", GetLastError()) }
        defer { WinHttpCloseHandle(session) }
        guard WinHttpSetTimeouts(session, 10000, 10000, 30000, 10000) else { throw WindowsError.api("Set model download timeouts", GetLastError()) }
        var protocols = DWORD(WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2)
        guard WinHttpSetOption(session, DWORD(WINHTTP_OPTION_SECURE_PROTOCOLS), &protocols, 4) else { throw WindowsError.api("Secure model download", GetLastError()) }
        guard let connection = withWideString(asset.host, { WinHttpConnect(session, $0, INTERNET_PORT(443), 0) }) else { throw WindowsError.api("Connect model download", GetLastError()) }
        defer { WinHttpCloseHandle(connection) }
        guard let request = withWideString(asset.remotePath, { WinHttpOpenRequest(connection, nil, $0, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) }) else { throw WindowsError.api("Open model download request", GetLastError()) }
        defer { WinHttpCloseHandle(request) }
        var policy = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP)
        guard WinHttpSetOption(request, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &policy, 4) else { throw WindowsError.api("Secure model redirects", GetLastError()) }
        try Self.cancelled(cancelled)
        guard WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0), WinHttpReceiveResponse(request, nil) else { throw WindowsError.api("Receive model download", GetLastError()) }
        var code: DWORD = 0, count: DWORD = 4
        guard WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &code, &count, nil), code == 200 else { throw WindowsError.unsupported("The model download is unavailable. Check your connection and retry.") }
        let file = try OwnedHandle(withWideString(try NativeFiles.windowsPath(destination)) { CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil) })
        var buffer = [UInt8](repeating: 0, count: 65536), received: UInt64 = 0, reported: UInt64 = 0
        let began = GetTickCount64()
        while true {
            try Self.cancelled(cancelled)
            guard GetTickCount64() - began < 600000 else { throw WindowsError.unsupported("The model download timed out. Check your connection and retry.") }
            var read: DWORD = 0, written: DWORD = 0
            guard WinHttpReadData(request, &buffer, DWORD(buffer.count), &read) else { throw WindowsError.api("Read model download", GetLastError()) }
            if read == 0 { break }
            guard read <= buffer.count, UInt64(read) <= asset.bytes - received else { throw WindowsError.unsupported("The model download exceeds its verified size.") }
            guard WriteFile(file.raw, buffer, read, &written, nil), written == read else { throw WindowsError.api("Save model download", GetLastError()) }
            received += UInt64(read)
            if received - reported >= 1_048_576 { progress(.init(stage: "Downloading local search components", completed: completed + received, total: total)); reported = received }
        }
        guard received == asset.bytes, FlushFileBuffers(file.raw) else { throw WindowsError.unsupported("The model download did not complete.") }
    }
    private static func cleanupStage(_ stage: String) {
        guard (try? inspect(stage, directory: true)) != nil else { return }
        for name in [tokenizer.name, graph.name, weights.name, package.name] {
            try? NativeFiles.remove(stage + "\\" + name)
        }
        let components = ["runtimes", "runtimes\\win-x64", "runtimes\\win-x64\\native"]
        if components.allSatisfy({ (try? inspect(stage + "\\" + $0, directory: true)) != nil }) {
            try? NativeFiles.remove(stage + "\\runtimes\\win-x64\\native\\onnxruntime.dll")
        }
        for name in ["runtimes\\win-x64\\native", "runtimes\\win-x64", "runtimes", ""] {
            let path = name.isEmpty ? stage : stage + "\\" + name
            if (try? inspect(path, directory: true)) != nil { try? withWideString(NativeFiles.windowsPath(path)) { _ = RemoveDirectoryW($0) } }
        }
    }
    static func remove() throws {
        NativeEmbedding.closeForRemoval()
        let root = try directory()
        guard try NativeFiles.exists(root) else { return }
        try inspect(root, directory: true)
        let operation = try OwnedHandle(withWideString("Local\\SwiftyToys.EmbeddingDownload-" + (try identity())) { CreateMutexW(nil, false, $0) })
        let ownership = WaitForSingleObject(operation.raw, 0)
        guard ownership == DWORD(WAIT_OBJECT_0) || ownership == 0x80 else { throw WindowsError.unsupported("Cancel the active model download before removing it.") }
        defer { ReleaseMutex(operation.raw) }
        for asset in files { if try NativeFiles.exists(root + "\\" + asset.name) { try inspect(root + "\\" + asset.name, directory: false); try NativeFiles.remove(root + "\\" + asset.name) } }
        _ = try withWideString(NativeFiles.windowsPath(root)) { RemoveDirectoryW($0) }
    }
}
