// SPDX-License-Identifier: MIT
import WinSDK

enum ShellIntegration {
    static let applicationID = "SwiftyToys.SwiftyToys"
    private static var identityKey: PROPERTYKEY {
        PROPERTYKEY(fmtid: GUID(Data1: 0x9f4c2855, Data2: 0x9f79, Data3: 0x4b39,
            Data4: (0xa8, 0xd0, 0xe1, 0xd4, 0x2d, 0xe1, 0xd5, 0xf3)), pid: 5)
    }
    private static func check(_ result: HRESULT, _ operation: String) throws {
        guard result >= 0 else { throw WindowsError.status(operation, result) }
    }
    static func configureProcessIdentity() throws {
        try check(withWideString(applicationID) { SetCurrentProcessExplicitAppUserModelID($0) }, "Set taskbar application identity")
    }
    private static func withCOM<Result>(_ body: () throws -> Result) throws -> Result {
        let result = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        guard result >= 0 || result == HRESULT(bitPattern: 0x80010106) else { throw WindowsError.status("Initialize Shell COM", result) }
        defer { if result >= 0 { CoUninitialize() } }
        return try body()
    }
    private static func withShortcut<Result>(
        _ path: String?, _ body: (UnsafeMutablePointer<IShellLinkW>, UnsafeMutablePointer<IPersistFile>, UnsafeMutablePointer<IPropertyStore>) throws -> Result
    ) throws -> Result {
        var classID = CLSID_ShellLink, linkID = IID_IShellLinkW
        var object: UnsafeMutableRawPointer?
        try check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &linkID, &object), "Open Shell shortcut")
        guard let link = object?.assumingMemoryBound(to: IShellLinkW.self) else { throw WindowsError.unsupported("Shell returned an empty shortcut.") }
        defer { _ = link.pointee.lpVtbl.pointee.Release(link) }
        var fileID = IID_IPersistFile
        object = nil
        try check(link.pointee.lpVtbl.pointee.QueryInterface(link, &fileID, &object), "Open shortcut storage")
        guard let file = object?.assumingMemoryBound(to: IPersistFile.self) else { throw WindowsError.unsupported("Shell returned empty shortcut storage.") }
        defer { _ = file.pointee.lpVtbl.pointee.Release(file) }
        if let path { try check(withWideString(path) { file.pointee.lpVtbl.pointee.Load(file, $0, 2) }, "Read shortcut") }
        var propertyID = IID_IPropertyStore
        object = nil
        try check(link.pointee.lpVtbl.pointee.QueryInterface(link, &propertyID, &object), "Open shortcut properties")
        guard let properties = object?.assumingMemoryBound(to: IPropertyStore.self) else { throw WindowsError.unsupported("Shell returned empty shortcut properties.") }
        defer { _ = properties.pointee.lpVtbl.pointee.Release(properties) }
        return try body(link, file, properties)
    }
    private static func readText(_ read: (UnsafeMutablePointer<WCHAR>, Int32) -> HRESULT) throws -> String {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        try check(read(&buffer, Int32(buffer.count)), "Read shortcut field")
        guard buffer.last == 0 else { throw WindowsError.unsupported("Shortcut field exceeds the Shell path limit.") }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
    private static func equalPaths(_ lhs: String, _ rhs: String) -> Bool {
        withWideString(lhs) { left in withWideString(rhs) { CompareStringOrdinal(left, -1, $0, -1, true) == CSTR_EQUAL } }
    }
    private static func readIdentity(_ text: PWSTR?) throws -> String {
        guard let text else { throw WindowsError.unsupported("Shell returned an empty application identity.") }
        var length = 0
        while length <= 128, text[length] != 0 { length += 1 }
        guard length <= 128 else { throw WindowsError.unsupported("Invalid Shell application identity.") }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }
    static func configureShortcut(path: String, iconPath: String) throws {
        try configureShortcut(path: path, iconPath: iconPath, target: NativeFiles.path("SwiftyToys.exe"))
    }
    private static func configureShortcut(path: String, iconPath: String, target expectedTarget: String) throws {
        guard !path.utf16.contains(0), !iconPath.utf16.contains(0),
            path.utf16.count < MAX_PATH, iconPath.utf16.count < MAX_PATH, try NativeFiles.exists(iconPath)
        else { throw WindowsError.unsupported("Invalid Shell shortcut or icon path.") }
        try withCOM {
            try withShortcut(path) { link, file, properties in
                let target = try readText { link.pointee.lpVtbl.pointee.GetPath(link, $0, $1, nil, 0) }
                var index: Int32 = 0
                let icon = try readText { link.pointee.lpVtbl.pointee.GetIconLocation(link, $0, $1, &index) }
                guard equalPaths(target, expectedTarget), equalPaths(icon, iconPath), index == 0 else {
                    throw WindowsError.unsupported("Shortcut must target the installed SwiftyToys and its selected icon.")
                }
                var value = PROPVARIANT()
                defer { PropVariantClear(&value) }
                let characters = Array(applicationID.utf16) + [0]
                guard let allocation = CoTaskMemAlloc(SIZE_T(characters.count * MemoryLayout<WCHAR>.size)) else {
                    throw WindowsError.unsupported("Could not allocate the shortcut identity.")
                }
                value.vt = VARTYPE(VT_LPWSTR.rawValue)
                value.pwszVal = allocation.assumingMemoryBound(to: WCHAR.self)
                characters.withUnsafeBufferPointer { value.pwszVal.initialize(from: $0.baseAddress!, count: $0.count) }
                var key = identityKey
                try check(properties.pointee.lpVtbl.pointee.SetValue(properties, &key, &value), "Set shortcut application identity")
                try check(properties.pointee.lpVtbl.pointee.Commit(properties), "Commit shortcut application identity")
                try check(withWideString(path) { file.pointee.lpVtbl.pointee.Save(file, $0, true) }, "Save shortcut application identity")
            }
        }
    }
    static func refreshIcons(paths: [String]) throws {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.utf16.contains(0) && $0.utf16.count < MAX_PATH }) else {
            throw WindowsError.unsupported("Shell notification paths must fit MAX_PATH.")
        }
        for path in paths {
            withWideString(path) { SHChangeNotify(LONG(SHCNE_UPDATEITEM), UINT(SHCNF_PATHW | SHCNF_FLUSHNOWAIT), $0, nil) }
        }
    }
    static func selfCheck() throws {
        var processID: PWSTR?
        try check(GetCurrentProcessExplicitAppUserModelID(&processID), "Read taskbar application identity")
        defer { CoTaskMemFree(processID) }
        guard try readIdentity(processID) == applicationID else { throw WindowsError.unsupported("Process taskbar identity failed.") }
        var temporary = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        let count = GetTempPathW(DWORD(temporary.count), &temporary)
        guard count > 0, count < temporary.count else { throw WindowsError.api("Find test temporary directory", GetLastError()) }
        var guid = GUID(), name = [WCHAR](repeating: 0, count: 40)
        try check(CoCreateGuid(&guid), "Create shortcut fixture identity")
        guard StringFromGUID2(&guid, &name, Int32(name.count)) > 0 else { throw WindowsError.unsupported("Encode shortcut fixture identity.") }
        let path = String(decoding: temporary.prefix(Int(count)), as: UTF16.self) + "SwiftyToys-" + String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self) + ".lnk"
        guard try !NativeFiles.exists(path) else { throw WindowsError.unsupported("Shortcut fixture already exists.") }
        defer { try? NativeFiles.remove(path) }
        let target = executablePath(), icon = target
        let directory = target.split(separator: "\\").dropLast().joined(separator: "\\")
        let arguments = "settings", description = "SwiftyToys Shell fixture"
        try withCOM {
            try withShortcut(nil) { link, file, _ in
                try check(withWideString(target) { link.pointee.lpVtbl.pointee.SetPath(link, $0) }, "Create shortcut fixture target")
                try check(withWideString(arguments) { link.pointee.lpVtbl.pointee.SetArguments(link, $0) }, "Create shortcut fixture arguments")
                try check(withWideString(directory) { link.pointee.lpVtbl.pointee.SetWorkingDirectory(link, $0) }, "Create shortcut fixture directory")
                try check(withWideString(description) { link.pointee.lpVtbl.pointee.SetDescription(link, $0) }, "Create shortcut fixture description")
                try check(withWideString(icon) { link.pointee.lpVtbl.pointee.SetIconLocation(link, $0, 0) }, "Create shortcut fixture icon")
                try check(withWideString(path) { file.pointee.lpVtbl.pointee.Save(file, $0, true) }, "Save shortcut fixture")
            }
            try configureShortcut(path: path, iconPath: icon, target: target)
            try withShortcut(path) { link, _, properties in
                var key = identityKey, value = PROPVARIANT()
                defer { PropVariantClear(&value) }
                try check(properties.pointee.lpVtbl.pointee.GetValue(properties, &key, &value), "Read shortcut fixture identity")
                guard value.vt == VARTYPE(VT_LPWSTR.rawValue) else { throw WindowsError.unsupported("Shortcut identity type failed.") }
                let actualID = try readIdentity(value.pwszVal)
                var index: Int32 = 0
                let actualIcon = try readText { link.pointee.lpVtbl.pointee.GetIconLocation(link, $0, $1, &index) }
                guard actualID == applicationID, equalPaths(actualIcon, icon), index == 0,
                    try equalPaths(readText { link.pointee.lpVtbl.pointee.GetPath(link, $0, $1, nil, 0) }, target),
                    try readText({ link.pointee.lpVtbl.pointee.GetArguments(link, $0, $1) }) == arguments,
                    try equalPaths(readText { link.pointee.lpVtbl.pointee.GetWorkingDirectory(link, $0, $1) }, directory),
                    try readText({ link.pointee.lpVtbl.pointee.GetDescription(link, $0, $1) }) == description
                else { throw WindowsError.unsupported("Shortcut identity, icon or preserved fields failed.") }
            }
        }
        Console.writeLine("PASS: native shortcut identity and icon roundtrip; target, arguments, directory and description preserved")
    }
}
