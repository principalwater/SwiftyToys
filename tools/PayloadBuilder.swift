// SPDX-License-Identifier: MIT
// Build-only payload creation: standard Swift and native Windows file, hashing and compression APIs.
import WinSDK

private let maximumBytes = 64 * 1024 * 1024
private enum BuildFailure: Error { case invalidInput, fileIO, hashing, compression }
private func wide(_ text: String) -> [WCHAR] { Array(text.utf16) + [0] }
private func fileName(_ data: inout WIN32_FIND_DATAW) -> String {
    withUnsafePointer(to: &data.cFileName) {
        $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) { pointer in
            var count = 0
            while count < Int(MAX_PATH) && pointer[count] != 0 { count += 1 }
            return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF16.self)
        }
    }
}
private func read(_ path: String, maximum: Int = maximumBytes) throws -> [UInt8] {
    let name = wide(path)
    guard let file = name.withUnsafeBufferPointer({ CreateFileW($0.baseAddress, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil,
            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN), nil) }), file != INVALID_HANDLE_VALUE else { throw BuildFailure.fileIO }
    defer { CloseHandle(file) }
    var information = BY_HANDLE_FILE_INFORMATION()
    if !GetFileInformationByHandle(file, &information)
        || information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) != 0 { throw BuildFailure.invalidInput }
    let size = UInt64(information.nFileSizeHigh) << 32 | UInt64(information.nFileSizeLow)
    if size > UInt64(maximum) { throw BuildFailure.invalidInput }
    var bytes = [UInt8](repeating: 0, count: Int(size))
    var amount: DWORD = 0
    let succeeded = bytes.withUnsafeMutableBytes { ReadFile(file, $0.baseAddress, DWORD(size), &amount, nil) }
    if !succeeded || amount != bytes.count { throw BuildFailure.fileIO }
    return bytes
}
private func reserved(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
    var length = 0
    while start + length < end && bytes[start + length] != 46 { length += 1 }
    if length != 3 && length != 4 { return false }
    let a = bytes[start] & 0xdf, b = bytes[start + 1] & 0xdf, c = bytes[start + 2] & 0xdf
    if length == 3 {
        return (a == 67 && b == 79 && c == 78) || (a == 80 && b == 82 && c == 78)
            || (a == 65 && b == 85 && c == 88) || (a == 78 && b == 85 && c == 76)
    }
    return ((a == 67 && b == 79 && c == 77) || (a == 76 && b == 80 && c == 84))
        && bytes[start + 3] >= 49 && bytes[start + 3] <= 57
}
private func valid(_ path: String) -> Bool {
    let bytes = Array(path.utf8)
    if bytes.isEmpty || bytes.count > 1024 { return false }
    var start = 0
    for index in 0...bytes.count {
        if index == bytes.count || bytes[index] == 47 {
            let count = index - start
            if count == 0 || count > 255 || bytes[start] == 46 || bytes[index - 1] == 46 || reserved(bytes, start, index) { return false }
            start = index + 1
        } else {
            let character = bytes[index]
            if !((character >= 65 && character <= 90) || (character >= 97 && character <= 122)
                || (character >= 48 && character <= 57) || character == 45 || character == 46 || character == 95) { return false }
        }
    }
    return true
}
private func enumerate(_ source: String, relative: String = "", files: inout [String]) throws {
    if relative.utf8.count > 1024 { throw BuildFailure.invalidInput }
    let directory = relative.isEmpty ? source : source + "\\" + relative.replacingForwardSlash()
    let pattern = wide(directory + "\\*")
    var data = WIN32_FIND_DATAW()
    guard let handle = pattern.withUnsafeBufferPointer({ FindFirstFileW($0.baseAddress, &data) }), handle != INVALID_HANDLE_VALUE else { throw BuildFailure.fileIO }
    defer { FindClose(handle) }
    while true {
        let name = fileName(&data)
        if name != "." && name != ".." {
            let path = relative.isEmpty ? name : relative + "/" + name
            if !valid(path) || data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { throw BuildFailure.invalidInput }
            if relative.isEmpty {
                let allowedFiles = ["SwiftyToys.exe", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md", "runtime-files.txt", "swift-version.txt"]
                let allowedDirectories = ["Languages", "resources", "Licenses", "docs", "Drivers"]
                if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                    if !allowedDirectories.contains(name) { throw BuildFailure.invalidInput }
                } else if !allowedFiles.contains(name) { throw BuildFailure.invalidInput }
            }
            if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                try enumerate(source, relative: path, files: &files)
            } else {
                let lower = name.lowercased()
                if lower.hasSuffix(".ps1") || lower.hasSuffix(".cmd") || lower.hasSuffix(".bat") || lower.hasSuffix(".iss") || lower.hasSuffix(".pas") { throw BuildFailure.invalidInput }
                files.append(path)
                if files.count > 512 { throw BuildFailure.invalidInput }
            }
        }
        if !FindNextFileW(handle, &data) {
            if GetLastError() != DWORD(ERROR_NO_MORE_FILES) { throw BuildFailure.fileIO }
            break
        }
    }
}
private extension String {
    func replacingForwardSlash() -> String { String(map { $0 == "/" ? "\\" : $0 }) }
}
private func append(_ value: UInt64, width: Int, to bytes: inout [UInt8]) {
    for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
}
private func digest(_ bytes: [UInt8]) throws -> [UInt8] {
    var algorithm: BCRYPT_ALG_HANDLE?
    let name = wide("SHA256")
    if name.withUnsafeBufferPointer({ BCryptOpenAlgorithmProvider(&algorithm, $0.baseAddress, nil, 0) }) < 0 { throw BuildFailure.hashing }
    defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
    var hash: BCRYPT_HASH_HANDLE?
    if BCryptCreateHash(algorithm, &hash, nil, 0, nil, 0, 0) < 0 { throw BuildFailure.hashing }
    defer { BCryptDestroyHash(hash) }
    if bytes.withUnsafeBytes({ BCryptHashData(hash, UnsafeMutableRawPointer(mutating: $0.baseAddress)?.assumingMemoryBound(to: UCHAR.self), UInt32(bytes.count), 0) }) < 0 { throw BuildFailure.hashing }
    var result = [UInt8](repeating: 0, count: 32)
    if result.withUnsafeMutableBufferPointer({ BCryptFinishHash(hash, $0.baseAddress, 32, 0) }) < 0 { throw BuildFailure.hashing }
    return result
}
private func compress(_ bytes: [UInt8]) throws -> [UInt8] {
    var compressor: COMPRESSOR_HANDLE?
    if !CreateCompressor(UInt32(COMPRESS_ALGORITHM_LZMS), nil, &compressor) { throw BuildFailure.compression }
    defer { CloseCompressor(compressor) }
    var blockSize: DWORD = 1024 * 1024
    if !SetCompressorInformation(compressor, COMPRESS_INFORMATION_CLASS_BLOCK_SIZE, &blockSize, SIZE_T(MemoryLayout<DWORD>.size)) { throw BuildFailure.compression }
    var size: SIZE_T = 0
    let query = bytes.withUnsafeBytes { Compress(compressor, $0.baseAddress, SIZE_T(bytes.count), nil, 0, &size) }
    if query || GetLastError() != DWORD(ERROR_INSUFFICIENT_BUFFER) || size == 0 || size > maximumBytes - 48 { throw BuildFailure.compression }
    var result = [UInt8](repeating: 0, count: Int(size))
    let capacity = result.count
    let succeeded = result.withUnsafeMutableBytes { output in
        bytes.withUnsafeBytes { Compress(compressor, $0.baseAddress, SIZE_T(bytes.count), output.baseAddress, SIZE_T(capacity), &size) }
    }
    if !succeeded || size > capacity { throw BuildFailure.compression }
    result.removeSubrange(Int(size)..<result.count)
    return result
}
private func write(_ bytes: [UInt8], to path: String) throws {
    let name = wide(path)
    guard let file = name.withUnsafeBufferPointer({ CreateFileW($0.baseAddress, DWORD(GENERIC_WRITE), 0, nil,
            DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil) }), file != INVALID_HANDLE_VALUE else { throw BuildFailure.fileIO }
    var written: DWORD = 0
    let succeeded = bytes.withUnsafeBytes { WriteFile(file, $0.baseAddress, DWORD(bytes.count), &written, nil) }
    let flushed = FlushFileBuffers(file)
    CloseHandle(file)
    if !succeeded || written != bytes.count || !flushed {
        name.withUnsafeBufferPointer { _ = DeleteFileW($0.baseAddress) }
        throw BuildFailure.fileIO
    }
}
private func build(source: String, destination: String) throws {
    let sourceName = wide(source)
    let attributes = sourceName.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
    if attributes == DWORD(INVALID_FILE_ATTRIBUTES) || attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        || attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { throw BuildFailure.invalidInput }
    var files: [String] = []
    try enumerate(source, files: &files)
    if !files.contains("SwiftyToys.exe") { throw BuildFailure.invalidInput }
    files.sort()
    var bundle = Array("SWTBND01".utf8)
    append(UInt64(files.count), width: 4, to: &bundle)
    for path in files {
        let pathBytes = Array(path.utf8)
        let overhead = 10 + pathBytes.count
        if overhead > maximumBytes - bundle.count { throw BuildFailure.invalidInput }
        let bytes = try read(source + "\\" + path.replacingForwardSlash(), maximum: maximumBytes - bundle.count - overhead)
        append(UInt64(pathBytes.count), width: 2, to: &bundle)
        append(UInt64(bytes.count), width: 8, to: &bundle)
        bundle.append(contentsOf: pathBytes)
        bundle.append(contentsOf: bytes)
    }
    var payload = Array("SWTPKG01".utf8)
    append(UInt64(bundle.count), width: 8, to: &payload)
    payload.append(contentsOf: try digest(bundle))
    payload.append(contentsOf: try compress(bundle))
    try write(payload, to: destination)
    print("Payload: \(files.count) files, \(bundle.count) expanded bytes, \(payload.count) packaged bytes")
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--selfcheck" {
    precondition(valid("Languages/en.json") && !valid("../file") && !valid("a/../file") && !valid("CON.txt") && !valid("C:/file") && !valid("a./file") && !valid("a//file"))
    print("Payload path selfcheck passed")
} else if CommandLine.arguments.count == 3 {
    do { try build(source: CommandLine.arguments[1], destination: CommandLine.arguments[2]) }
    catch { print("Payload build failed: \(error)"); ExitProcess(1) }
} else {
    print("Usage: PayloadBuilder SOURCE_DIRECTORY OUTPUT_PAYLOAD | --selfcheck")
    ExitProcess(2)
}
