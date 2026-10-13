// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import BrightnessCore

/// Cold installation work; call on the installer's worker thread.
enum NativeInstaller {
    private struct Reference<T>: ~Copyable {
        let raw: UnsafeMutablePointer<T>
        init(_ pointer: UnsafeMutablePointer<T>?) throws {
            guard let pointer else { throw WindowsError.unsupported("Windows returned an empty installation interface.") }
            raw = pointer
        }
        deinit { raw.withMemoryRebound(to: IUnknown.self, capacity: 1) { _ = $0.pointee.lpVtbl.pointee.Release($0) } }
    }
    private struct Text: ~Copyable {
        let raw: BSTR
        init(_ text: String) throws {
            guard let value = withWideString(text, { SysAllocString($0) }) else { throw WindowsError.unsupported("Allocate installation string.") }
            raw = value
        }
        deinit { SysFreeString(raw) }
    }
    private struct LegacyTask { let path: String; let xml: String }
    private struct SavedTask { let xml: String; let enabled: VARIANT_BOOL }
    private struct SavedFile { let path: String; let backup: String? }
    private static func check(_ status: HRESULT, _ operation: String) throws {
        guard status >= 0 else { throw WindowsError.status(operation, status) }
    }
    private static func string(_ value: BSTR?) -> String {
        value.map { String(decoding: UnsafeBufferPointer(start: $0, count: Int(SysStringLen($0))), as: UTF16.self) } ?? ""
    }
    private static func folder(_ id: GUID) throws -> String {
        var id = id, value: PWSTR?
        try check(SHGetKnownFolderPath(&id, 0, nil, &value), "Find installation folder")
        defer { CoTaskMemFree(value) }
        guard let value else { throw WindowsError.unsupported("Windows returned an empty installation folder.") }
        var count = 0
        while count < 32768, value[count] != 0 { count += 1 }
        guard count < 32768 else { throw WindowsError.unsupported("Installation folder is too long.") }
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF16.self)
    }
    private static func canonical(_ path: String) throws -> String {
        guard !path.isEmpty, !path.utf16.contains(0), !path.contains("\""), path.utf16.count < 32768 else {
            throw WindowsError.unsupported("Invalid installation path.")
        }
        var path = path
        if path.hasPrefix("\\\\?\\") {
            path = String(path.dropFirst(4))
            guard path.utf16.count >= 3, path.dropFirst().hasPrefix(":\\") else {
                throw WindowsError.unsupported("Installation requires an extended local drive path.")
            }
        }
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = withWideString(path) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
        guard count > 0, count < buffer.count else { throw WindowsError.api("Resolve installation path", GetLastError()) }
        let result = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        guard result.utf16.count >= 3, result.dropFirst().hasPrefix(":\\"), !result.dropFirst(2).contains(":") else {
            throw WindowsError.unsupported("Installation requires a local drive path.")
        }
        return result.hasSuffix("\\") ? String(result.dropLast()) : result
    }
    /// Reject junctions/symlinks in every existing component before copying or replacing.
    private static func inspect(_ path: String, directory: Bool? = nil, required: Bool = true) throws {
        let path = try canonical(path)
        let parts = path.split(separator: "\\")
        var current = String(parts[0]) + "\\"
        for (index, part) in parts.dropFirst().enumerated() {
            current += (current.hasSuffix("\\") ? "" : "\\") + part
            let attributes = withWideString(try NativeFiles.windowsPath(current)) { GetFileAttributesW($0) }
            if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
                let error = GetLastError()
                guard !required, error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) else {
                    throw WindowsError.api("Inspect installation path", error)
                }
                return
            }
            guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw WindowsError.unsupported("Installation paths must not contain junctions or symbolic links.") }
            let isDirectory = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            if index < parts.count - 2 {
                guard isDirectory else { throw WindowsError.unsupported("Installation parent is not a directory.") }
            } else if let directory, directory != isDirectory { throw WindowsError.unsupported("Invalid installation file type.") }
        }
    }
    private static func makeDirectory(_ path: String) throws {
        try inspect(path, directory: true, required: false)
        try NativeFiles.createDirectory(path)
        try inspect(path, directory: true)
    }
    private static func entries(_ directory: String) throws -> [(String, DWORD)] {
        try inspect(directory, directory: true)
        var data = WIN32_FIND_DATAW()
        let search = withWideString(try NativeFiles.windowsPath(directory + "\\*")) { FindFirstFileW($0, &data) }
        guard let search, search != INVALID_HANDLE_VALUE else { throw WindowsError.api("Read installation files", GetLastError()) }
        defer { FindClose(search) }
        var result: [(String, DWORD)] = []
        repeat {
            let name = wideString(data.cFileName)
            if name != ".", name != ".." {
                guard !name.isEmpty, !name.contains(":"), !name.contains("\\"), !name.contains("/"),
                    data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0, result.count < 2048 else {
                    throw WindowsError.unsupported("Invalid installation payload entry.")
                }
                result.append((name, data.dwFileAttributes))
            }
        } while FindNextFileW(search, &data)
        guard GetLastError() == DWORD(ERROR_NO_MORE_FILES) else { throw WindowsError.api("Enumerate installation files", GetLastError()) }
        return result.sorted { $0.0 < $1.0 }
    }
    private static func payload(_ source: String) throws -> [String] {
        try inspect(source, directory: true)
        var files = ["SwiftyToys.exe", "runtime-files.txt", "swift-version.txt", "README.md", "CHANGELOG.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "resources\\SwiftyToys.ico", "resources\\SwiftyToys.svg"]
        func collect(_ relative: String, depth: Int) throws {
            guard depth <= 4 else { throw WindowsError.unsupported("Installation payload is too deeply nested.") }
            for (name, attributes) in try entries(source + "\\" + relative) {
                let path = relative + "\\" + name
                if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { try collect(path, depth: depth + 1) }
                else {
                    let lower = name.lowercased()
                    let valid = relative == "Languages" ? lower.hasSuffix(".json") :
                        relative == "Licenses" ? lower.hasSuffix(".txt") :
                        relative == "docs" || relative.hasPrefix("docs\\") ? lower.hasSuffix(".md") || lower.hasSuffix(".png") || lower.hasSuffix(".svg") : false
                    guard valid, files.count < 4096 else { throw WindowsError.unsupported("Unexpected installation payload file.") }
                    files.append(path)
                }
            }
        }
        for directory in ["Languages", "Licenses", "docs"] { try collect(directory, depth: 0) }
        let required = ["Languages\\en-US.json", "Languages\\ru-RU.json",
            "Licenses\\Dispatch.txt", "Licenses\\Foundation.txt", "Licenses\\FoundationICU.txt",
            "Licenses\\SwiftFoundation.txt", "Licenses\\SwiftFoundation-NOTICE.txt", "Licenses\\Swift.txt",
            "Licenses\\ModernFlyouts.txt", "Licenses\\ICU.txt", "docs\\Guide.md", "docs\\Design.md",
            "docs\\DriverVerification.md", "docs\\Localization.md", "docs\\WindowsInterop.md", "docs\\Validation.md",
            "docs\\Trackpad.md", "docs\\RuntimeArchitecture.md", "docs\\Requirements.md", "docs\\Performance.md",
            "docs\\Packaging.md", "docs\\images\\overview.svg"]
        guard required.allSatisfy(files.contains) else {
            throw WindowsError.unsupported("Extract the complete SwiftyToys release before installing.")
        }
        for file in files {
            let path = source + "\\" + file
            try inspect(path, directory: false)
            if file != "SwiftyToys.exe", file != "runtime-files.txt" {
                let bytes = try NativeFiles.read(path, maximum: 4 * 1024 * 1024)
                guard !bytes.isEmpty else { throw WindowsError.unsupported("Installation payload file is empty: " + file) }
                if file.hasPrefix("Languages\\") {
                    let pack = try LanguagePack(bytes: bytes)
                    guard equalWindowsNames(file, "Languages\\" + pack.locale + ".json") else {
                        throw WindowsError.unsupported("Installation language pack does not match its locale.")
                    }
                }
            }
        }
        let icon = withWideString(try NativeFiles.windowsPath(source + "\\resources\\SwiftyToys.ico")) {
            LoadImageW(nil, $0, UINT(IMAGE_ICON), 32, 32, UINT(LR_LOADFROMFILE))
        }
        guard let icon else { throw WindowsError.api("Validate installation icon", GetLastError()) }
        DestroyIcon(icon.assumingMemoryBound(to: HICON__.self))
        guard try NativeFiles.read(source + "\\runtime-files.txt", maximum: 4096).isEmpty else {
            throw WindowsError.unsupported("This installer requires the complete static-runtime release.")
        }
        let executable = try NativeFiles.read(source + "\\SwiftyToys.exe", maximum: 16 * 1024 * 1024)
        guard executable.count >= 64, executable[0] == 0x4d, executable[1] == 0x5a else { throw WindowsError.unsupported("Invalid installation executable.") }
        let pe = Int(executable[60]) | Int(executable[61]) << 8 | Int(executable[62]) << 16 | Int(executable[63]) << 24
        guard pe >= 64, pe <= executable.count - 6, Array(executable[pe..<pe + 6]) == [0x50, 0x45, 0, 0, 0x64, 0x86] else {
            throw WindowsError.unsupported("Installation executable must be a Windows x64 image.")
        }
        for name in ["vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"] {
            guard try NativeFiles.exists(systemExecutable(name)) else { throw WindowsError.unsupported("Install Microsoft Visual C++ 2015–2022 x64 Redistributable, then retry: https://aka.ms/vs/17/release/vc_redist.x64.exe") }
        }
        return files
    }
    private static func copy(_ source: String, _ destination: String) throws {
        try inspect(source, directory: false)
        try inspect(destination, directory: false, required: false)
        var guid = GUID(), name = [WCHAR](repeating: 0, count: 40)
        try check(CoCreateGuid(&guid), "Create installation copy name")
        guard StringFromGUID2(&guid, &name, Int32(name.count)) > 0 else { throw WindowsError.unsupported("Encode installation copy name.") }
        let temporary = destination + "." + String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self) + ".tmp"
        let originalPath = try NativeFiles.windowsPath(source), temporaryPath = try NativeFiles.windowsPath(temporary), destinationPath = try NativeFiles.windowsPath(destination)
        guard withWideString(originalPath, { original in withWideString(temporaryPath) { CopyFileW(original, $0, true) } }) else { throw WindowsError.api("Copy installation file", GetLastError()) }
        defer { try? NativeFiles.remove(temporary) }
        do {
            let output = try OwnedHandle(withWideString(temporaryPath) { CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil) })
            guard FlushFileBuffers(output.raw) else { throw WindowsError.api("Flush installation copy", GetLastError()) }
        }
        try inspect(destination, directory: false, required: false)
        guard withWideString(temporaryPath, { original in withWideString(destinationPath) { MoveFileExW(original, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) } }) else {
            throw WindowsError.api("Replace installation file", GetLastError())
        }
    }
    private static func processPath(_ id: DWORD) throws -> String? {
        let raw = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE), false, id)
        guard let raw else {
            if GetLastError() == DWORD(ERROR_INVALID_PARAMETER) { return nil }
            throw WindowsError.api("Inspect existing SwiftyToys process", GetLastError())
        }
        let process = try OwnedHandle(raw)
        if WaitForSingleObject(process.raw,0)==DWORD(WAIT_OBJECT_0) { return nil }
        var buffer = [WCHAR](repeating: 0, count: 32768), count = DWORD(32768)
        guard QueryFullProcessImageNameW(process.raw, 0, &buffer, &count) else {
            let error=GetLastError()
            // A snapshot can outlive a process; only a signaled handle proves it has exited.
            if WaitForSingleObject(process.raw,0)==DWORD(WAIT_OBJECT_0) { return nil }
            throw WindowsError.api("Read existing SwiftyToys process path",error)
        }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }
    private static func remaining(_ executable: String, session: DWORD) throws -> Bool {
        let snapshot = try OwnedHandle(CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0))
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot.raw, &entry) else {
            if GetLastError() == DWORD(ERROR_NO_MORE_FILES) { return false }
            throw WindowsError.api("Read running installation processes", GetLastError())
        }
        let name = String(executable.split(separator: "\\").last ?? "")
        repeat {
            if entry.th32ProcessID != GetCurrentProcessId(), equalWindowsNames(wideString(entry.szExeFile), name) {
                var foundSession: DWORD = 0
                guard ProcessIdToSessionId(entry.th32ProcessID, &foundSession) else {
                    if GetLastError() == DWORD(ERROR_INVALID_PARAMETER) { continue }
                    throw WindowsError.api("Read existing process session", GetLastError())
                }
                if foundSession == session, let path = try processPath(entry.th32ProcessID), equalWindowsNames(path, executable) { return true }
            }
        } while Process32NextW(snapshot.raw, &entry)
        guard GetLastError() == DWORD(ERROR_NO_MORE_FILES) else { throw WindowsError.api("Enumerate existing processes", GetLastError()) }
        return false
    }
    private static func launch(_ executable: String, arguments: String, wait: Bool) throws {
        try inspect(executable, directory: false)
        var command = Array(("\"" + executable + "\"" + (arguments.isEmpty ? "" : " " + arguments)).utf16) + [0]
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        guard withWideString(executable, { CreateProcessW($0, &command, nil, nil, false, DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &information) }) else {
            throw WindowsError.api("Start installation process", GetLastError())
        }
        let process = try OwnedHandle(information.hProcess), thread = try OwnedHandle(information.hThread)
        _ = thread.raw
        if wait {
            let result = WaitForSingleObject(process.raw, 15000)
            guard result == DWORD(WAIT_OBJECT_0) else { throw WindowsError.unsupported("The previous resident is still restoring its display. Wait and retry; do not kill its watchdog.") }
        }
    }
    private static func stop(_ executable: String, session: DWORD) throws {
        guard try NativeFiles.exists(executable) else { return }
        let deadline = GetTickCount64() + 15000
        try launch(executable, arguments: "exit", wait: true)
        while try remaining(executable, session: session) {
            guard GetTickCount64() < deadline else { throw WindowsError.unsupported("The previous resident or watchdog is still restoring its display. Wait and retry; recovery leases have been retained.") }
            Sleep(100)
        }
    }
    private static func currentSID() throws -> String {
        var raw: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &raw) else { throw WindowsError.api("Read installation user", GetLastError()) }
        let token = try OwnedHandle(raw)
        var size: DWORD = 0
        _ = GetTokenInformation(token.raw, TokenUser, nil, 0, &size)
        guard size >= MemoryLayout<TOKEN_USER>.size, size <= 65536 else { throw WindowsError.unsupported("Invalid installation user token.") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token.raw, TokenUser, buffer, size, &size) else { throw WindowsError.api("Read installation user SID", GetLastError()) }
        var text: PWSTR?
        guard ConvertSidToStringSidW(buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid, &text), let text else { throw WindowsError.api("Encode installation user SID", GetLastError()) }
        defer { _ = LocalFree(text) }
        var count = 0
        while count < 256, text[count] != 0 { count += 1 }
        guard count < 256 else { throw WindowsError.unsupported("Invalid installation user SID.") }
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF16.self)
    }
    private static func userMatches(_ user: String, sid: String) -> Bool {
        if equalWindowsNames(user, sid) { return true }
        var size: DWORD = 0, domainSize: DWORD = 0, use = SidTypeUser
        _ = withWideString(user) { LookupAccountNameW(nil, $0, nil, &size, nil, &domainSize, &use) }
        guard size > 0, size <= 65536, domainSize <= 32768 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        var domain = [WCHAR](repeating: 0, count: Int(domainSize)), text: PWSTR?
        guard withWideString(user, { LookupAccountNameW(nil, $0, buffer, &size, &domain, &domainSize, &use) }),
            use == SidTypeUser, ConvertSidToStringSidW(buffer, &text), let text else { return false }
        defer { _ = LocalFree(text) }
        var count = 0
        while count < 256, text[count] != 0 { count += 1 }
        return count < 256 && equalWindowsNames(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF16.self), sid)
    }
    private static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private static func readRun(_ name: String) throws -> String? {
        var size: DWORD = 0
        let status = withWideString(runKey) { key in withWideString(name) { RegGetValueW(HKEY_CURRENT_USER, key, $0, DWORD(RRF_RT_REG_SZ), nil, nil, &size) } }
        if status == ERROR_FILE_NOT_FOUND { return nil }
        guard status == ERROR_SUCCESS, size >= 2, size <= 65536, size % 2 == 0 else { throw WindowsError.unsupported("Invalid previous startup registry value.") }
        var buffer = [WCHAR](repeating: 0, count: Int(size) / 2)
        let read = withWideString(runKey) { key in withWideString(name) { RegGetValueW(HKEY_CURRENT_USER, key, $0, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) } }
        guard read == ERROR_SUCCESS, buffer.last == 0 else { throw WindowsError.api("Read previous startup registry value", DWORD(read)) }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
    private static func writeRun(_ name: String, value: String?) throws {
        var key: HKEY?
        let opened = withWideString(runKey) { RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, REGSAM(KEY_SET_VALUE), nil, &key, nil) }
        guard opened == ERROR_SUCCESS, let key else { throw WindowsError.api("Open startup registry", DWORD(opened)) }
        defer { RegCloseKey(key) }
        let status: LSTATUS
        if let value {
            let words = Array(value.utf16) + [0]
            status = withWideString(name) { name in words.withUnsafeBytes { RegSetValueExW(key, name, 0, DWORD(REG_SZ), $0.baseAddress!.assumingMemoryBound(to: BYTE.self), DWORD($0.count)) } }
        } else { status = withWideString(name) { RegDeleteValueW(key, $0) } }
        guard status == ERROR_SUCCESS || value == nil && status == ERROR_FILE_NOT_FOUND else { throw WindowsError.api("Update startup registry", DWORD(status)) }
    }
    private static func xml(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character { case "&": result += "&amp;"; case "<": result += "&lt;"; case ">": result += "&gt;"; case "\"": result += "&quot;"; case "'": result += "&apos;"; default: result.append(character) }
        }
        return result
    }
    private static func runtimeName(_ name: String) -> Bool {
        name.hasSuffix(".dll") && ["swift", "Foundation", "_Foundation", "BlocksRuntime", "dispatch"].contains(where: name.hasPrefix)
            && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 || $0 == 46 }
    }
    private static func unquoted(_ value: String) -> String {
        var value = value[...]
        while value.first == "\"" { value = value.dropFirst() }
        while value.last == "\"" { value = value.dropLast() }
        return String(value)
    }
    private static func mayRestoreFiles(residentRunning: Bool, acquiredMutex: Bool) -> Bool {
        !residentRunning && acquiredMutex
    }
    private static func legacyBackupName(_ path: String) throws -> String {
        var remaining = Array(path.utf8)[...]
        let digest = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, remaining.count)
            buffer.copyBytes(from: remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            return count
        }
        return digest.map { let text = String($0, radix: 16); return $0 < 16 ? "0" + text : text }.joined() + ".xml"
    }
    private static func taskXML(executable: String, directory: String, sid: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        <RegistrationInfo><Description>SwiftyToys: native Swift brightness and Mac keyboard tools</Description></RegistrationInfo>
        <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>\(xml(sid))</UserId><Delay>PT20S</Delay></LogonTrigger></Triggers>
        <Principals><Principal id="Author"><UserId>\(xml(sid))</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
        <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>false</Enabled><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>4</Priority></Settings>
        <Actions Context="Author"><Exec><Command>\(xml(executable))</Command><WorkingDirectory>\(xml(directory))</WorkingDirectory></Exec></Actions>
        </Task>
        """
    }
    private static func owned(_ task: UnsafeMutablePointer<IRegisteredTask>, executable: String, sid: String) throws -> Bool {
        var definitionPointer: UnsafeMutablePointer<ITaskDefinition>?
        try check(task.pointee.lpVtbl.pointee.get_Definition(task, &definitionPointer), "Read previous startup definition")
        let definition = try Reference(definitionPointer)
        var principalPointer: UnsafeMutablePointer<IPrincipal>?
        try check(definition.raw.pointee.lpVtbl.pointee.get_Principal(definition.raw, &principalPointer), "Read previous startup user")
        let principal = try Reference(principalPointer)
        var user: BSTR?
        defer { SysFreeString(user) }
        try check(principal.raw.pointee.lpVtbl.pointee.get_UserId(principal.raw, &user), "Read previous startup identity")
        guard userMatches(string(user), sid: sid) else { return false }
        var actionsPointer: UnsafeMutablePointer<IActionCollection>?
        try check(definition.raw.pointee.lpVtbl.pointee.get_Actions(definition.raw, &actionsPointer), "Read previous startup actions")
        let actions = try Reference(actionsPointer)
        var count: LONG = 0
        try check(actions.raw.pointee.lpVtbl.pointee.get_Count(actions.raw, &count), "Count previous startup actions")
        guard count == 1 else { return false }
        var actionPointer: UnsafeMutablePointer<IAction>?
        try check(actions.raw.pointee.lpVtbl.pointee.get_Item(actions.raw, 1, &actionPointer), "Read previous startup action")
        let action = try Reference(actionPointer)
        var actionType = TASK_ACTION_EXEC
        try check(action.raw.pointee.lpVtbl.pointee.get_Type(action.raw, &actionType), "Read previous startup action type")
        guard actionType == TASK_ACTION_EXEC else { return false }
        var id = GUID(Data1: 0x4c3d624d, Data2: 0xfd6b, Data3: 0x49a3, Data4: (0xb9,0xb7,0x09,0xcb,0x3c,0xd3,0xf0,0x47)), object: UnsafeMutableRawPointer?
        try check(action.raw.pointee.lpVtbl.pointee.QueryInterface(action.raw, &id, &object), "Read previous startup executable")
        let exec = try Reference(object?.assumingMemoryBound(to: IExecAction.self))
        var path: BSTR?
        defer { SysFreeString(path) }
        try check(exec.raw.pointee.lpVtbl.pointee.get_Path(exec.raw, &path), "Read previous startup executable path")
        guard let normalized = try? canonical(string(path)) else { return false }
        return equalWindowsNames(normalized, executable)
    }
    private static func legacyTasks(_ folder: UnsafeMutablePointer<ITaskFolder>, executable: String, sid: String, depth: Int = 0) throws -> [LegacyTask] {
        guard depth <= 32 else { throw WindowsError.unsupported("Task Scheduler folder tree is too deep.") }
        var result: [LegacyTask] = [], collectionPointer: UnsafeMutablePointer<IRegisteredTaskCollection>?
        try check(folder.pointee.lpVtbl.pointee.GetTasks(folder, LONG(TASK_ENUM_HIDDEN.rawValue), &collectionPointer), "Inspect previous startup tasks")
        let collection = try Reference(collectionPointer)
        var count: LONG = 0
        try check(collection.raw.pointee.lpVtbl.pointee.get_Count(collection.raw, &count), "Count previous startup tasks")
        guard (0...16384).contains(count) else { throw WindowsError.unsupported("Invalid startup task count.") }
        for index in 0..<count {
            var item = VARIANT(), pointer: UnsafeMutablePointer<IRegisteredTask>?
            item.vt = VARTYPE(VT_I4.rawValue); item.lVal = index + 1
            try check(collection.raw.pointee.lpVtbl.pointee.get_Item(collection.raw, item, &pointer), "Inspect previous startup task")
            let task = try Reference(pointer)
            var name: BSTR?, path: BSTR?, taskXML: BSTR?
            defer { SysFreeString(name); SysFreeString(path); SysFreeString(taskXML) }
            try check(task.raw.pointee.lpVtbl.pointee.get_Name(task.raw, &name), "Read previous startup task name")
            let taskName = string(name)
            guard taskName.lowercased().hasPrefix("brightnessctl"), try owned(task.raw, executable: executable, sid: sid) else { continue }
            try check(task.raw.pointee.lpVtbl.pointee.get_Path(task.raw, &path), "Read previous startup task path")
            try check(task.raw.pointee.lpVtbl.pointee.get_Xml(task.raw, &taskXML), "Back up previous startup task")
            result.append(LegacyTask(path: string(path), xml: string(taskXML)))
        }
        var foldersPointer: UnsafeMutablePointer<ITaskFolderCollection>?
        try check(folder.pointee.lpVtbl.pointee.GetFolders(folder, 0, &foldersPointer), "Inspect startup task folders")
        let folders = try Reference(foldersPointer)
        try check(folders.raw.pointee.lpVtbl.pointee.get_Count(folders.raw, &count), "Count startup task folders")
        guard (0...16384).contains(count) else { throw WindowsError.unsupported("Invalid startup task folder count.") }
        for index in 0..<count {
            var item = VARIANT(), pointer: UnsafeMutablePointer<ITaskFolder>?
            item.vt = VARTYPE(VT_I4.rawValue); item.lVal = index + 1
            try check(folders.raw.pointee.lpVtbl.pointee.get_Item(folders.raw, item, &pointer), "Read startup task folder")
            let child = try Reference(pointer)
            result += try legacyTasks(child.raw, executable: executable, sid: sid, depth: depth + 1)
        }
        return result
    }
    private static func shortcut(path: String, executable: String, directory: String, icon: String) throws {
        var classID = CLSID_ShellLink, interfaceID = IID_IShellLinkW, object: UnsafeMutableRawPointer?
        try check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &interfaceID, &object), "Create settings shortcut")
        let link = try Reference(object?.assumingMemoryBound(to: IShellLinkW.self))
        try check(withWideString(executable) { link.raw.pointee.lpVtbl.pointee.SetPath(link.raw, $0) }, "Set settings shortcut executable")
        try check(withWideString("settings") { link.raw.pointee.lpVtbl.pointee.SetArguments(link.raw, $0) }, "Set settings shortcut command")
        try check(withWideString(directory) { link.raw.pointee.lpVtbl.pointee.SetWorkingDirectory(link.raw, $0) }, "Set settings shortcut directory")
        try check(withWideString("SwiftyToys settings: brightness, Mac keyboard habits, desktop tools and Homebrew") { link.raw.pointee.lpVtbl.pointee.SetDescription(link.raw, $0) }, "Set settings shortcut description")
        try check(withWideString(icon) { link.raw.pointee.lpVtbl.pointee.SetIconLocation(link.raw, $0, 0) }, "Set settings shortcut icon")
        interfaceID = IID_IPersistFile; object = nil
        try check(link.raw.pointee.lpVtbl.pointee.QueryInterface(link.raw, &interfaceID, &object), "Open settings shortcut storage")
        let file = try Reference(object?.assumingMemoryBound(to: IPersistFile.self))
        var guid = GUID(), name = [WCHAR](repeating: 0, count: 40)
        try check(CoCreateGuid(&guid), "Create staged shortcut name")
        guard StringFromGUID2(&guid, &name, Int32(name.count)) > 0 else { throw WindowsError.unsupported("Encode staged shortcut name.") }
        let temporary = path + "." + String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self) + ".lnk"
        guard temporary.utf16.count < MAX_PATH else { throw WindowsError.unsupported("Start menu shortcut path is too long.") }
        defer { try? NativeFiles.remove(temporary) }
        try check(withWideString(temporary) { file.raw.pointee.lpVtbl.pointee.Save(file.raw, $0, true) }, "Stage settings shortcut")
        try ShellIntegration.configureShortcut(path: temporary, iconPath: icon)
        try inspect(path, directory: false, required: false)
        let temporaryPath = try NativeFiles.windowsPath(temporary), destinationPath = try NativeFiles.windowsPath(path)
        guard withWideString(temporaryPath, { staged in withWideString(destinationPath) { MoveFileExW(staged, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) } }) else {
            throw WindowsError.api("Commit settings shortcut", GetLastError())
        }
        try ShellIntegration.refreshIcons(paths: [path, executable, icon])
    }
    static func install(from sourceDirectory: String, progress: @Sendable (String) -> Void) throws -> String {
        progress("Checking the complete installation package…")
        let source = try canonical(sourceDirectory), files = try payload(source)
        let directory = try canonical(folder(FOLDERID_LocalAppData) + "\\SwiftyToys")
        let legacyDirectory = try canonical(folder(FOLDERID_LocalAppData) + "\\BrightnessCtl")
        let executable = directory + "\\SwiftyToys.exe", legacyExecutable = legacyDirectory + "\\BrightnessCtl.exe"
        guard !equalWindowsNames(source, directory), !source.lowercased().hasPrefix(directory.lowercased() + "\\"),
            directory.utf16.count + 30 < MAX_PATH else { throw WindowsError.unsupported("Extract the installer outside the installed application folder.") }
        try inspect(directory, directory: true, required: false)
        try inspect(legacyDirectory, directory: true, required: false)
        let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        try check(initialized, "Initialize native installer COM")
        defer { CoUninitialize() }
        let sid = try currentSID(), taskName = "SwiftyToys-" + sid
        let installationMutex = try OwnedHandle(withWideString("Local\\SwiftyToys.Install-" + sid) { CreateMutexW(nil, false, $0) })
        let acquired = WaitForSingleObject(installationMutex.raw, 0)
        guard acquired == DWORD(WAIT_OBJECT_0) || acquired == 0x80 else { throw WindowsError.unsupported("Another SwiftyToys installation is running. Close it and retry.") }
        defer { ReleaseMutex(installationMutex.raw) }
        var session: DWORD = 0
        guard ProcessIdToSessionId(GetCurrentProcessId(), &session) else { throw WindowsError.api("Read installer session", GetLastError()) }
        var classID = GUID(Data1: 0x0f87369f, Data2: 0xa4e5, Data3: 0x4cfc, Data4: (0xbd,0x3e,0x73,0xe6,0x15,0x45,0x72,0xdd))
        var serviceID = GUID(Data1: 0x2faba4c7, Data2: 0x4da9, Data3: 0x4013, Data4: (0x96,0x97,0x20,0xcc,0x3f,0xd4,0x0f,0x85)), object: UnsafeMutableRawPointer?
        try check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &serviceID, &object), "Open native Task Scheduler")
        let service = try Reference(object?.assumingMemoryBound(to: ITaskService.self)), empty = VARIANT()
        try check(service.raw.pointee.lpVtbl.pointee.Connect(service.raw, empty, empty, empty, empty), "Connect native Task Scheduler")
        let rootName = try Text("\\")
        var rootPointer: UnsafeMutablePointer<ITaskFolder>?
        try check(service.raw.pointee.lpVtbl.pointee.GetFolder(service.raw, rootName.raw, &rootPointer), "Open startup task folder")
        let root = try Reference(rootPointer)
        let startupName = try Text(taskName)
        var previousTaskPointer: UnsafeMutablePointer<IRegisteredTask>?
        var previousTask: SavedTask?
        let previousTaskStatus = root.raw.pointee.lpVtbl.pointee.GetTask(root.raw, startupName.raw, &previousTaskPointer)
        if previousTaskStatus >= 0 {
            let previous = try Reference(previousTaskPointer)
            guard try owned(previous.raw, executable: executable, sid: sid) else {
                throw WindowsError.unsupported("The startup task name belongs to a different application or user. It has been retained.")
            }
            var previousXML: BSTR?, enabled: VARIANT_BOOL = 0
            defer { SysFreeString(previousXML) }
            try check(previous.raw.pointee.lpVtbl.pointee.get_Xml(previous.raw, &previousXML), "Back up current startup task")
            try check(previous.raw.pointee.lpVtbl.pointee.get_Enabled(previous.raw, &enabled), "Back up current startup task state")
            previousTask = SavedTask(xml: string(previousXML), enabled: enabled)
        } else if previousTaskStatus != HRESULT(bitPattern: 0x80070002) {
            throw WindowsError.status("Inspect existing startup task", previousTaskStatus)
        }
        let hasLegacy = try NativeFiles.exists(legacyExecutable)
        let legacy = hasLegacy ? try legacyTasks(root.raw, executable: legacyExecutable, sid: sid) : []
        let legacyRun = hasLegacy ? try readRun("BrightnessCtl") : nil
        let previousRun = try readRun("SwiftyToys")
        let previousResidentRunning = try remaining(executable, session: session)
        let previousLegacyRunning = hasLegacy ? try remaining(legacyExecutable, session: session) : false
        let programs = try folder(FOLDERID_Programs), shortcutPath = programs + "\\SwiftyToys.lnk", icon = directory + "\\resources\\SwiftyToys.ico"
        try inspect(programs, directory: true)
        try makeDirectory(directory)
        let previousManifest = directory + "\\runtime-files.txt"
        var previousRuntime: [String] = []
        if try NativeFiles.exists(previousManifest) {
            try inspect(previousManifest, directory: false)
            previousRuntime = try NativeFiles.text(previousManifest).split(whereSeparator: { $0.isNewline }).map(String.init).filter(runtimeName)
        }
        var transactionID = GUID(), transactionName = [WCHAR](repeating: 0, count: 40)
        try check(CoCreateGuid(&transactionID), "Create installation rollback directory")
        guard StringFromGUID2(&transactionID, &transactionName, Int32(transactionName.count)) > 0 else { throw WindowsError.unsupported("Encode installation rollback directory.") }
        let transaction = directory + "\\install-rollback-" + String(decoding: transactionName.prefix(while: { $0 != 0 }), as: UTF16.self)
        try makeDirectory(transaction)
        var savedFiles: [SavedFile] = [], metadata: [String] = []
        func discardBackups() throws {
            for saved in savedFiles { if let path = saved.backup { try NativeFiles.remove(path) } }
            for path in metadata { try NativeFiles.remove(path) }
            guard withWideString(try NativeFiles.windowsPath(transaction), { RemoveDirectoryW($0) }) else { throw WindowsError.api("Remove completed rollback directory", GetLastError()) }
        }
        do {
            var paths = files.map { directory + "\\" + $0 } + previousRuntime.map { directory + "\\" + $0 }
            paths += [directory + "\\startup-task.txt", shortcutPath]
            if hasLegacy { paths += [directory + "\\config.ini", directory + "\\software.txt"] }
            var seen: Set<String> = []
            for path in paths where seen.insert(path.lowercased()).inserted {
                try inspect(path, directory: false, required: false)
                let saved = try NativeFiles.exists(path) ? transaction + "\\" + String(savedFiles.count) + ".bak" : nil
                if let saved { try copy(path, saved) }
                savedFiles.append(SavedFile(path: path, backup: saved))
            }
            let manifest = transaction + "\\files.txt"
            try NativeFiles.write(Array(savedFiles.map { ($0.backup.map { String($0.split(separator: "\\").last!) } ?? "absent") + "\t" + $0.path }.joined(separator: "\r\n").utf8), to: manifest)
            metadata.append(manifest)
            if let previousTask {
                let xmlPath = transaction + "\\startup-task.xml", enabledPath = transaction + "\\startup-task-enabled.txt"
                try NativeFiles.write([0xff, 0xfe] + previousTask.xml.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }, to: xmlPath)
                metadata.append(xmlPath)
                try NativeFiles.write(Array(String(previousTask.enabled).utf8), to: enabledPath)
                metadata.append(enabledPath)
            }
            let runPath = transaction + "\\startup-run.txt"
            try NativeFiles.write(Array((previousRun.map { "present\r\n" + $0 } ?? "absent").utf8), to: runPath)
            metadata.append(runPath)
        } catch {
            try? discardBackups()
            throw error
        }
        var taskTouched = false, runTouched = false, launchAttempted = false
        var changedFiles: Set<String> = []
        do {
        progress("Waiting for the previous resident to restore its display…")
        try stop(executable, session: session)
        let backup = directory + "\\migration-backup"
        if hasLegacy {
            try makeDirectory(backup)
            for task in legacy {
                // Hash the full task path to keep folder-qualified backups distinct and bounded.
                let name = try legacyBackupName(task.path)
                guard (backup + "\\" + name).utf16.count < 32768 else { throw WindowsError.unsupported("Previous startup task backup path is too long.") }
                let path = backup + "\\" + name
                try inspect(path, directory: false, required: false)
                try NativeFiles.write(Array(task.xml.utf8), to: path)
            }
            if let legacyRun {
                let path = backup + "\\BrightnessCtl-run.txt"
                try inspect(path, directory: false, required: false)
                try NativeFiles.write(Array(legacyRun.utf8), to: path)
            }
            try stop(legacyExecutable, session: session)
            for name in ["scanout-lease.json", "output-color-lease.txt"] {
                guard try !NativeFiles.exists(legacyDirectory + "\\" + name) else { throw WindowsError.unsupported("BrightnessCtl recovery is pending. Restore the connected display with BrightnessCtl before migrating.") }
            }
        }
        // Hold the shared display mutex while replacing files; release before starting the resident.
        do {
            let lock = try InstanceLock(timeout: 0)
            guard lock.acquired else { throw WindowsError.unsupported("Another resident owns the display. Exit it and retry the installation.") }
            if hasLegacy, try !NativeFiles.exists(directory + "\\software.txt") {
                for name in ["config.ini", "software.txt"] where try NativeFiles.exists(legacyDirectory + "\\" + name) {
                    try copy(legacyDirectory + "\\" + name, backup + "\\" + name)
                    changedFiles.insert((directory + "\\" + name).lowercased())
                    try copy(legacyDirectory + "\\" + name, directory + "\\" + name)
                }
            }
            progress("Installing SwiftyToys and preserving your settings…")
            for relative in files {
                var parent = directory
                for component in relative.split(separator: "\\").dropLast() { parent += "\\" + component; try makeDirectory(parent) }
                changedFiles.insert((directory + "\\" + relative).lowercased())
                try copy(source + "\\" + relative, directory + "\\" + relative)
            }
            for name in previousRuntime {
                let path = directory + "\\" + name
                try inspect(path, directory: false, required: false)
                changedFiles.insert(path.lowercased())
                try NativeFiles.remove(path)
            }
        }
        changedFiles.insert(shortcutPath.lowercased())
        try shortcut(path: shortcutPath, executable: executable, directory: directory, icon: icon)
        progress("Configuring per-user startup…")
        let name = try Text(taskName), definition = try Text(taskXML(executable: executable, directory: directory, sid: sid))
        var registeredPointer: UnsafeMutablePointer<IRegisteredTask>?
        taskTouched = true
        try check(root.raw.pointee.lpVtbl.pointee.RegisterTask(root.raw, name.raw, definition.raw, LONG(TASK_CREATE_OR_UPDATE.rawValue), empty, empty, TASK_LOGON_INTERACTIVE_TOKEN, empty, &registeredPointer), "Register current-user startup task")
        let registered = try Reference(registeredPointer)
            let taskFile = directory + "\\startup-task.txt"
            try inspect(taskFile, directory: false, required: false)
            changedFiles.insert(taskFile.lowercased())
            try NativeFiles.write(Array(taskName.utf8), to: taskFile)
            runTouched = true
            try writeRun("SwiftyToys", value: "\"" + executable + "\"")
            try check(registered.raw.pointee.lpVtbl.pointee.put_Enabled(registered.raw, VARIANT_BOOL(-1)), "Enable installed SwiftyToys startup")
            var runningPointer: UnsafeMutablePointer<IRunningTask>?
            launchAttempted = true
            try check(registered.raw.pointee.lpVtbl.pointee.Run(registered.raw, empty, &runningPointer), "Start installed SwiftyToys")
            let running = try Reference(runningPointer)
            _ = running.raw
            let deadline = GetTickCount64() + 15000
            let verifyAfter = GetTickCount64() + 3000
            var started = false
            repeat {
                if GetTickCount64() >= verifyAfter, let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) {
                    var owner: DWORD = 0, ownerSession: DWORD = 0
                    GetWindowThreadProcessId(window, &owner)
                    if ProcessIdToSessionId(owner, &ownerSession), ownerSession == session,
                        let path = try processPath(owner), equalWindowsNames(path, executable) {
                        var reply: DWORD_PTR = 0
                        if SendMessageTimeoutW(window, brightnessMessage, 0, 0, UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 500, &reply) != 0,
                            (1...102).contains(reply) { started = true; break }
                    }
                }
                Sleep(100)
            } while GetTickCount64() < deadline
            guard started else { throw WindowsError.unsupported("SwiftyToys did not start. Previous BrightnessCtl startup has been retained; inspect startup.log and retry.") }
        } catch {
            let originalError = error
            var problems: [String] = []
            // Prevent another automatic launch before asking the new resident to restore and exit.
            if taskTouched {
                do {
                var pointer: UnsafeMutablePointer<IRegisteredTask>?
                let status = root.raw.pointee.lpVtbl.pointee.GetTask(root.raw, startupName.raw, &pointer)
                if status >= 0 {
                    let current = try Reference(pointer)
                    guard try owned(current.raw, executable: executable, sid: sid) else {
                        throw WindowsError.unsupported("Startup ownership changed; the new owner has been retained.")
                    }
                    try check(current.raw.pointee.lpVtbl.pointee.put_Enabled(current.raw, VARIANT_BOOL(0)), "Suspend failed installation startup")
                } else if status != HRESULT(bitPattern: 0x80070002) { try check(status, "Inspect failed startup task") }
                } catch { problems.append("Could not suspend startup: \(error)") }
            }
            if runTouched {
                do { try writeRun("SwiftyToys", value: nil) } catch { problems.append("Could not suspend the startup fallback: \(error)") }
            }
            do {
                if launchAttempted { try stop(executable, session: session) }
                guard problems.isEmpty else { throw WindowsError.unsupported(problems.joined(separator: "\n")) }
                let residentRunning = try remaining(executable, session: session)
                let lock = try InstanceLock(timeout: 0)
                guard mayRestoreFiles(residentRunning: residentRunning, acquiredMutex: lock.acquired) else {
                    throw WindowsError.unsupported("The resident or watchdog is still running, or a resident still owns the display.")
                }
                for saved in savedFiles.reversed() where changedFiles.contains(saved.path.lowercased()) {
                    if let backup = saved.backup { try copy(backup, saved.path) }
                    else { try inspect(saved.path, directory: false, required: false); try NativeFiles.remove(saved.path) }
                }
            } catch {
                throw WindowsError.unsupported("\(originalError)\n\nRecovery is pending; no files were restored under a running resident or watchdog. Rollback copies have been retained in \(transaction).\n\(error)")
            }
            if taskTouched {
                do {
                    var currentPointer: UnsafeMutablePointer<IRegisteredTask>?
                    let status = root.raw.pointee.lpVtbl.pointee.GetTask(root.raw, startupName.raw, &currentPointer)
                    if status >= 0 {
                        let current = try Reference(currentPointer)
                        guard try owned(current.raw, executable: executable, sid: sid) else {
                            throw WindowsError.unsupported("Startup ownership changed; the new owner has been retained.")
                        }
                    } else if status != HRESULT(bitPattern: 0x80070002) { try check(status, "Inspect startup task before rollback") }
                    if let previousTask {
                        let xml = try Text(previousTask.xml)
                        var restoredPointer: UnsafeMutablePointer<IRegisteredTask>?
                        try check(root.raw.pointee.lpVtbl.pointee.RegisterTask(root.raw, startupName.raw, xml.raw, LONG(TASK_CREATE_OR_UPDATE.rawValue), empty, empty, TASK_LOGON_INTERACTIVE_TOKEN, empty, &restoredPointer), "Restore previous startup task")
                        let restored = try Reference(restoredPointer)
                        try check(restored.raw.pointee.lpVtbl.pointee.put_Enabled(restored.raw, previousTask.enabled), "Restore previous startup task state")
                    } else {
                        let status = root.raw.pointee.lpVtbl.pointee.DeleteTask(root.raw, startupName.raw, 0)
                        if status != HRESULT(bitPattern: 0x80070002) { try check(status, "Remove failed new startup task") }
                    }
                } catch { problems.append("Could not restore the previous startup task: \(error)") }
            }
            if runTouched {
                do { try writeRun("SwiftyToys", value: previousRun) } catch { problems.append("Could not restore the previous startup fallback: \(error)") }
            }
            if problems.isEmpty {
                do {
                    if previousResidentRunning { try launch(executable, arguments: "", wait: false) }
                    else if previousLegacyRunning { try launch(legacyExecutable, arguments: "", wait: false) }
                } catch { problems.append("Previous files were restored, but the previous resident could not be relaunched: \(error)") }
            }
            if problems.isEmpty {
                do { try discardBackups() }
                catch { throw WindowsError.unsupported("\(originalError)\n\nPrevious files and startup were restored. Remaining rollback copies could not be removed from \(transaction).\n\(error)") }
                throw originalError
            }
            throw WindowsError.unsupported("\(originalError)\n\nRollback copies have been retained in \(transaction).\n" + problems.joined(separator: "\n"))
        }
        var warnings: [String] = []
        // The new resident is ready: legacy cleanup cannot turn this success into a failed installation.
        for legacyTask in legacy {
            do {
            let path = try Text(legacyTask.path)
            var pointer: UnsafeMutablePointer<IRegisteredTask>?
            try check(root.raw.pointee.lpVtbl.pointee.GetTask(root.raw, path.raw, &pointer), "Find migrated startup task")
            let task = try Reference(pointer)
            if try owned(task.raw, executable: legacyExecutable, sid: sid) {
                try check(task.raw.pointee.lpVtbl.pointee.put_Enabled(task.raw, VARIANT_BOOL(0)), "Disable migrated startup task")
            }
            } catch { warnings.append("A previous BrightnessCtl startup task could not be disabled and was retained."); Diagnostics.write("installation legacy startup cleanup: \(error)") }
        }
        do {
        if let legacyRun, equalWindowsNames(unquoted(legacyRun), legacyExecutable), try readRun("BrightnessCtl") == legacyRun {
            try writeRun("BrightnessCtl", value: nil)
        }
        } catch { warnings.append("The previous BrightnessCtl startup fallback could not be removed and was retained."); Diagnostics.write("installation legacy Run cleanup: \(error)") }
        // Retain unrelated or other-user tasks, even when they share the old task name.
        do {
        let oldName = try Text("SwiftyToys")
        var oldPointer: UnsafeMutablePointer<IRegisteredTask>?
        if root.raw.pointee.lpVtbl.pointee.GetTask(root.raw, oldName.raw, &oldPointer) >= 0 {
            let old = try Reference(oldPointer)
            if try owned(old.raw, executable: executable, sid: sid) { try check(root.raw.pointee.lpVtbl.pointee.DeleteTask(root.raw, oldName.raw, 0), "Remove owned legacy startup task") }
        }
        } catch { warnings.append("A previous SwiftyToys startup task could not be removed and was retained."); Diagnostics.write("installation previous startup cleanup: \(error)") }
        do { try discardBackups() } catch { warnings.append("Installation rollback copies were retained for manual cleanup."); Diagnostics.write("installation backup cleanup: \(error)") }
        progress("Installed and running. Your brightness and settings have been preserved." + (warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")))
        return executable
    }
    /// Pure checks: never change installed files, registry values, tasks or display state.
    static func selfCheck() throws {
        let backupName = try legacyBackupName("\\Fixture\\BrightnessCtl Startup Task")
        guard backupName.count == 68, backupName.hasSuffix(".xml"),
            backupName == (try legacyBackupName("\\Fixture\\BrightnessCtl Startup Task")),
            backupName != (try legacyBackupName("\\Other\\BrightnessCtl Startup Task")),
            try legacyBackupName("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.xml",
            (String(repeating: "a", count: 64) + "\\" + backupName + "." + String(repeating: "g", count: 38) + ".tmp").utf16.count < MAX_PATH else {
            throw WindowsError.unsupported("Compact legacy startup backup name check failed.")
        }
        let definition = taskXML(executable: "C:\\fixture & test\\SwiftyToys.exe", directory: "C:\\fixture & test", sid: "S-1-5-21-1-2-3-1001")
        guard definition.containsText("fixture &amp; test"), definition.containsText("<Priority>4</Priority>"),
            definition.containsText("<Delay>PT20S</Delay>"), definition.containsText("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"),
            definition.containsText("<RunLevel>LeastPrivilege</RunLevel>"), definition.containsText("<LogonType>InteractiveToken</LogonType>"),
            definition.containsText("<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"),
            definition.containsText("<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>"),
            definition.containsText("<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"), xml("<&>\"'") == "&lt;&amp;&gt;&quot;&apos;",
            runtimeName("swiftCore.dll"), runtimeName("FoundationEssentials.dll"), !runtimeName("..\\swiftCore.dll"),
            !runtimeName("swiftCore.dll:stream"), !runtimeName("kernel32.dll"),
            unquoted("\"C:\\fixture\\BrightnessCtl.exe\"") == "C:\\fixture\\BrightnessCtl.exe",
            unquoted("\"C:\\fixture\\BrightnessCtl.exe\" arguments") != "C:\\fixture\\BrightnessCtl.exe",
            mayRestoreFiles(residentRunning: false, acquiredMutex: true),
            !mayRestoreFiles(residentRunning: true, acquiredMutex: true),
            !mayRestoreFiles(residentRunning: false, acquiredMutex: false),
            !mayRestoreFiles(residentRunning: true, acquiredMutex: false) else {
            throw WindowsError.unsupported("Native installation task policy check failed.")
        }
        guard try equalWindowsNames(canonical("\\\\?\\C:\\fixture\\SwiftyToys"), canonical("C:\\fixture\\SwiftyToys")) else {
            throw WindowsError.unsupported("Native installation extended drive path check failed.")
        }
        for path in ["\\\\server\\share\\SwiftyToys", "\\\\?\\UNC\\server\\share\\SwiftyToys",
            "\\\\?\\Volume{fixture}\\SwiftyToys", "C:\\fixture:stream", "C:\\fixture\"bad", "C:\\fixture\u{0}"] {
            do { _ = try canonical(path) } catch { continue }
            throw WindowsError.unsupported("Native installation path rejection check failed.")
        }
        var temporary = [WCHAR](repeating: 0, count: 32768), guid = GUID(), name = [WCHAR](repeating: 0, count: 40)
        let count = GetTempPathW(DWORD(temporary.count), &temporary)
        guard count > 0, count < temporary.count else { throw WindowsError.api("Find installer fixture directory", GetLastError()) }
        try check(CoCreateGuid(&guid), "Create installer fixture identity")
        guard StringFromGUID2(&guid, &name, Int32(name.count)) > 0 else { throw WindowsError.unsupported("Encode installer fixture identity.") }
        let fixture = try canonical(String(decoding: temporary.prefix(Int(count)), as: UTF16.self) + "SwiftyToys-install-fixture-" + String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self))
        try inspect(fixture, directory: true, required: false)
        guard withWideString(try NativeFiles.windowsPath(fixture), { CreateDirectoryW($0, nil) }) else { throw WindowsError.api("Create exclusive installer fixture", GetLastError()) }
        let original = fixture + "\\old.bin", replacement = fixture + "\\new.bin", target = fixture + "\\target.bin", snapshot = fixture + "\\saved.bin"
        defer { for path in [original, replacement, target, snapshot] { try? NativeFiles.remove(path) }; if let fixture = try? NativeFiles.windowsPath(fixture) { _ = withWideString(fixture, { RemoveDirectoryW($0) }) } }
        try NativeFiles.write(Array("old payload".utf8), to: original)
        try NativeFiles.write(Array("new payload".utf8), to: replacement)
        try copy(original, target)
        try copy(target, snapshot)
        try copy(replacement, target)
        var rejected = false
        do { try copy(fixture + "\\missing.bin", target) } catch { rejected = true }
        guard rejected, try NativeFiles.read(target) == Array("new payload".utf8) else { throw WindowsError.unsupported("Invalid installation copy succeeded or damaged the destination.") }
        if mayRestoreFiles(residentRunning: true, acquiredMutex: true) { try copy(snapshot, target) }
        guard try NativeFiles.read(target) == Array("new payload".utf8) else { throw WindowsError.unsupported("Rollback changed files under a running watchdog.") }
        try copy(snapshot, target)
        guard try NativeFiles.read(target) == Array("old payload".utf8) else { throw WindowsError.unsupported("Explicit installation snapshot rollback failed.") }
        do {
            let executable=executablePath()
            var command=Array(("\""+executable+"\" --process-path-fixture").utf16)+[0]
            var startup=STARTUPINFOW(), child=PROCESS_INFORMATION()
            startup.cb=DWORD(MemoryLayout<STARTUPINFOW>.size)
            startup.dwFlags=DWORD(STARTF_USESHOWWINDOW); startup.wShowWindow=WORD(SW_HIDE)
            guard withWideString(executable,{ CreateProcessW($0,&command,nil,nil,false,DWORD(CREATE_SUSPENDED|CREATE_NO_WINDOW),nil,nil,&startup,&child) }) else {
                throw WindowsError.api("Create owned installer process fixture",GetLastError())
            }
            let process=try OwnedHandle(child.hProcess), thread=try OwnedHandle(child.hThread)
            defer {
                if WaitForSingleObject(process.raw,0) != DWORD(WAIT_OBJECT_0) {
                    _=TerminateProcess(process.raw,1); _=WaitForSingleObject(process.raw,5000)
                }
            }
            guard try processPath(child.dwProcessId).map({equalWindowsNames($0,executable)}) == true else {
                throw WindowsError.unsupported("Live owned process identity was not verified.")
            }
            guard ResumeThread(thread.raw) != DWORD.max, WaitForSingleObject(process.raw,10000)==DWORD(WAIT_OBJECT_0),
                try processPath(child.dwProcessId)==nil else {
                throw WindowsError.unsupported("Exited process was not excluded from installer ownership checks.")
            }
        }
        Console.writeLine("PASS: native installer policies, unsafe path rejection, atomic file replacement and rollback ownership gate; no system configuration changed")
    }
}
