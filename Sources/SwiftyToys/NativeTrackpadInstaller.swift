// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK
import WindowsDisplayABI

/// Elevated, cold driver work. Windows and signed upstream drivers own input processing.
enum NativeTrackpadInstaller {
    private static let usb = "USB\\VID_05AC&PID_0265&MI_01"
    private static let bluetooth = "BTHENUM\\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265"
    private static let openBluetooth = [
        "HID\\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265&Col01",
        "HID\\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265&Col02",
    ]
    private static var allowed: [String] { [usb, bluetooth] + openBluetooth }
    private struct Device { let instance: String; let ids: [String]; let inf: String; let problem: DWORD }
    private struct Binding { let id: String; let inf: String; let hash: String? }
    private struct Entry { let path: String; let directory: Bool; let time: UInt64 }
    private struct Session { let root: String; var stage: String?; var restart = false }
    private static func require(_ success: Bool, _ operation: String) throws {
        guard success else { throw WindowsError.api(operation, GetLastError()) }
    }
    private static func prefix(_ path: String, _ root: String) -> Bool {
        let count = root.utf16.count
        return path.utf16.count > count && equalWindowsNames(String(decoding: path.utf16.prefix(count + 1), as: UTF16.self), root + "\\")
    }
    private static func canonical(_ path: String) throws -> String {
        guard !path.isEmpty, !path.utf16.contains(0), !path.contains("\""), path.utf16.count < 32768 else {
            throw WindowsError.unsupported("Invalid driver storage path.")
        }
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = withWideString(path) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
        guard count > 0, count < buffer.count else { throw WindowsError.api("Resolve driver path", GetLastError()) }
        let result = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        guard result.utf16.count >= 3, result.dropFirst().hasPrefix(":\\"), !result.dropFirst(2).contains(":") else {
            throw WindowsError.unsupported("Driver storage requires a local drive path.")
        }
        return result.hasSuffix("\\") ? String(result.dropLast()) : result
    }
    private static func inspectComponents(_ path: String) throws {
        let parts = try canonical(path).split(separator: "\\")
        var current = String(parts[0]) + "\\"
        for part in parts.dropFirst() {
            current += (current.hasSuffix("\\") ? "" : "\\") + part
            let attributes = withWideString(current) { GetFileAttributesW($0) }
            if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
                let error = GetLastError()
                if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) { return }
                throw WindowsError.api("Inspect driver storage", error)
            }
            guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
                throw WindowsError.unsupported("Driver storage contains a reparse point.")
            }
        }
    }
    private static func ownerTrusted(_ handle: HANDLE, kind: SE_OBJECT_TYPE) throws {
        var owner: PSID?, security: PSECURITY_DESCRIPTOR?
        let status = GetSecurityInfo(handle, kind, DWORD(OWNER_SECURITY_INFORMATION), &owner, nil, nil, nil, &security)
        guard status == DWORD(ERROR_SUCCESS), let owner else { throw WindowsError.api("Read driver storage owner", status) }
        defer { _ = LocalFree(security) }
        var administrators: PSID?, system: PSID?
        try require(withWideString("S-1-5-32-544") { ConvertStringSidToSidW($0, &administrators) }, "Read administrator identity")
        defer { _ = LocalFree(administrators) }
        try require(withWideString("S-1-5-18") { ConvertStringSidToSidW($0, &system) }, "Read system identity")
        defer { _ = LocalFree(system) }
        guard IsValidSid(owner), EqualSid(owner, administrators) || EqualSid(owner, system) else {
            throw WindowsError.unsupported("Driver storage has an untrusted owner. Remove that storage manually before retrying.")
        }
    }
    private static func trustedFile(_ path: String, writeSecurity: Bool = false) throws -> OwnedHandle {
        try inspectComponents(path)
        let file = try OwnedHandle(withWideString(path) {
            CreateFileW($0, DWORD(READ_CONTROL) | (writeSecurity ? DWORD(WRITE_DAC | WRITE_OWNER) : 0), DWORD(FILE_SHARE_READ), nil,
                DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        })
        var info = BY_HANDLE_FILE_INFORMATION()
        try require(GetFileInformationByHandle(file.raw, &info), "Inspect driver storage handle")
        guard info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw WindowsError.unsupported("Driver storage contains a reparse point.") }
        try ownerTrusted(file.raw, kind: SE_FILE_OBJECT)
        return consume file
    }
    private static func withSecurity<Result: ~Copyable>(_ text: String = "O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;GRGX;;;BU)", _ body: (PSECURITY_DESCRIPTOR) throws -> Result) throws -> Result {
        var descriptor: PSECURITY_DESCRIPTOR?
        try require(withWideString(text) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }, "Create protected driver storage permissions")
        guard let descriptor else { throw WindowsError.unsupported("Driver storage permissions are unavailable.") }
        defer { _ = LocalFree(descriptor) }
        return try body(descriptor)
    }
    private static func protect(_ path: String, directory: Bool) throws {
        try inspectComponents(path)
        try withSecurity { descriptor in
            if directory, try !NativeFiles.exists(path) {
                var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
                try require(withWideString(path) { CreateDirectoryW($0, &attributes) }, "Create protected driver directory")
            }
            let file = try trustedFile(path, writeSecurity: true)
            var owner: PSID?, dacl: PACL?, present: WindowsBool = false, defaulted: WindowsBool = false
            try require(GetSecurityDescriptorOwner(descriptor, &owner, &defaulted), "Read protected driver owner")
            try require(GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) && present.boolValue, "Read protected driver permissions")
            let status = SetSecurityInfo(file.raw, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION) | DWORD(PROTECTED_DACL_SECURITY_INFORMATION), owner, nil, dacl, nil)
            guard status == DWORD(ERROR_SUCCESS) else { throw WindowsError.api("Protect driver storage", status) }
        }
    }
    private static func entries(_ directory: String, depth: Int = 0, recursive: Bool = true) throws -> [Entry] {
        guard depth <= 16 else { throw WindowsError.unsupported("Driver storage is too deeply nested.") }
        try inspectComponents(directory)
        var data = WIN32_FIND_DATAW()
        let search = withWideString(directory + "\\*") { FindFirstFileW($0, &data) }
        guard let search, search != INVALID_HANDLE_VALUE else {
            if GetLastError() == DWORD(ERROR_FILE_NOT_FOUND) { return [] }
            throw WindowsError.api("Read driver storage", GetLastError())
        }
        defer { FindClose(search) }
        var result: [Entry] = []
        repeat {
            let name = wideString(data.cFileName)
            if name != ".", name != ".." {
                guard !name.isEmpty, !name.contains(":"), !name.contains("/"), !name.contains("\\"), data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
                    throw WindowsError.unsupported("Invalid driver storage entry.")
                }
                let path = directory + "\\" + name
                let isDirectory = data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
                result.append(Entry(path: path, directory: isDirectory, time: UInt64(data.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(data.ftLastWriteTime.dwLowDateTime)))
                if isDirectory, recursive { result += try entries(path, depth: depth + 1) }
                guard result.count <= 16384 else { throw WindowsError.unsupported("Driver storage has too many files.") }
            }
        } while FindNextFileW(search, &data)
        guard GetLastError() == DWORD(ERROR_NO_MORE_FILES) else { throw WindowsError.api("Enumerate driver storage", GetLastError()) }
        return result
    }
    private static func folder(_ id: GUID) throws -> String {
        var id = id, path: PWSTR?
        let status = SHGetKnownFolderPath(&id, 0, nil, &path)
        guard status >= 0, let path else { throw WindowsError.status("Find driver storage folder", status) }
        defer { CoTaskMemFree(path) }
        var count = 0
        while count < 32768, path[count] != 0 { count += 1 }
        guard count < 32768 else { throw WindowsError.unsupported("Driver storage folder is too long.") }
        return try canonical(String(decoding: UnsafeBufferPointer(start: path, count: count), as: UTF16.self))
    }
    private static func guidName() throws -> String {
        var guid = GUID(), buffer = [WCHAR](repeating: 0, count: 40)
        guard CoCreateGuid(&guid) >= 0, StringFromGUID2(&guid, &buffer, Int32(buffer.count)) > 0 else { throw WindowsError.unsupported("Create driver staging identity.") }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self).filter { $0 != "{" && $0 != "}" && $0 != "-" }
    }
    private static func run(_ executable: String, arguments: [String]) throws -> DWORD {
        try inspectComponents(executable)
        var command = Array(([quoteArgument(executable)] + arguments.map(quoteArgument)).joined(separator: " ").utf16) + [0]
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        try require(withWideString(executable) { CreateProcessW($0, &command, nil, nil, false, DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &information) }, "Start native driver utility")
        let process = try OwnedHandle(information.hProcess), thread = try OwnedHandle(information.hThread)
        _ = thread.raw
        // Never kill a timed-out driver operation: it may still own Windows device state.
        let wait = WaitForSingleObject(process.raw, DWORD(INFINITE))
        guard wait == DWORD(WAIT_OBJECT_0) else { throw WindowsError.api("Wait for native driver utility", GetLastError()) }
        var code: DWORD = 0
        try require(GetExitCodeProcess(process.raw, &code), "Read native driver utility result")
        return code
    }
    private static func pnputil(_ arguments: [String], restart: inout Bool, export: Bool = false) throws {
        let code = try run(systemExecutable("pnputil.exe"), arguments: arguments)
        guard code == 0 || !export && code == 3010 else { throw WindowsError.api("Windows driver package operation", code) }
        restart = restart || code == 3010
    }
    private static func safeInfName(_ name: String, oemOnly: Bool = false) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".inf") else { return false }
        let stem = lower.dropLast(4)
        if oemOnly { return stem.hasPrefix("oem") && !stem.dropFirst(3).isEmpty && stem.dropFirst(3).utf8.allSatisfy { (48...57).contains($0) } }
        return !stem.isEmpty && stem.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
    }
    private static func targets(apple: Bool) -> [String] { apple ? [usb, bluetooth] : [usb] + openBluetooth }
    private static func match(_ device: Device, ids: [String]) -> String? {
        ids.first { id in prefix(device.instance, id) && device.ids.contains { equalWindowsNames($0, id) } }
    }
    private static func devices() throws -> [Device] {
        guard let list = SetupDiGetClassDevsW(nil, nil, nil, DWORD(DIGCF_PRESENT | DIGCF_ALLCLASSES)), list != INVALID_HANDLE_VALUE else { throw WindowsError.api("Enumerate trackpad devices", GetLastError()) }
        defer { SetupDiDestroyDeviceInfoList(list) }
        var result: [Device] = []
        for index in 0..<16384 {
            var device = SP_DEVINFO_DATA()
            device.cbSize = DWORD(MemoryLayout<SP_DEVINFO_DATA>.size)
            if !SetupDiEnumDeviceInfo(list, DWORD(index), &device) {
                guard GetLastError() == DWORD(ERROR_NO_MORE_ITEMS) else { throw WindowsError.api("Read trackpad device", GetLastError()) }
                return result
            }
            var instance = [WCHAR](repeating: 0, count: 4096)
            try require(SetupDiGetDeviceInstanceIdW(list, &device, &instance, DWORD(instance.count), nil), "Read trackpad instance")
            var ids = [WCHAR](repeating: 0, count: 8192), size: DWORD = 0, type: DWORD = 0
            let idRead = ids.withUnsafeMutableBytes { SetupDiGetDeviceRegistryPropertyW(list, &device, DWORD(SPDRP_HARDWAREID), &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count), &size) }
            var hardware: [String] = []
            if idRead {
                guard type == REG_MULTI_SZ || type == REG_SZ, size >= 2, size <= ids.count * 2, size % 2 == 0, ids[Int(size / 2) - 1] == 0 else { throw WindowsError.unsupported("Invalid device hardware identifiers.") }
                hardware = ids.prefix(Int(size / 2)).split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
            } else if GetLastError() != DWORD(ERROR_INVALID_DATA) { throw WindowsError.api("Read device hardware identifiers", GetLastError()) }
            // DEVPKEY_Device_DriverInfPath; construct the SDK value without an external UUID data import.
            var infKey = DEVPROPKEY(fmtid: GUID(Data1: 0xa8b865dd, Data2: 0x2e3d, Data3: 0x4094,
                Data4: (0xad, 0x97, 0xe5, 0x93, 0xa7, 0x0c, 0x75, 0xd6)), pid: 5)
            var inf = [WCHAR](repeating: 0, count: 512), propertyType: DEVPROPTYPE = 0
            let infRead = inf.withUnsafeMutableBytes { SetupDiGetDevicePropertyW(list, &device, &infKey, &propertyType, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count), &size, 0) }
            if infRead { guard propertyType == DEVPROP_TYPE_STRING, size >= 2, size <= inf.count * 2, size % 2 == 0, inf[Int(size / 2) - 1] == 0 else { throw WindowsError.unsupported("Invalid device driver identifier.") } }
            else if GetLastError() != DWORD(ERROR_NOT_FOUND) && GetLastError() != DWORD(ERROR_INVALID_DATA) { throw WindowsError.api("Read device driver binding", GetLastError()) }
            var status: ULONG = 0, problem: ULONG = 0
            guard CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == 0 else { throw WindowsError.unsupported("Windows device state is unavailable.") }
            result.append(Device(instance: String(decoding: instance.prefix(while: { $0 != 0 }), as: UTF16.self), ids: hardware, inf: infRead ? String(decoding: inf.prefix(while: { $0 != 0 }), as: UTF16.self) : "", problem: problem))
        }
        throw WindowsError.unsupported("The device list exceeds its safety limit.")
    }
    private typealias Bind = @convention(c) (HWND?, UnsafePointer<WCHAR>?, UnsafePointer<WCHAR>?, DWORD, UnsafeMutablePointer<WindowsBool>?) -> WindowsBool
    private static func bind(_ id: String, inf: String, restart: inout Bool) throws {
        guard allowed.contains(where: { equalWindowsNames($0, id) }), try NativeFiles.exists(inf) else { throw WindowsError.unsupported("Invalid trackpad hardware or missing recovery INF.") }
        guard let library = withWideString("newdev.dll", { LoadLibraryExW($0, nil, 0x800) }) else { throw WindowsError.api("Load native driver binding API", GetLastError()) }
        defer { FreeLibrary(library) }
        guard let address = GetProcAddress(library, "UpdateDriverForPlugAndPlayDevicesW") else { throw WindowsError.unsupported("Native driver binding API is unavailable.") }
        var reboot: WindowsBool = false
        let update = unsafeBitCast(address, to: Bind.self)
        try require(withWideString(id) { hardware in withWideString(inf) { update(nil, hardware, $0, 5, &reboot).boolValue } }, "Bind signed trackpad driver")
        restart = restart || reboot.boolValue
    }
    private static func download(host: String, path: String, destination: String) throws {
        guard let session = withWideString("SwiftyToys driver installer", { WinHttpOpen($0, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) }) else { throw WindowsError.api("Open HTTPS download", GetLastError()) }
        defer { WinHttpCloseHandle(session) }
        try require(WinHttpSetTimeouts(session, 10000, 10000, 30000, 30000), "Set HTTPS timeouts")
        var protocols = DWORD(WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2)
        try require(WinHttpSetOption(session, DWORD(WINHTTP_OPTION_SECURE_PROTOCOLS), &protocols, 4), "Require secure driver download")
        guard let connection = withWideString(host, { WinHttpConnect(session, $0, INTERNET_PORT(443), 0) }) else { throw WindowsError.api("Connect driver download", GetLastError()) }
        defer { WinHttpCloseHandle(connection) }
        guard let request = withWideString(path, { route in withWideString("GET") { WinHttpOpenRequest(connection, $0, route, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) } }) else { throw WindowsError.api("Open driver download request", GetLastError()) }
        defer { WinHttpCloseHandle(request) }
        try require(WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0), "Send driver download request")
        try require(WinHttpReceiveResponse(request, nil), "Receive driver download response")
        var status: DWORD = 0, size: DWORD = 4
        try require(WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &status, &size, nil), "Read driver download status")
        guard status == 200 else { throw WindowsError.unsupported("Driver download returned HTTP \(status).") }
        let file = try OwnedHandle(withWideString(destination) { CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil) })
        var buffer = [UInt8](repeating: 0, count: 65536), total: UInt64 = 0
        while true {
            var read: DWORD = 0, written: DWORD = 0
            try require(WinHttpReadData(request, &buffer, DWORD(buffer.count), &read), "Read driver download")
            if read == 0 { break }
            total += UInt64(read)
            guard read <= buffer.count, total <= 1_073_741_824 else { throw WindowsError.unsupported("Driver download exceeds its safety limit.") }
            try require(WriteFile(file.raw, buffer, read, &written, nil) && written == read, "Save driver download")
        }
        guard total > 0 else { throw WindowsError.unsupported("Driver download is empty.") }
        try require(FlushFileBuffers(file.raw), "Flush driver download")
    }
    private static func infCovers(_ text: String, id: String) -> Bool {
        text.split(whereSeparator: { $0.isNewline }).contains { line in
            line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0].split(separator: ",").dropFirst().contains {
                equalWindowsNames(String($0).trimmingWhitespace(), id)
            }
        }
    }
    private static func infText(_ path: String) throws -> String {
        let bytes = try NativeFiles.read(path, maximum: 4 * 1024 * 1024)
        if bytes.starts(with: [0xff, 0xfe]) {
            guard bytes.count % 2 == 0 else { throw WindowsError.unsupported("Invalid driver INF encoding.") }
            let words = stride(from: 2, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            guard let text = String(validating: words, as: UTF16.self) else { throw WindowsError.unsupported("Invalid driver INF encoding.") }
            return text
        }
        let content = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Array(bytes.dropFirst(3)) : bytes
        guard let text = String(validating: content, as: UTF8.self) else { throw WindowsError.unsupported("Invalid driver INF encoding.") }
        return text
    }
    private static func parent(_ path: String) -> String { path.split(separator: "\\").dropLast().joined(separator: "\\") }
    private static func filename(_ path: String) -> String { String(path.split(separator: "\\").last ?? "") }
    private static func digest(_ path: String) throws -> String {
        try NativeDriverTrust.sha256(ofFile: path).map { byte in let text = String(byte, radix: 16); return text.count == 1 ? "0" + text : text }.joined()
    }
    private static func verifyCatalog(_ inf: String) throws {
        let cats = try entries(parent(inf), recursive: false).filter { !$0.directory && filename($0.path).lowercased().hasSuffix(".cat") }
        guard cats.count == 1 else { throw WindowsError.unsupported("Driver catalog is missing or ambiguous.") }
        try NativeDriverTrust.verifySignature(cats[0].path, signer: .microsoftHardware)
    }
    private static func windowsInfDirectory() throws -> String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = GetWindowsDirectoryW(&buffer, UINT(buffer.count))
        guard count > 0, count < buffer.count else { throw WindowsError.api("Find Windows driver directory", GetLastError()) }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self) + "\\INF"
    }
    private struct RecoveryReader {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) throws {
            guard bytes.count < 32768 else { throw WindowsError.unsupported("Recovery file is too large.") }
            self.bytes = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Array(bytes.dropFirst(3)) : bytes
        }
        mutating func white() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { white(); if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false }
        mutating func need(_ byte: UInt8) throws { guard take(byte) else { throw WindowsError.unsupported("Invalid trackpad recovery JSON.") } }
        mutating func value() throws -> [UInt8] {
            white(); let start = index
            var stack: [UInt8] = [], quoted = false, escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 { stack.append(byte); guard stack.count <= 4 else { throw WindowsError.unsupported("Recovery JSON is too deeply nested.") } }
                else if byte == 125 || byte == 93 {
                    if stack.isEmpty { break }
                    guard stack.removeLast() == (byte == 125 ? 123 : 91) else { throw WindowsError.unsupported("Invalid recovery JSON brackets.") }
                } else if byte == 44, stack.isEmpty { break }
                else if byte == 58, stack.isEmpty { break }
                index += 1
            }
            guard index > start, !quoted, stack.isEmpty else { throw WindowsError.unsupported("Invalid trackpad recovery JSON value.") }
            return Array(bytes[start..<index])
        }
        mutating func fields() throws -> [String: [UInt8]] {
            try need(123); var result: [String: [UInt8]] = [:]
            if take(125) { return result }
            repeat {
                let raw = try value()
                guard let key = try StateJSON.decode(Array("{\"key\":".utf8) + raw + [125])["key"]?.string, result[key] == nil else { throw WindowsError.unsupported("Invalid or duplicate recovery JSON key.") }
                try need(58); result[key] = try value()
                if take(125) { break }
                try need(44)
            } while true
            white(); guard index == bytes.count else { throw WindowsError.unsupported("Unexpected recovery JSON data.") }
            return result
        }
        mutating func bindings() throws -> [Binding] {
            try need(91); var result: [Binding] = []
            if take(93) { return result }
            repeat {
                let fields = try StateJSON.decode(value())
                guard let id = fields["HardwareID"]?.string, let inf = fields["Inf"]?.string,
                    allowed.contains(where: { equalWindowsNames($0, id) }), !inf.isEmpty,
                    Set(fields.keys).isSubset(of: ["HardwareID", "Inf", "SHA256"]), result.count < 16 else { throw WindowsError.unsupported("Invalid recovery driver binding.") }
                let hash = fields["SHA256"]?.string
                if fields["SHA256"] != nil {
                    guard let hash, hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw WindowsError.unsupported("Invalid recovery driver hash.") }
                }
                result.append(Binding(id: id, inf: inf, hash: hash))
                if take(93) { break }
                try need(44)
            } while true
            white(); guard index == bytes.count else { throw WindowsError.unsupported("Unexpected recovery bindings data.") }
            return result
        }
    }
    private static func decodeRecovery(_ bytes: [UInt8]) throws -> [Binding] {
        var reader = try RecoveryReader(bytes)
        let fields = try reader.fields()
        guard Set(fields.keys) == ["Source", "Bindings"], let source = fields["Source"], let bindings = fields["Bindings"],
            let name = try StateJSON.decode(Array("{\"value\":".utf8) + source + [125])["value"]?.string, name == "Apple" || name == "Imbushuo"
        else { throw WindowsError.unsupported("Invalid trackpad recovery file.") }
        var list = try RecoveryReader(bindings)
        let result = try list.bindings()
        guard !result.isEmpty else { throw WindowsError.unsupported("Recovery file contains no driver bindings.") }
        return result
    }
    private static func encodeRecovery(_ bindings: [Binding], apple: Bool) -> [UInt8] {
        let members = bindings.map { binding -> String in
            var fields: [String: StateField] = ["HardwareID": .string(binding.id), "Inf": .string(binding.inf)]
            if let hash = binding.hash { fields["SHA256"] = .string(hash) }
            return String(decoding: StateJSON.encode(fields), as: UTF8.self)
        }.joined(separator: ",")
        let source = String(decoding: StateJSON.encode(["Source": .string(apple ? "Apple" : "Imbushuo")]), as: UTF8.self)
        return Array((source.dropLast() + ",\"Bindings\":[" + members + "]}").utf8)
    }
    private static func restore(_ bindings: [Binding], session: inout Session) throws {
        let windows = try windowsInfDirectory()
        var failures: [String] = []
        for binding in bindings {
            do {
                let inf = try canonical(binding.inf)
                guard prefix(inf, session.root) || equalWindowsNames(parent(inf), windows) && safeInfName(filename(inf)) else { throw WindowsError.unsupported("Recovery INF is outside protected backup or Windows INF storage.") }
                if prefix(inf, session.root) {
                    let file = try trustedFile(inf); _ = file.raw
                    if let hash = binding.hash { try NativeDriverTrust.verifyHash(inf, expected: hash) }
                    try verifyCatalog(inf)
                }
                try bind(binding.id, inf: inf, restart: &session.restart)
            } catch { failures.append(String(describing: error)) }
        }
        guard failures.isEmpty else { throw WindowsError.unsupported("Trackpad recovery failed: " + failures.joined(separator: "; ")) }
    }
    private static func utcTime() -> String {
        var value = SYSTEMTIME(); GetSystemTime(&value)
        func padded(_ number: WORD, _ width: Int = 2) -> String { let text = String(number); return String(repeating: "0", count: max(0, width - text.count)) + text }
        return "\(padded(value.wYear, 4))-\(padded(value.wMonth))-\(padded(value.wDay))T\(padded(value.wHour)):\(padded(value.wMinute)):\(padded(value.wSecond)).\(padded(value.wMilliseconds, 3))Z"
    }
    private static func saveResult(_ session: Session, status: String, message: String) throws {
        try NativeFiles.write(StateJSON.encode(["Status": .string(status), "Message": .string(message), "Stage": session.stage.map(StateField.string) ?? .null,
            "RestartRequired": .bool(session.restart), "TimeUtc": .string(utcTime())]), to: session.root + "\\last-result.json")
    }
    private static func isAppleComputer() throws -> Bool {
        var buffer = [WCHAR](repeating: 0, count: 512), size: DWORD = 1024
        let status = withWideString("HARDWARE\\DESCRIPTION\\System\\BIOS") { key in withWideString("SystemManufacturer") { name in
            buffer.withUnsafeMutableBytes { storage in RegGetValueW(HKEY_LOCAL_MACHINE, key, name, DWORD(RRF_RT_REG_SZ), nil, storage.baseAddress, &size) }
        } }
        guard status == ERROR_SUCCESS, size >= 2, size <= buffer.count * 2, size % 2 == 0 else { throw WindowsError.api("Read computer manufacturer", DWORD(status)) }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self).lowercased().containsText("apple")
    }
    private static func extractor() throws -> String {
        let directory = try folder(FOLDERID_ProgramFiles)
        for relative in ["7-Zip\\7z.exe", "WinRAR\\UnRAR.exe"] {
            let path = directory + "\\" + relative
            if try NativeFiles.exists(path) {
                let container = try trustedFile(parent(path)); _ = container.raw
                let executable = try trustedFile(path); _ = executable.raw
                return path
            }
        }
        throw WindowsError.unsupported("Apple uses a solid RAR archive. Install 7-Zip or WinRAR, or choose the open-source package.")
    }
    private static func prepare(apple: Bool, session: inout Session) throws -> [String] {
        if apple, try !isAppleComputer() { throw WindowsError.unsupported("Apple Boot Camp drivers are intended for Apple computers. Choose the open-source package on another PC.") }
        let tool = apple ? try extractor() : try systemExecutable("tar.exe")
        if apple { Console.writeLine("Downloading Boot Camp drivers from Apple. Apple licenses apply; Apple binaries are not distributed with SwiftyToys.") }
        else {
            Console.writeLine("Downloading mac-precision-touchpad 2105-3979. USB driver: GPLv2; source/license: https://github.com/imbushuo/mac-precision-touchpad")
            Console.writeLine("Upstream Bluetooth support is experimental and may cause input lag or system crashes. Apple is recommended for Bluetooth on Boot Camp.")
        }
        let stage = session.root + "\\" + utcTime().prefix(19).filter { $0 != ":" } + "-" + (try guidName())
        try protect(stage, directory: true); session.stage = stage
        let archive = stage + (apple ? "\\AppleBcUpdate.exe" : "\\upstream-package.zip"), drivers = stage + "\\drivers"
        try protect(drivers, directory: true)
        if apple {
            try download(host: "swcdn.apple.com", path: "/content/downloads/03/60/041-96205/61hhcnj7q5dxosc171ytixty20vuqg0r0n/AppleBcUpdate.exe", destination: archive)
            try NativeDriverTrust.verifyFile(archive, expected: "6219751446d0a481bda143e21bba367f5cd0a38560af2adb72d3c3350a43bae3", signer: .apple)
        } else {
            try download(host: "github.com", path: "/imbushuo/mac-precision-touchpad/releases/download/2105-3979/Drivers-amd64-ReleaseMSSigned.zip", destination: archive)
            try NativeDriverTrust.verifyHash(archive, expected: "cea0449aa773dbbb70abdfc787be99335dabbd2719588cebbb8806f397b4fad2")
        }
        let arguments = apple ? (equalWindowsNames(filename(tool), "7z.exe")
            ? ["x", "-y", "-o" + drivers, archive, "ApplePrecisionTrackpadUSB\\*", "ApplePrecisionTrackpadBluetooth\\*"]
            : ["x", "-y", archive, "ApplePrecisionTrackpadUSB\\*", "ApplePrecisionTrackpadBluetooth\\*", drivers + "\\"])
            : ["-xf", archive, "-C", drivers]
        guard try run(tool, arguments: arguments) == 0 else { throw WindowsError.unsupported("Driver archive extraction failed.") }
        let extracted = try entries(drivers)
        for item in extracted { let file = try trustedFile(item.path); _ = file.raw }
        let infs = extracted.filter { !$0.directory && filename($0.path).lowercased().hasSuffix(".inf") }.map(\.path)
        guard infs.count == (apple ? 2 : 1), !apple || Set(infs.map { filename($0).lowercased() }) == ["appleprecisiontrackpadusb.inf", "appleprecisiontrackpadbluetooth.inf"] else { throw WindowsError.unsupported("Unexpected upstream driver layout.") }
        for inf in infs { try verifyCatalog(inf) }
        return infs
    }
    private static func exportDriver(_ name: String, stage: String, restart: inout Bool) throws -> String {
        guard safeInfName(name, oemOnly: true) else { throw WindowsError.unsupported("Invalid previous driver package identifier.") }
        let original = try windowsInfDirectory() + "\\" + name
        let hash = try digest(original), destination = stage + "\\" + name
        if try !NativeFiles.exists(destination) {
            try protect(destination, directory: true)
            try pnputil(["/export-driver", name, destination], restart: &restart, export: true)
        }
        let files = try entries(destination)
        for item in files { let file = try trustedFile(item.path); _ = file.raw }
        let infs = try files.filter { !$0.directory && filename($0.path).lowercased().hasSuffix(".inf") }.map(\.path).filter { try digest($0) == hash }
        guard infs.count == 1 else { throw WindowsError.unsupported("Exported backup does not uniquely match the previous driver INF.") }
        try verifyCatalog(infs[0])
        return infs[0]
    }
    private static func selectBluetoothPackages(hash: String, installed: [(String, String)], devices: [Device]) throws -> [String] {
        let selected = installed.filter { safeInfName($0.0, oemOnly: true) && $0.1 == hash }.map(\.0)
        guard !selected.isEmpty else { throw WindowsError.unsupported("The verified Apple Bluetooth Precision package is not installed. Pair Bluetooth before installing its driver.") }
        for device in devices where selected.contains(where: { equalWindowsNames($0, device.inf) }) {
            guard prefix(device.instance, bluetooth), device.ids.contains(where: { equalWindowsNames($0, bluetooth) }) else {
                throw WindowsError.unsupported("Another connected device uses the Bluetooth package. Repair stopped to preserve its driver.")
            }
        }
        return selected
    }
    private static func repairBluetooth(_ infs: [String], devices: [Device], session: inout Session) throws -> String {
        let bluetoothInfs = infs.filter { equalWindowsNames(filename($0), "ApplePrecisionTrackpadBluetooth.inf") }
        guard bluetoothInfs.count == 1, let stage = session.stage else { throw WindowsError.unsupported("A unique verified Apple Bluetooth Precision INF is required.") }
        let hash = try digest(bluetoothInfs[0]), windows = try windowsInfDirectory()
        let packages = try entries(windows, recursive: false).filter { !$0.directory && safeInfName(filename($0.path), oemOnly: true) }.map { (filename($0.path), try digest($0.path)) }
        let selected = try selectBluetoothPackages(hash: hash, installed: packages, devices: devices)
        for name in selected { _ = try exportDriver(name, stage: stage, restart: &session.restart) }
        let next = "Restart Windows, pair the trackpad over Bluetooth WITHOUT USB, verify basic pointer input, then install the Apple Precision driver. Do not remove the pair afterward. USB support is retained. No restart is automatic."
        let record = String(decoding: StateJSON.encode(["NextStep": .string(next)]), as: UTF8.self)
        let packageNames = selected.map { "\"" + $0 + "\"" }.joined(separator: ",")
        try NativeFiles.write(Array((String(record.dropLast()) + ",\"Packages\":[" + packageNames + "]}").utf8), to: stage + "\\pairing-repair.json")
        do {
            for name in selected { try pnputil(["/delete-driver", name, "/uninstall"], restart: &session.restart) }
        } catch {
            do { try pnputil(["/add-driver", bluetoothInfs[0]], restart: &session.restart) }
            catch { throw WindowsError.unsupported("Bluetooth package removal failed, and restoring the staged package failed. Backups are retained.") }
            throw error
        }
        session.restart = true
        try saveResult(session, status: "PairingRepairPrepared", message: next)
        return next
    }
    private static func perform(_ action: String, session: inout Session) throws -> String {
        if action == "rollback" {
            let recoveries = try entries(session.root).filter { !$0.directory && equalWindowsNames(filename($0.path), "recovery.json") }.sorted { $0.time < $1.time }
            guard !recoveries.isEmpty, recoveries.count <= 64 else { throw WindowsError.unsupported("No valid recovery backup was found, or recovery history exceeds 64 installs.") }
            var original: [Binding] = []
            for recovery in recoveries {
                let file = try trustedFile(recovery.path); _ = file.raw
                for binding in try decodeRecovery(NativeFiles.read(recovery.path)) where !original.contains(where: { equalWindowsNames($0.id, binding.id) }) { original.append(binding) }
            }
            try restore(original, session: &session)
            let message = "Original trackpad driver bindings restored. Staged packages and recovery files are retained." + (session.restart ? " Windows requests a restart; no restart is automatic." : "")
            try saveResult(session, status: "Restored", message: message); return message
        }
        let apple = action == "apple" || action == "prepare-apple" || action == "repair-bluetooth"
        let snapshot = try devices(), ids = targets(apple: apple)
        let connected = snapshot.compactMap { device in match(device, ids: ids).map { (device, $0) } }
        if action == "repair-bluetooth", connected.contains(where: { equalWindowsNames($0.1, usb) }) { throw WindowsError.unsupported("Disconnect the trackpad USB cable before repairing Bluetooth pairing.") }
        guard action == "repair-bluetooth" || !connected.isEmpty else { throw WindowsError.unsupported("Connect a Lightning Magic Trackpad 2 (PID 0265) over USB, or pair it over Bluetooth first. Other models are not supported by this installer.") }
        let infs = try prepare(apple: apple, session: &session)
        if action == "repair-bluetooth" { return try repairBluetooth(infs, devices: snapshot, session: &session) }
        if action.hasPrefix("prepare-") {
            let message = "Pinned package hash and catalog signatures verified. No driver binding changed."
            try saveResult(session, status: "Prepared", message: message); return message
        }
        guard let stage = session.stage else { throw WindowsError.unsupported("Driver staging directory is unavailable.") }
        var bindings: [Binding] = [], assignments: [(Device, String, String)] = []
        let windows = try windowsInfDirectory()
        for (device, id) in connected {
            let matching = try infs.filter { try infCovers(infText($0), id: id) }
            guard matching.count == 1 else { throw WindowsError.unsupported("A unique signed INF must cover the connected trackpad hardware.") }
            let previous: String
            if safeInfName(device.inf, oemOnly: true) { previous = try exportDriver(device.inf, stage: stage, restart: &session.restart) }
            else if safeInfName(device.inf) { previous = windows + "\\" + device.inf; try inspectComponents(previous) }
            else { throw WindowsError.unsupported("Could not identify the previous driver for recovery.") }
            let binding = Binding(id: id, inf: previous, hash: try digest(previous))
            if let existing = bindings.first(where: { equalWindowsNames($0.id, id) }) {
                guard existing.hash == binding.hash else { throw WindowsError.unsupported("Identical trackpad hardware has different previous drivers. Installation stopped to preserve recovery.") }
            } else { bindings.append(binding) }
            assignments.append((device, id, matching[0]))
        }
        try NativeFiles.write(encodeRecovery(bindings, apple: apple), to: stage + "\\recovery.json")
        do {
            for inf in infs { try pnputil(["/add-driver", inf], restart: &session.restart) }
            for (device, id, inf) in assignments {
                try bind(id, inf: inf, restart: &session.restart)
                if !session.restart {
                    guard let current = try devices().first(where: { equalWindowsNames($0.instance, device.instance) }), current.problem == 0,
                        safeInfName(current.inf, oemOnly: true), try digest(windows + "\\" + current.inf) == digest(inf)
                    else { throw WindowsError.unsupported("Windows did not bind the expected signed trackpad INF, or the device reports a problem.") }
                }
            }
        } catch {
            let failure = String(describing: error)
            do { try restore(bindings, session: &session) }
            catch { throw WindowsError.unsupported(failure + "; " + String(describing: error)) }
            throw WindowsError.unsupported(failure)
        }
        let message = "Signed trackpad packages staged and connected device bindings applied. Verify USB and Bluetooth gestures separately." + (session.restart ? " Windows requests a restart; no restart is automatic." : "")
        try saveResult(session, status: "Installed", message: message)
        return message
    }
    static func runCLI(action: String) throws -> String {
        guard ["apple", "imbushuo", "rollback", "repair-bluetooth", "prepare-apple", "prepare-imbushuo"].contains(action) else { throw WindowsError.unsupported("Unknown native trackpad installation action.") }
        var administrators: PSID?, member: WindowsBool = false
        try require(withWideString("S-1-5-32-544") { ConvertStringSidToSidW($0, &administrators) }, "Read driver installation permission")
        defer { _ = LocalFree(administrators) }
        try require(CheckTokenMembership(nil, administrators, &member), "Check driver installation permission")
        guard member.boolValue, MemoryLayout<UnsafeRawPointer>.size == 8 else { throw WindowsError.unsupported("Run the native trackpad installer as administrator on 64-bit Windows.") }
        let lock = try withSecurity("O:BAG:BAD:P(A;;GA;;;BA)(A;;GA;;;SY)") { descriptor in
            var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
            return try OwnedHandle(withWideString("Global\\SwiftyToys.TrackpadInstaller") { CreateMutexW(&attributes, false, $0) })
        }
        try ownerTrusted(lock.raw, kind: SE_KERNEL_OBJECT)
        let wait = WaitForSingleObject(lock.raw, 0)
        if wait == DWORD(WAIT_TIMEOUT) { throw WindowsError.unsupported("Another SwiftyToys trackpad installer is running.") }
        guard wait == DWORD(WAIT_OBJECT_0) || wait == 0x80 else { throw WindowsError.api("Acquire driver installer lock", GetLastError()) }
        defer { ReleaseMutex(lock.raw) }
        let base = try folder(FOLDERID_ProgramData) + "\\SwiftyToys", root = base + "\\Trackpad"
        try protect(base, directory: true); try protect(root, directory: true)
        let stored = try entries(root)
        for item in stored { let file = try trustedFile(item.path); _ = file.raw }
        for item in stored { try protect(item.path, directory: item.directory) }
        var session = Session(root: root)
        do { return try perform(action, session: &session) }
        catch {
            let failure = String(describing: error)
            do { try saveResult(session, status: "Failed", message: failure) }
            catch { throw WindowsError.unsupported(failure + "; could not save the private driver result: " + String(describing: error)) }
            throw error
        }
    }
    static func selfCheck() throws {
        func expect(_ condition: Bool, _ name: String) throws { guard condition else { throw WindowsError.unsupported("Native trackpad check failed: " + name) } }
        for (text, count) in [("O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;GRGX;;;BU)", 3), ("O:BAG:BAD:P(A;;GA;;;BA)(A;;GA;;;SY)", 2)] {
            try withSecurity(text) { descriptor in
                var control: SECURITY_DESCRIPTOR_CONTROL = 0, revision: DWORD = 0, owner: PSID?, defaulted: WindowsBool = false, present: WindowsBool = false, dacl: PACL?
                try require(GetSecurityDescriptorControl(descriptor, &control, &revision), "Inspect fixture security descriptor")
                try require(GetSecurityDescriptorOwner(descriptor, &owner, &defaulted), "Inspect fixture security owner")
                try require(GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted), "Inspect fixture security ACL")
                var info = ACL_SIZE_INFORMATION()
                try require(GetAclInformation(dacl, &info, DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size), AclSizeInformation), "Inspect fixture ACL entries")
                try expect(control & SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED) != 0 && IsWellKnownSid(owner, WinBuiltinAdministratorsSid) && present.boolValue && info.AceCount == count, "protected admin-owned storage and administrator/system-only mutex descriptors")
            }
        }
        let own = Device(instance: bluetooth + "\\fixture", ids: [bluetooth], inf: "oem2.inf", problem: 0)
        let usbDevice = Device(instance: usb + "\\fixture", ids: [usb], inf: "oem6.inf", problem: 0)
        try expect(match(own, ids: targets(apple: true)) == bluetooth && match(usbDevice, ids: targets(apple: true)) == usb, "exact Apple transport selection")
        for id in ["USB\\VID_05AC&PID_0324&MI_01", usb + "0", "ROOT\\" + usb, "USB\\VID_05AC&PID_0265&MI_02"] {
            try expect(match(Device(instance: id + "\\fixture", ids: [id], inf: "oem9.inf", problem: 0), ids: targets(apple: true)) == nil, "unrelated hardware rejected")
        }
        let installed = [("oem6.inf", "USB"), ("oem2.inf", "BT"), ("oem0.inf", "RADIO"), ("..\\oem7.inf", "BT")]
        try expect(try selectBluetoothPackages(hash: "BT", installed: installed, devices: [own, usbDevice]) == ["oem2.inf"], "Bluetooth package only; USB and radio retained")
        for devices in [[Device(instance: "USB\\VID_05AC&PID_0277&MI_02\\fixture", ids: [], inf: "oem2.inf", problem: 0)], [Device(instance: usb + "\\fixture", ids: [usb], inf: "oem2.inf", problem: 0)]] {
            var blocked = false; do { _ = try selectBluetoothPackages(hash: "BT", installed: installed, devices: devices) } catch { blocked = true }
            try expect(blocked, "another device sharing the Bluetooth package is protected")
        }
        var missing = false; do { _ = try selectBluetoothPackages(hash: "missing", installed: installed, devices: []) } catch { missing = true }
        try expect(missing, "missing verified package rejected")
        try expect(infCovers("%Name%=Install, " + usb + " ; comment", id: usb) && !infCovers("; %Name%=Install," + usb, id: usb) && !infCovers("%Name%=Install," + usb + "0", id: usb), "exact INF hardware coverage")
        let binding = Binding(id: usb, inf: "C:\\fixture\\driver.inf", hash: String(repeating: "a", count: 64))
        let decoded = try decodeRecovery(encodeRecovery([binding], apple: true))
        try expect(decoded.count == 1 && decoded[0].id == binding.id && decoded[0].inf == binding.inf && decoded[0].hash == binding.hash, "recovery roundtrip")
        let legacy = encodeRecovery([Binding(id: bluetooth, inf: "C:\\fixture\\previous.inf", hash: nil)], apple: true)
        try expect(try decodeRecovery([0xef, 0xbb, 0xbf] + legacy).first?.hash == nil, "legacy BOM recovery retained")
        for bytes in [Array("{}".utf8), Array("{\"Source\":\"Apple\",\"Bindings\":[]}".utf8), legacy + [0], Array("{\"Source\":\"Apple\",\"Source\":\"Imbushuo\",\"Bindings\":[]}".utf8)] {
            var rejected = false; do { _ = try decodeRecovery(bytes) } catch { rejected = true }; try expect(rejected, "invalid recovery rejected")
        }
        try expect(prefix("C:\\trusted\\driver.inf", "C:\\trusted") && !prefix("C:\\trusted-other\\driver.inf", "C:\\trusted"), "recovery path boundary")
        try expect(try !prefix(canonical("C:\\trusted\\..\\outside\\driver.inf"), "C:\\trusted"), "recovery traversal boundary")
        var invalidPath = false; do { _ = try canonical("C:\\trusted\\driver.inf:payload") } catch { invalidPath = true }
        try expect(invalidPath, "alternate data stream rejected")
        try expect(safeInfName("oem42.inf", oemOnly: true) && !safeInfName("oem.inf", oemOnly: true) && !safeInfName("oem1.inf /force", oemOnly: true), "OEM package names")
        Console.writeLine("PASS: exact native trackpad/transport and INF selection, Bluetooth USB/radio/other-device guards, bounded legacy recovery and package names; no hardware or system state changed")
    }
}
