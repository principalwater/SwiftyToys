// SPDX-License-Identifier: MIT
import WinSDK
import SetupABI

// Standard Swift deliberately uses only scalars, pointers and Win32-owned storage here.
private let maximumBundleBytes = 64 * 1024 * 1024
private let pathCapacity = 32768

private func allocate(_ bytes: Int, zero: Bool = false) -> UnsafeMutableRawPointer? {
    if bytes <= 0 || bytes > maximumBundleBytes { return nil }
    return HeapAlloc(GetProcessHeap(), zero ? DWORD(HEAP_ZERO_MEMORY) : 0, SIZE_T(bytes))
}
private func release(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { HeapFree(GetProcessHeap(), 0, pointer) }
}
private func wide(_ text: StaticString) -> UnsafeMutablePointer<WCHAR>? {
    let count = text.utf8CodeUnitCount
    if count > 4096 { return nil }
    let bytes = UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self)
    let length = MultiByteToWideChar(UINT(CP_UTF8), DWORD(MB_ERR_INVALID_CHARS), bytes, Int32(count), nil, 0)
    if length == 0 { return nil }
    guard let storage = allocate((Int(length) + 1) * 2, zero: true) else { return nil }
    let result = storage.assumingMemoryBound(to: WCHAR.self)
    if MultiByteToWideChar(UINT(CP_UTF8), DWORD(MB_ERR_INVALID_CHARS), bytes, Int32(count), result, length) != length {
        release(storage)
        return nil
    }
    return result
}
private func same(_ bytes: UnsafePointer<UInt8>, _ text: StaticString) -> Bool {
    var index = 0
    while index < text.utf8CodeUnitCount {
        if bytes[index] != text.utf8Start[index] { return false }
        index += 1
    }
    return true
}
private func unsigned(_ bytes: UnsafePointer<UInt8>, _ offset: Int, _ width: Int) -> UInt64 {
    var value: UInt64 = 0
    var index = 0
    while index < width {
        value |= UInt64(bytes[offset + index]) << (index * 8)
        index += 1
    }
    return value
}
private func hashMatches(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, digest: UnsafePointer<UInt8>) -> Bool {
    guard let name = wide("SHA256") else { return false }
    defer { release(name) }
    var algorithm: BCRYPT_ALG_HANDLE?
    if BCryptOpenAlgorithmProvider(&algorithm, name, nil, 0) < 0 { return false }
    defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
    var hash: BCRYPT_HASH_HANDLE?
    if BCryptCreateHash(algorithm, &hash, nil, 0, nil, 0, 0) < 0 { return false }
    defer { BCryptDestroyHash(hash) }
    if BCryptHashData(hash, bytes, UInt32(count), 0) < 0 { return false }
    guard let output = allocate(32) else { return false }
    defer { release(output) }
    let result = output.assumingMemoryBound(to: UInt8.self)
    if BCryptFinishHash(hash, result, 32, 0) < 0 { return false }
    var difference: UInt8 = 0
    var index = 0
    while index < 32 {
        difference |= result[index] ^ digest[index]
        index += 1
    }
    return difference == 0
}

private func reservedComponent(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
    var stemLength = 0
    while stemLength < count && bytes[stemLength] != 46 { stemLength += 1 }
    if stemLength != 3 && stemLength != 4 { return false }
    let a = bytes[0] & 0xdf
    let b = bytes[1] & 0xdf
    let c = bytes[2] & 0xdf
    if stemLength == 3 {
        return (a == 67 && b == 79 && c == 78) || (a == 80 && b == 82 && c == 78)
            || (a == 65 && b == 85 && c == 88) || (a == 78 && b == 85 && c == 76)
    }
    return ((a == 67 && b == 79 && c == 77) || (a == 76 && b == 80 && c == 84))
        && bytes[3] >= 49 && bytes[3] <= 57
}
private func validPath(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
    if count == 0 || count > 1024 { return false }
    var start = 0
    var index = 0
    while index <= count {
        if index == count || bytes[index] == 47 {
            let length = index - start
            if length == 0 || length > 255 || bytes[start] == 46 || bytes[index - 1] == 46
                || reservedComponent(bytes.advanced(by: start), count: length) { return false }
            start = index + 1
        } else {
            let character = bytes[index]
            if !((character >= 65 && character <= 90) || (character >= 97 && character <= 122)
                || (character >= 48 && character <= 57) || character == 45 || character == 46 || character == 95) { return false }
        }
        index += 1
    }
    return true
}

private struct Record {
    var path: UnsafePointer<UInt8>
    var pathCount: Int
    var data: UnsafePointer<UInt8>
    var dataCount: Int
    var next: Int
}
private func record(_ bytes: UnsafePointer<UInt8>, size: Int, offset: Int) -> Record? {
    if offset < 12 || offset > size || size - offset < 10 { return nil }
    let pathCount = Int(unsigned(bytes, offset, 2))
    let dataCount = unsigned(bytes, offset + 2, 8)
    if pathCount > size - offset - 10 || dataCount > UInt64(size - offset - 10 - pathCount) { return nil }
    let path = bytes.advanced(by: offset + 10)
    if !validPath(path, count: pathCount) { return nil }
    let dataStart = offset + 10 + pathCount
    return Record(path: path, pathCount: pathCount, data: bytes.advanced(by: dataStart),
                  dataCount: Int(dataCount), next: dataStart + Int(dataCount))
}
private func bundleValid(_ bytes: UnsafePointer<UInt8>, size: Int) -> Bool {
    if size < 12 || size > maximumBundleBytes || !same(bytes, "SWTBND01") { return false }
    let count = unsigned(bytes, 8, 4)
    if count == 0 || count > 512 { return false }
    var offset = 12
    var index: UInt64 = 0
    while index < count {
        guard let item = record(bytes, size: size, offset: offset) else { return false }
        offset = item.next
        index += 1
    }
    return offset == size
}

private func payload(_ module: HMODULE?) -> (UnsafeMutablePointer<UInt8>, Int)? {
    guard let name = UnsafePointer<WCHAR>(bitPattern: 201), let type = UnsafePointer<WCHAR>(bitPattern: 10),
          let resource = FindResourceW(module, name, type) else { return nil }
    let resourceSize = Int(SizeofResource(module, resource))
    if resourceSize <= 48 || resourceSize > maximumBundleBytes { return nil }
    guard let loaded = LoadResource(module, resource), let locked = LockResource(loaded) else { return nil }
    let bytes = locked.assumingMemoryBound(to: UInt8.self)
    if !same(UnsafePointer(bytes), "SWTPKG01") { return nil }
    let bundleSize = unsigned(UnsafePointer(bytes), 8, 8)
    if bundleSize < 12 || bundleSize > UInt64(maximumBundleBytes) { return nil }
    guard let output = allocate(Int(bundleSize)) else { return nil }
    var decompressor: DECOMPRESSOR_HANDLE?
    if !CreateDecompressor(UInt32(COMPRESS_ALGORITHM_LZMS), nil, &decompressor) {
        release(output)
        return nil
    }
    var written: SIZE_T = 0
    let succeeded = Decompress(decompressor, bytes.advanced(by: 48), SIZE_T(resourceSize - 48),
                               output, SIZE_T(bundleSize), &written)
    CloseDecompressor(decompressor)
    let result = output.assumingMemoryBound(to: UInt8.self)
    if !succeeded || written != bundleSize
        || !hashMatches(result, count: Int(bundleSize), digest: UnsafePointer(bytes.advanced(by: 16)))
        || !bundleValid(UnsafePointer(result), size: Int(bundleSize)) {
        release(output)
        return nil
    }
    return (result, Int(bundleSize))
}

private func pathLength(_ path: UnsafePointer<WCHAR>) -> Int {
    var count = 0
    while count < pathCapacity && path[count] != 0 { count += 1 }
    return count
}
private func append(_ output: UnsafeMutablePointer<WCHAR>, base: UnsafePointer<WCHAR>, suffix: UnsafePointer<UInt8>, count: Int) -> Bool {
    let baseCount = pathLength(base)
    if baseCount == pathCapacity || count > pathCapacity - baseCount - 2 { return false }
    var index = 0
    while index < baseCount { output[index] = base[index]; index += 1 }
    output[index] = 92
    index = 0
    while index < count {
        output[baseCount + 1 + index] = WCHAR(suffix[index] == 47 ? 92 : suffix[index])
        index += 1
    }
    output[baseCount + count + 1] = 0
    return true
}
private func makeParents(_ path: UnsafeMutablePointer<WCHAR>, after baseCount: Int) -> Bool {
    var index = baseCount + 1
    while path[index] != 0 {
        if path[index] == 92 {
            path[index] = 0
            let created = CreateDirectoryW(path, nil)
            let error = GetLastError()
            let attributes = GetFileAttributesW(path)
            path[index] = 92
            if !created && error != DWORD(ERROR_ALREADY_EXISTS) { return false }
            if attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
                || attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return false }
        }
        index += 1
    }
    return true
}
private func parentsSafe(_ path: UnsafeMutablePointer<WCHAR>, after baseCount: Int) -> Bool {
    var index = baseCount
    while path[index] != 0 {
        if path[index] == 92 {
            path[index] = 0
            let attributes = GetFileAttributesW(path)
            path[index] = 92
            if attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
                || attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return false }
        }
        index += 1
    }
    return true
}
private func extract(_ bytes: UnsafePointer<UInt8>, size: Int, directory: UnsafePointer<WCHAR>) -> Bool {
    guard let storage = allocate(pathCapacity * 2) else { return false }
    defer { release(storage) }
    let path = storage.assumingMemoryBound(to: WCHAR.self)
    let baseCount = pathLength(directory)
    var offset = 12
    let count = unsigned(bytes, 8, 4)
    var index: UInt64 = 0
    while index < count {
        guard let item = record(bytes, size: size, offset: offset),
              append(path, base: directory, suffix: item.path, count: item.pathCount),
              makeParents(path, after: baseCount) else { return false }
        guard let file = CreateFileW(path, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW),
                                    DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil),
              file != INVALID_HANDLE_VALUE else { return false }
        var written: DWORD = 0
        let result = WriteFile(file, item.data, DWORD(item.dataCount), &written, nil)
        CloseHandle(file)
        if !result || written != item.dataCount { return false }
        offset = item.next
        index += 1
    }
    return true
}
private func cleanup(_ bytes: UnsafePointer<UInt8>, size: Int, directory: UnsafePointer<WCHAR>) {
    guard let storage = allocate(pathCapacity * 2) else { return }
    defer { release(storage) }
    let path = storage.assumingMemoryBound(to: WCHAR.self)
    let baseCount = pathLength(directory)
    let count = unsigned(bytes, 8, 4)
    var offset = 12
    var index: UInt64 = 0
    while index < count {
        guard let item = record(bytes, size: size, offset: offset) else { break }
        if append(path, base: directory, suffix: item.path, count: item.pathCount), parentsSafe(path, after: baseCount) { DeleteFileW(path) }
        offset = item.next
        index += 1
    }
    offset = 12
    index = 0
    while index < count {
        guard let item = record(bytes, size: size, offset: offset) else { break }
        if append(path, base: directory, suffix: item.path, count: item.pathCount), parentsSafe(path, after: baseCount) {
            var position = pathLength(UnsafePointer(path)) - 1
            while position > baseCount {
                if path[position] == 92 { path[position] = 0; RemoveDirectoryW(path) }
                position -= 1
            }
        }
        offset = item.next
        index += 1
    }
    RemoveDirectoryW(directory)
}

private func stagingDirectory() -> UnsafeMutablePointer<WCHAR>? {
    guard let tempStorage = allocate(pathCapacity * 2) else { return nil }
    defer { release(tempStorage) }
    guard let outputStorage = allocate(pathCapacity * 2) else { return nil }
    let temp = tempStorage.assumingMemoryBound(to: WCHAR.self)
    let output = outputStorage.assumingMemoryBound(to: WCHAR.self)
    let tempCount = Int(GetTempPathW(DWORD(pathCapacity), temp))
    if tempCount == 0 || tempCount >= pathCapacity - 64 { release(outputStorage); return nil }
    var position = 0
    var source = 0
    output[0] = 92; output[1] = 92; output[2] = 63; output[3] = 92
    position = 4
    if tempCount >= 3 && temp[1] == 58 && temp[2] == 92 {
        source = 0
    } else if tempCount >= 3 && temp[0] == 92 && temp[1] == 92 && temp[2] != 63 && temp[2] != 46 {
        output[4] = 85; output[5] = 78; output[6] = 67; output[7] = 92
        position = 8; source = 2
    } else { release(outputStorage); return nil }
    while source < tempCount { output[position] = temp[source]; position += 1; source += 1 }
    if output[position - 1] != 92 { output[position] = 92; position += 1 }
    let prefix: StaticString = "SwiftyToys-Setup-"
    var index = 0
    while index < prefix.utf8CodeUnitCount { output[position] = WCHAR(prefix.utf8Start[index]); position += 1; index += 1 }
    var guid = GUID()
    if CoCreateGuid(&guid) < 0 || StringFromGUID2(&guid, output.advanced(by: position), 39) != 39 {
        release(outputStorage); return nil
    }
    guard let descriptor = directorySecurity() else { release(outputStorage); return nil }
    var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
    let created = CreateDirectoryW(output, &security)
    LocalFree(descriptor)
    if !created { release(outputStorage); return nil }
    let attributes = GetFileAttributesW(output)
    if attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
        RemoveDirectoryW(output); release(outputStorage); return nil
    }
    return output
}
private func runInstaller(_ directory: UnsafePointer<WCHAR>, arguments: StaticString = "\" --installer") -> DWORD {
    guard let executableStorage = allocate(pathCapacity * 2) else { return 0x1004 }
    defer { release(executableStorage) }
    guard let commandStorage = allocate(pathCapacity * 2) else { return 0x1004 }
    defer { release(commandStorage) }
    let executable = executableStorage.assumingMemoryBound(to: WCHAR.self)
    let command = commandStorage.assumingMemoryBound(to: WCHAR.self)
    let name: StaticString = "SwiftyToys.exe"
    if !append(executable, base: directory, suffix: name.utf8Start, count: name.utf8CodeUnitCount) { return 0x1004 }
    let executableCount = pathLength(UnsafePointer(executable))
    if executableCount > pathCapacity - arguments.utf8CodeUnitCount - 2 { return 0x1004 }
    command[0] = 34
    var index = 0
    while index < executableCount { command[index + 1] = executable[index]; index += 1 }
    var position = executableCount + 1
    index = 0
    while index < arguments.utf8CodeUnitCount { command[position] = WCHAR(arguments.utf8Start[index]); position += 1; index += 1 }
    command[position] = 0
    var startup = STARTUPINFOW()
    startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
    var process = PROCESS_INFORMATION()
    if !CreateProcessW(executable, command, nil, nil, false, DWORD(CREATE_UNICODE_ENVIRONMENT), nil, directory, &startup, &process) { return 0x1004 }
    CloseHandle(process.hThread)
    defer { CloseHandle(process.hProcess) }
    if WaitForSingleObject(process.hProcess, DWORD(INFINITE)) != DWORD(WAIT_OBJECT_0) { return 0x1004 }
    var code: DWORD = 1
    if !GetExitCodeProcess(process.hProcess, &code) { return 0x1004 }
    return code
}
private func bootstrap() -> DWORD {
    SetErrorMode(UINT(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX))
    guard let (bytes, size) = payload(GetModuleHandleW(nil)) else { return 0x1001 }
    defer { release(bytes) }
    guard let directory = stagingDirectory() else { return 0x1002 }
    defer { cleanup(UnsafePointer(bytes), size: size, directory: UnsafePointer(directory)); release(directory) }
    if !extract(UnsafePointer(bytes), size: size, directory: UnsafePointer(directory)) { return 0x1003 }
    let prerequisite = prepareRuntime(UnsafePointer(directory))
    if prerequisite != 0 { return prerequisite }
    return runInstaller(UnsafePointer(directory), arguments: automaticInstallation() ? "\" --installer --install" : "\" --installer")
}
private func automaticInstallation() -> Bool {
    var count: Int32 = 0
    guard let values = CommandLineToArgvW(GetCommandLineW(), &count) else { return false }
    defer { LocalFree(values) }
    guard count == 2, let argument = values[1] else { return false }
    let option: StaticString = "--install"
    var index = 0
    while index < option.utf8CodeUnitCount {
        if argument[index] != WCHAR(option.utf8Start[index]) { return false }
        index += 1
    }
    return argument[index] == 0
}
private func failure() {
    guard let title = wide("SwiftyToys Setup") else { return }
    defer { release(title) }
    guard let message = wide("Setup could not extract or start its installation files. Download a fresh copy and try again.") else { return }
    defer { release(message) }
    MessageBoxW(nil, message, title, UINT(MB_OK | MB_ICONERROR))
}

@inline(never)
private func startBootstrap() {
    #if BOOTSTRAP_SELFTEST
    let result = selfcheck()
    if result != 0 { ExitProcess(result) }
    #if BOOTSTRAP_PACKAGECHECK
    ExitProcess(packageCheck())
    #else
    ExitProcess(0)
    #endif
    #else
    let result = bootstrap()
    if result >= 0x1001 && result <= 0x1004 { failure() }
    if result == 0x1005 { prerequisiteFailure() }
    ExitProcess(result)
    #endif
}

@_cdecl("bootstrapEntry")
public func bootstrapEntry() {
    __security_init_cookie()
    startBootstrap()
}

// Bind these constants to one independently verified Microsoft download at release time.
private let redistHost: StaticString = "download.visualstudio.microsoft.com"
private let redistPath: StaticString = "/download/pr/bd1c8d9d-ba95-4eee-bc6e-df1fcc876373/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe"
private let redistSHA256: StaticString = "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"
private let minimumRuntimeVersion: UInt64 = (14 << 48) | (44 << 32) | (35211 << 16)

private func runtimeFileReady(_ name: StaticString) -> Bool {
    guard let libraryName = wide(name) else { return false }
    defer { release(libraryName) }
    guard let module = LoadLibraryExW(libraryName, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)) else { return false }
    defer { FreeLibrary(module) }
    guard let pathStorage = allocate(pathCapacity * 2) else { return false }
    defer { release(pathStorage) }
    let path = pathStorage.assumingMemoryBound(to: WCHAR.self)
    let count = GetModuleFileNameW(module, path, DWORD(pathCapacity))
    if count == 0 || count >= DWORD(pathCapacity) { return false }
    var ignored: DWORD = 0
    let size = GetFileVersionInfoSizeW(path, &ignored)
    if size == 0 || size > 1024 * 1024 { return false }
    guard let info = allocate(Int(size)) else { return false }
    defer { release(info) }
    guard let root = wide("\\") else { return false }
    defer { release(root) }
    if !GetFileVersionInfoW(path, 0, size, info) { return false }
    var value: UnsafeMutableRawPointer?
    var length: UINT = 0
    if !VerQueryValueW(info, root, &value, &length) || length < MemoryLayout<VS_FIXEDFILEINFO>.size { return false }
    guard let version = value?.assumingMemoryBound(to: VS_FIXEDFILEINFO.self), version.pointee.dwSignature == 0xfeef04bd else { return false }
    let number = UInt64(version.pointee.dwFileVersionMS) << 32 | UInt64(version.pointee.dwFileVersionLS)
    return number >= minimumRuntimeVersion
}
private func runtimeReady() -> Bool {
    runtimeFileReady("vcruntime140.dll") && runtimeFileReady("vcruntime140_1.dll") && runtimeFileReady("msvcp140.dll")
}
private func hexNibble(_ value: UInt8) -> UInt8? {
    if value >= 48 && value <= 57 { return value - 48 }
    if value >= 65 && value <= 70 { return value - 65 + 10 }
    if value >= 97 && value <= 102 { return value - 97 + 10 }
    return nil
}
private func pinnedDigest(_ digest: UnsafePointer<UInt8>) -> Bool {
    if redistSHA256.utf8CodeUnitCount != 64 { return false }
    var index = 0
    var difference: UInt8 = 0
    while index < 32 {
        guard let high = hexNibble(redistSHA256.utf8Start[index * 2]),
              let low = hexNibble(redistSHA256.utf8Start[index * 2 + 1]) else { return false }
        difference |= digest[index] ^ (high << 4 | low)
        index += 1
    }
    return difference == 0
}
private func downloadRedist(_ path: UnsafePointer<WCHAR>) -> Bool {
    if redistSHA256.utf8CodeUnitCount != 64 { return false }
    guard let agent = wide("SwiftyToys Setup") else { return false }
    defer { release(agent) }
    guard let host = wide(redistHost) else { return false }
    defer { release(host) }
    guard let remotePath = wide(redistPath) else { return false }
    defer { release(remotePath) }
    guard let session = WinHttpOpen(agent, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) else { return false }
    defer { WinHttpCloseHandle(session) }
    if !WinHttpSetTimeouts(session, 10000, 10000, 30000, 30000) { return false }
    var protocols: DWORD = DWORD(WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2)
    if !WinHttpSetOption(session, DWORD(WINHTTP_OPTION_SECURE_PROTOCOLS), &protocols, DWORD(MemoryLayout<DWORD>.size)) { return false }
    guard let connection = WinHttpConnect(session, host, INTERNET_PORT(443), 0) else { return false }
    defer { WinHttpCloseHandle(connection) }
    guard let request = WinHttpOpenRequest(connection, nil, remotePath, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) else { return false }
    defer { WinHttpCloseHandle(request) }
    var redirectPolicy: DWORD = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
    if !WinHttpSetOption(request, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &redirectPolicy, DWORD(MemoryLayout<DWORD>.size)) { return false }
    if !WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0) || !WinHttpReceiveResponse(request, nil) { return false }
    var status: DWORD = 0
    var statusSize = DWORD(MemoryLayout<DWORD>.size)
    if !WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &status, &statusSize, nil)
        || status != 200 { return false }
    guard let name = wide("SHA256") else { return false }
    defer { release(name) }
    var algorithm: BCRYPT_ALG_HANDLE?
    if BCryptOpenAlgorithmProvider(&algorithm, name, nil, 0) < 0 { return false }
    defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
    var hash: BCRYPT_HASH_HANDLE?
    if BCryptCreateHash(algorithm, &hash, nil, 0, nil, 0, 0) < 0 { return false }
    defer { BCryptDestroyHash(hash) }
    guard let buffer = allocate(65536) else { return false }
    defer { release(buffer) }
    guard let file = CreateFileW(path, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW),
                                DWORD(FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_OPEN_REPARSE_POINT), nil),
          file != INVALID_HANDLE_VALUE else { return false }
    defer { CloseHandle(file) }
    var total: DWORD = 0
    while true {
        var read: DWORD = 0
        if !WinHttpReadData(request, buffer, 65536, &read) { return false }
        if read == 0 { break }
        if read > 65536 || read > 32 * 1024 * 1024 - total { return false }
        var written: DWORD = 0
        if !WriteFile(file, buffer, read, &written, nil) || written != read
            || BCryptHashData(hash, buffer.assumingMemoryBound(to: UCHAR.self), read, 0) < 0 { return false }
        total += read
    }
    if total == 0 || !FlushFileBuffers(file) { return false }
    if BCryptFinishHash(hash, buffer.assumingMemoryBound(to: UCHAR.self), 32, 0) < 0 { return false }
    return pinnedDigest(UnsafePointer(buffer.assumingMemoryBound(to: UInt8.self)))
}
private func pinnedFile(_ file: HANDLE) -> Bool {
    guard let name = wide("SHA256") else { return false }
    defer { release(name) }
    var algorithm: BCRYPT_ALG_HANDLE?
    if BCryptOpenAlgorithmProvider(&algorithm, name, nil, 0) < 0 { return false }
    defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
    var hash: BCRYPT_HASH_HANDLE?
    if BCryptCreateHash(algorithm, &hash, nil, 0, nil, 0, 0) < 0 { return false }
    defer { BCryptDestroyHash(hash) }
    guard let buffer = allocate(65536) else { return false }
    defer { release(buffer) }
    var total: DWORD = 0
    while true {
        var read: DWORD = 0
        if !ReadFile(file, buffer, 65536, &read, nil) { return false }
        if read == 0 { break }
        if read > 65536 || read > 32 * 1024 * 1024 - total
            || BCryptHashData(hash, buffer.assumingMemoryBound(to: UCHAR.self), read, 0) < 0 { return false }
        total += read
    }
    if total == 0 || BCryptFinishHash(hash, buffer.assumingMemoryBound(to: UCHAR.self), 32, 0) < 0 { return false }
    if !pinnedDigest(UnsafePointer(buffer.assumingMemoryBound(to: UInt8.self))) { return false }
    return SetFilePointerEx(file, LARGE_INTEGER(), nil, DWORD(FILE_BEGIN))
}
private func trustedRedist(_ path: UnsafePointer<WCHAR>, file: HANDLE) -> Bool {
    var attributes = BY_HANDLE_FILE_INFORMATION()
    if !GetFileInformationByHandle(file, &attributes) || attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return false }
    var action = GUID(Data1: 0x00aac56b, Data2: 0xcd44, Data3: 0x11d0, Data4: (0x8c, 0xc2, 0x00, 0xc0, 0x4f, 0xc2, 0x95, 0xee))
    var info = WINTRUST_FILE_INFO_(cbStruct: DWORD(MemoryLayout<WINTRUST_FILE_INFO_>.size), pcwszFilePath: path, hFile: file, pgKnownSubject: nil)
    return withUnsafeMutablePointer(to: &info) { pointer in
        var data = WINTRUST_DATA()
        data.cbStruct = DWORD(MemoryLayout<WINTRUST_DATA>.size)
        data.dwUIChoice = DWORD(WTD_UI_NONE)
        data.fdwRevocationChecks = DWORD(WTD_REVOKE_WHOLECHAIN)
        data.dwUnionChoice = DWORD(WTD_CHOICE_FILE)
        data.pFile = pointer
        data.dwStateAction = DWORD(WTD_STATEACTION_VERIFY)
        data.dwProvFlags = DWORD(WTD_DISABLE_MD2_MD4 | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT)
        let result = WinVerifyTrust(HWND(bitPattern: -1), &action, &data)
        data.dwStateAction = DWORD(WTD_STATEACTION_CLOSE)
        WinVerifyTrust(HWND(bitPattern: -1), &action, &data)
        return result == 0
    }
}
private func installRedist(_ path: UnsafePointer<WCHAR>, directory: UnsafePointer<WCHAR>) -> DWORD {
    guard let verb = wide("runas") else { return 0x1005 }
    defer { release(verb) }
    guard let parameters = wide("/install /quiet /norestart") else { return 0x1005 }
    defer { release(parameters) }
    var info = SHELLEXECUTEINFOW()
    info.cbSize = DWORD(MemoryLayout<SHELLEXECUTEINFOW>.size)
    info.fMask = ULONG(SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI)
    info.lpVerb = UnsafePointer(verb)
    info.lpFile = path
    info.lpParameters = UnsafePointer(parameters)
    info.lpDirectory = directory
    info.nShow = SW_HIDE
    if !ShellExecuteExW(&info) { return GetLastError() == DWORD(ERROR_CANCELLED) ? 0x1006 : 0x1005 }
    guard let process = info.hProcess else { return 0x1005 }
    defer { CloseHandle(process) }
    if WaitForSingleObject(process, DWORD(INFINITE)) != DWORD(WAIT_OBJECT_0) { return 0x1005 }
    var code: DWORD = 1
    if !GetExitCodeProcess(process, &code) { return 0x1005 }
    if code == 1602 { return 0x1006 }
    if code != 0 && code != 3010 { return 0x1005 }
    return runtimeReady() ? 0 : 0x1005
}
private func prepareRuntime(_ directory: UnsafePointer<WCHAR>) -> DWORD {
    if runtimeReady() { return 0 }
    guard let title = wide("SwiftyToys Setup") else { return 0x1005 }
    defer { release(title) }
    guard let message = wide("SwiftyToys needs the Microsoft Visual C++ Runtime. Download and install the signed Microsoft component now? An internet connection and administrator approval are required.") else { return 0x1005 }
    defer { release(message) }
    if MessageBoxW(nil, message, title, UINT(MB_OKCANCEL | MB_ICONINFORMATION)) != IDOK { return 0x1006 }
    guard let storage = allocate(pathCapacity * 2) else { return 0x1005 }
    defer { release(storage) }
    let path = storage.assumingMemoryBound(to: WCHAR.self)
    let name: StaticString = "VC_redist.x64.exe"
    if !append(path, base: directory, suffix: name.utf8Start, count: name.utf8CodeUnitCount) { return 0x1005 }
    defer { DeleteFileW(path) }
    if !downloadRedist(UnsafePointer(path)) { return 0x1005 }
    // Keep the verified file locked against replacement throughout the elevated vendor process.
    guard let file = CreateFileW(path, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                                DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil), file != INVALID_HANDLE_VALUE else { return 0x1005 }
    defer { CloseHandle(file) }
    if !pinnedFile(file) || !trustedRedist(UnsafePointer(path), file: file) { return 0x1005 }
    return installRedist(UnsafePointer(path), directory: directory)
}

private func prerequisiteFailure() {
    guard let title = wide("SwiftyToys Setup") else { return }
    defer { release(title) }
    guard let message = wide("The Microsoft Visual C++ Runtime could not be downloaded, verified or installed. Check your connection and try again. If Windows requested a restart, restart Windows before retrying.") else { return }
    defer { release(message) }
    MessageBoxW(nil, message, title, UINT(MB_OK | MB_ICONERROR))
}

private func directorySecurity() -> PSECURITY_DESCRIPTOR? {
    var token: HANDLE?
    if !OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token) { return nil }
    defer { CloseHandle(token) }
    var size: DWORD = 0
    GetTokenInformation(token, TokenUser, nil, 0, &size)
    if size == 0 || size > 16384 { return nil }
    guard let storage = allocate(Int(size)) else { return nil }
    defer { release(storage) }
    if !GetTokenInformation(token, TokenUser, storage, size, &size) { return nil }
    var sid: LPWSTR?
    if !ConvertSidToStringSidW(storage.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid, &sid) { return nil }
    guard let sid else { return nil }
    defer { LocalFree(sid) }
    let sidCount = pathLength(UnsafePointer(sid))
    if sidCount == 0 || sidCount > 256 { return nil }
    guard let descriptorStorage = allocate(2048, zero: true) else { return nil }
    defer { release(descriptorStorage) }
    let text = descriptorStorage.assumingMemoryBound(to: WCHAR.self)
    let prefix: StaticString = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;"
    var index = 0
    while index < prefix.utf8CodeUnitCount { text[index] = WCHAR(prefix.utf8Start[index]); index += 1 }
    var position = index
    index = 0
    while index < sidCount { text[position] = sid[index]; position += 1; index += 1 }
    text[position] = 41
    var descriptor: PSECURITY_DESCRIPTOR?
    if !ConvertStringSecurityDescriptorToSecurityDescriptorW(text, DWORD(SDDL_REVISION_1), &descriptor, nil) { return nil }
    return descriptor
}

#if BOOTSTRAP_SELFTEST

#if BOOTSTRAP_PACKAGECHECK
// Exercise the shipped resource and stage-two UI without changing any installation.
private func packageCheck() -> DWORD {
    guard let (bytes, size) = payload(GetModuleHandleW(nil)) else { return 10 }
    defer { release(bytes) }
    guard let directory = stagingDirectory() else { return 11 }
    defer { cleanup(UnsafePointer(bytes), size: size, directory: UnsafePointer(directory)); release(directory) }
    if !extract(UnsafePointer(bytes), size: size, directory: UnsafePointer(directory)) { return 12 }
    if !runtimeReady() { return 13 }
    return runInstaller(UnsafePointer(directory), arguments: "\" --test-installer-ui")
}
#endif

private func pathCase(_ text: StaticString, expected: Bool) -> Bool {
    validPath(text.utf8Start, count: text.utf8CodeUnitCount) == expected
}
private func selfcheck() -> DWORD {
    if !pathCase("Languages/en.json", expected: true) || !pathCase("resources/SwiftyToys.ico", expected: true)
        || !pathCase("../file", expected: false) || !pathCase("a/../file", expected: false)
        || !pathCase("C:/file", expected: false) || !pathCase("a\\file", expected: false)
        || !pathCase("CON.txt", expected: false) || !pathCase("a./file", expected: false)
        || !pathCase("a/", expected: false) || !pathCase("/a", expected: false)
        || !pathCase("a//b", expected: false) || !pathCase("a b", expected: false)
        || !pathCase("NUL", expected: false) || !pathCase("com1", expected: false)
        || !pathCase("COM9.ext", expected: false) || !pathCase("LPT0", expected: true) { return 1 }
    guard let storage = allocate(64, zero: true) else { return 2 }
    defer { release(storage) }
    let bytes = storage.assumingMemoryBound(to: UInt8.self)
    let magic: StaticString = "SWTBND01"
    var index = 0
    while index < 8 { bytes[index] = magic.utf8Start[index]; index += 1 }
    bytes[8] = 1; bytes[12] = 1; bytes[14] = 1; bytes[22] = 120; bytes[23] = 41
    if !bundleValid(UnsafePointer(bytes), size: 24) || bundleValid(UnsafePointer(bytes), size: 23)
        || bundleValid(UnsafePointer(bytes), size: 25) { return 3 }
    bytes[8] = 1; bytes[9] = 2
    if bundleValid(UnsafePointer(bytes), size: 24) { return 4 }
    bytes[9] = 0
    index = 14
    while index < 22 { bytes[index] = 255; index += 1 }
    if bundleValid(UnsafePointer(bytes), size: 24) { return 5 }
    bytes[14] = 0
    index = 15
    while index < 22 { bytes[index] = 0; index += 1 }
    bytes[12] = 0
    if bundleValid(UnsafePointer(bytes), size: 22) { return 6 }
    return 0
}

#endif
