// SPDX-License-Identifier: MIT

import WinSDK
import WindowsDisplayABI

/// Read-only checks of an existing driver file with CNG and WinVerifyTrust.
/// Policy mirrors scripts/install-trackpad.ps1: pinned SHA-256 for the download, then a trusted
/// Authenticode signature whose leaf subject starts with the expected publisher.
enum NativeDriverTrust {
    enum Signer: String {
        case apple = "CN=Apple Inc.,"
        case microsoftHardware = "CN=Microsoft Windows Hardware Compatibility Publisher,"
    }

    /// SHA-256 through CNG. `next` fills the buffer and returns the byte count, or 0 at the end.
    static func sha256(_ next: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> [UInt8] {
        var opened: BCRYPT_ALG_HANDLE?
        var status = withWideString("SHA256") { BCryptOpenAlgorithmProvider(&opened, $0, nil, 0) }
        guard status >= 0, let algorithm = opened else { throw WindowsError.status("Open SHA-256 provider", status) }
        defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
        var objectSize: DWORD = 0
        var written: DWORD = 0
        status = withWideString("ObjectLength") { name in
            withUnsafeMutableBytes(of: &objectSize) {
                BCryptGetProperty(
                    algorithm, name, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), DWORD($0.count), &written, 0)
            }
        }
        guard status >= 0, written == 4, objectSize > 0, objectSize <= 1_048_576 else {
            throw WindowsError.status("Query SHA-256 object size", status)
        }
        var object = [UInt8](repeating: 0, count: Int(objectSize))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var digest = [UInt8](repeating: 0, count: 32)
        try object.withUnsafeMutableBufferPointer { storage in
            var created: BCRYPT_HASH_HANDLE?
            let result = BCryptCreateHash(algorithm, &created, storage.baseAddress, DWORD(storage.count), nil, 0, 0)
            guard result >= 0, let hash = created else { throw WindowsError.status("Create SHA-256 hash", result) }
            defer { BCryptDestroyHash(hash) }
            var done = false
            while !done {
                let added: NTSTATUS = try chunk.withUnsafeMutableBytes { buffer in
                    let count = try next(buffer)
                    guard count >= 0, count <= buffer.count else {
                        throw WindowsError.unsupported("Invalid read size.")
                    }
                    done = count == 0
                    return done
                        ? 0
                        : BCryptHashData(hash, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), DWORD(count), 0)
                }
                guard added >= 0 else { throw WindowsError.status("Hash driver data", added) }
            }
            let finished = digest.withUnsafeMutableBufferPointer { BCryptFinishHash(hash, $0.baseAddress, 32, 0) }
            guard finished >= 0 else { throw WindowsError.status("Finish SHA-256 hash", finished) }
        }
        return digest
    }

    static func sha256(ofFile path: String) throws -> [UInt8] {
        let file = try OwnedHandle(
            withWideString(path) {
                CreateFileW(
                    $0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                    DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
            })
        return try sha256(from: file.raw)
    }

    private static func sha256(from file: HANDLE) throws -> [UInt8] {
        return try sha256 { buffer in
            var received: DWORD = 0
            guard ReadFile(file, buffer.baseAddress, DWORD(buffer.count), &received, nil) else {
                throw WindowsError.api("Read driver file", GetLastError())
            }
            return Int(received)
        }
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57: character - 48
        case 97...102: character - 87
        case 65...70: character - 55
        default: nil
        }
    }

    /// Exactly 64 ASCII hex digits, either case, equal to the digest. No trimming or prefixes.
    static func hashMatches(_ digest: [UInt8], expected: String) -> Bool {
        let text = Array(expected.utf8)
        guard digest.count == 32, text.count == 64 else { return false }
        var difference: UInt8 = 0
        for (index, byte) in digest.enumerated() {
            guard let high = nibble(text[2 * index]), let low = nibble(text[2 * index + 1]) else { return false }
            difference |= byte ^ (high << 4 | low)
        }
        return difference == 0
    }

    static func verifyHash(_ path: String, expected: String) throws {
        guard hashMatches(try sha256(ofFile: path), expected: expected) else {
            throw WindowsError.unsupported("Package hash does not match the pinned SHA-256.")
        }
    }
    /// Keeps the file locked against writes/deletion across hash and signature verification.
    static func verifyFile(_ path: String, expected: String, signer: Signer) throws {
        guard expected.utf8.count == 64, expected.utf8.allSatisfy({ nibble($0) != nil }) else {
            throw WindowsError.unsupported("Expected SHA-256 must contain exactly 64 ASCII hex digits.")
        }
        let file = try OwnedHandle(
            withWideString(path) {
                CreateFileW(
                    $0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                    DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
            })
        guard hashMatches(try sha256(from: file.raw), expected: expected) else {
            throw WindowsError.unsupported("Package hash does not match the pinned SHA-256.")
        }
        let position = LARGE_INTEGER()
        guard SetFilePointerEx(file.raw, position, nil, DWORD(FILE_BEGIN)) else {
            throw WindowsError.api("Rewind verified driver file", GetLastError())
        }
        try verifySignature(path, signer: signer, fileHandle: file.raw)
    }

    /// Case-insensitive ordinal prefix, like the installer's `-like 'CN=...,*'`.
    static func subjectMatches(_ subject: String, _ signer: Signer) -> Bool {
        let prefix = signer.rawValue
        return equalWindowsNames(String(decoding: subject.utf16.prefix(prefix.utf16.count), as: UTF16.self), prefix)
    }

    /// WinVerifyTrust must accept the complete chain before the leaf subject is considered.
    /// The signer certificate belongs to the verification state and is read before that state is closed.
    static func verifySignature(_ path: String, signer: Signer, fileHandle: HANDLE? = nil) throws {
        // WINTRUST_ACTION_GENERIC_VERIFY_V2; the SDK macro is not importable into Swift.
        var action = GUID(
            Data1: 0x00AA_C56B, Data2: 0xCD44, Data3: 0x11D0, Data4: (0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE))
        let window = HWND(bitPattern: -1)  // INVALID_HANDLE_VALUE: no UI
        try withWideString(path) { wide in
            var file = WINTRUST_FILE_INFO_(
                cbStruct: DWORD(MemoryLayout<WINTRUST_FILE_INFO_>.size), pcwszFilePath: wide, hFile: fileHandle,
                pgKnownSubject: nil)
            try withUnsafeMutablePointer(to: &file) { filePointer in
                var data = WINTRUST_DATA()
                data.cbStruct = DWORD(MemoryLayout<WINTRUST_DATA>.size)
                data.dwUIChoice = DWORD(WTD_UI_NONE)
                data.fdwRevocationChecks = DWORD(WTD_REVOKE_WHOLECHAIN)
                data.dwUnionChoice = DWORD(WTD_CHOICE_FILE)
                data.pFile = filePointer
                data.dwStateAction = DWORD(WTD_STATEACTION_VERIFY)
                data.dwProvFlags = DWORD(WTD_DISABLE_MD2_MD4 | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT)
                let result = WinVerifyTrust(window, &action, &data)
                defer {
                    data.dwStateAction = DWORD(WTD_STATEACTION_CLOSE)
                    _ = WinVerifyTrust(window, &action, &data)
                }
                guard result == 0 else { throw WindowsError.status("Verify Authenticode signature", result) }
                guard let provider = WTHelperProvDataFromStateData(data.hWVTStateData),
                    let primary = WTHelperGetProvSignerFromChain(provider, 0, false, 0),
                    let leaf = WTHelperGetProvCertFromChain(primary, 0),
                    let certificate = leaf.pointee.pCert
                else { throw WindowsError.unsupported("The signer certificate is unavailable.") }
                guard let chain = primary.pointee.pChainContext,
                    chain.pointee.TrustStatus.dwErrorStatus
                        & DWORD(
                            CERT_TRUST_IS_REVOKED | CERT_TRUST_REVOCATION_STATUS_UNKNOWN
                                | CERT_TRUST_IS_OFFLINE_REVOCATION) == 0
                else { throw WindowsError.unsupported("The signer revocation status could not be verified.") }
                var name = certificate.pointee.pCertInfo.pointee.Subject
                let encoding = DWORD(X509_ASN_ENCODING)
                let style = DWORD(CERT_X500_NAME_STR | CERT_NAME_STR_REVERSE_FLAG)  // CN first, as .NET Subject
                let size = CertNameToStrW(encoding, &name, style, nil, 0)
                guard size > 1, size <= 4096 else {
                    throw WindowsError.unsupported("The signer subject is unavailable.")
                }
                var buffer = [WCHAR](repeating: 0, count: Int(size))
                guard CertNameToStrW(encoding, &name, style, &buffer, size) == size else {
                    throw WindowsError.unsupported("The signer subject is unavailable.")
                }
                guard subjectMatches(String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self), signer) else {
                    throw WindowsError.unsupported("The file is not signed by the expected publisher.")
                }
            }
        }
    }

    /// Needs no driver package, administrator rights or file writes.
    static func selfCheck() throws {
        func expect(_ condition: Bool, _ name: String) throws {
            guard condition else { throw WindowsError.unsupported("Driver trust check failed: \(name).") }
        }
        func digest(_ text: String, chunk: Int) throws -> [UInt8] {
            var rest = Array(text.utf8)[...]
            return try sha256 { buffer in
                let count = min(chunk, buffer.count, rest.count)
                buffer.copyBytes(from: rest.prefix(count))
                rest = rest.dropFirst(count)
                return count
            }
        }
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let million = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        var remaining = 1_000_000
        let long = try sha256 { buffer in
            let count = min(buffer.count, remaining)
            for index in 0..<count { buffer[index] = 0x61 }
            remaining -= count
            return count
        }
        let digestOfABC = try digest("abc", chunk: 1024)
        try expect(hashMatches(digestOfABC, expected: abc), "lowercase hash")
        try expect(hashMatches(digestOfABC, expected: abc.uppercased()), "uppercase hash")
        try expect(hashMatches(try digest("abc", chunk: 1), expected: abc), "chunked hash")
        try expect(hashMatches(try digest("", chunk: 1), expected: empty), "empty hash")
        try expect(hashMatches(long, expected: million), "multi-buffer hash")
        let short = String(abc.dropLast())
        for bad in [
            "", short, abc + "0", " " + short, short + "\n", "0x" + String(abc.dropLast(2)), short + "g", short + "e",
            empty,
        ] {
            try expect(!hashMatches(digestOfABC, expected: bad), "strict hash rejection")
        }
        try expect(!hashMatches([UInt8](repeating: 0, count: 31), expected: abc), "digest length")
        try expect(subjectMatches("CN=Apple Inc., OU=Example, O=Apple Inc., C=US", .apple), "Apple subject")
        try expect(subjectMatches("cn=apple inc., o=x", .apple), "case-insensitive subject")
        try expect(
            subjectMatches(
                "CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation", .microsoftHardware),
            "Microsoft subject")
        for bad in [
            "CN=Apple Inc.", "CN=Apple Inc.X, O=x", "O=x, CN=Apple Inc.,", "CN=\"Apple Inc.,x\"",
            "CN=Evil, O=Apple Inc.,", "",
        ] {
            try expect(!subjectMatches(bad, .apple), "subject rejection")
        }
        try expect(!subjectMatches("CN=Apple Inc., O=x", .microsoftHardware), "publisher separation")
        Console.writeLine(
            "PASS: native SHA-256 and strict pinned-hash / signer-subject rules; no file or system setting changed")
    }
}
