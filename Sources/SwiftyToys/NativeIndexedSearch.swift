// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import SearchIndexABI
import WinSDK

/// Read-only providers for the isolated search worker; COM calls never run on the UI/input thread.
enum NativeIndexedSearch {
    private final class Reference<T> {
        let raw: UnsafeMutablePointer<T>
        init(_ pointer: UnsafeMutablePointer<T>?) throws {
            guard let pointer else { throw WindowsError.unsupported("Search returned an empty native interface.") }; raw = pointer
        }
        deinit { raw.withMemoryRebound(to: IUnknown.self, capacity: 1) { _ = $0.pointee.lpVtbl.pointee.Release($0) } }
    }
    private final class Value {
        var raw = VARIANT()
        init() {}
        init(_ text: String) throws {
            guard let value = withWideString(text, { SysAllocString($0) }) else { throw WindowsError.unsupported("Allocate search string.") }
            raw.vt = VARTYPE(VT_BSTR.rawValue); raw.bstrVal = value
        }
        init(_ integer: Int32) { raw.vt = VARTYPE(VT_I4.rawValue); raw.lVal = integer }
        deinit { VariantClear(&raw) }
        func dispatch() throws -> Reference<IDispatch> {
            guard raw.vt == VARTYPE(VT_DISPATCH.rawValue), let pointer = raw.pdispVal else { throw WindowsError.unsupported("Search did not return an automation interface.") }
            _ = pointer.pointee.lpVtbl.pointee.AddRef(pointer)
            return try Reference(pointer)
        }
        var text: String? {
            guard raw.vt == VARTYPE(VT_BSTR.rawValue), let text = raw.bstrVal, SysStringLen(text) <= 32767 else { return nil }
            return String(decoding: UnsafeBufferPointer(start: text, count: Int(SysStringLen(text))), as: UTF16.self)
        }
        var bool: Bool? { raw.vt == VARTYPE(VT_BOOL.rawValue) ? raw.boolVal != 0 : nil }
    }
    private static func check(_ result: HRESULT, _ operation: String) throws { guard result >= 0 else { throw WindowsError.status(operation, result) } }
    private static func withCOM<T>(_ body: () throws -> T) throws -> T {
        let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        try check(initialized, "Initialize read-only search COM")
        defer { CoUninitialize() }; return try body()
    }
    private static func invoke(_ object: Reference<IDispatch>, _ name: String, flags: WORD = WORD(DISPATCH_PROPERTYGET), arguments: [Value] = []) throws -> Value {
        var identifier: DISPID = 0, empty = GUID()
        try check(withWideString(name) { text in
            var name: PWSTR? = UnsafeMutablePointer(mutating: text)
            return object.raw.pointee.lpVtbl.pointee.GetIDsOfNames(object.raw, &empty, &name, 1, GetUserDefaultLCID(), &identifier)
        }, "Find search automation property")
        var values = arguments.reversed().map { $0.raw }, named = DISPID(DISPID_PROPERTYPUT)
        let result = Value(); var exception = EXCEPINFO(), argumentError: UINT = 0
        defer { SysFreeString(exception.bstrSource); SysFreeString(exception.bstrDescription); SysFreeString(exception.bstrHelpFile) }
        let status = values.withUnsafeMutableBufferPointer { buffer in
            withUnsafeMutablePointer(to: &named) { named in
                var parameters = DISPPARAMS(rgvarg: buffer.baseAddress, rgdispidNamedArgs: flags & WORD(DISPATCH_PROPERTYPUT) != 0 ? named : nil, cArgs: UINT(buffer.count), cNamedArgs: flags & WORD(DISPATCH_PROPERTYPUT) != 0 ? 1 : 0)
                return object.raw.pointee.lpVtbl.pointee.Invoke(object.raw, identifier, &empty, GetUserDefaultLCID(), flags, &parameters, &result.raw, &exception, &argumentError)
            }
        }
        withExtendedLifetime(arguments) {}
        try check(status, "Read-only search automation")
        return result
    }
    private static func nativeText(_ pointer: PWSTR?) throws -> String {
        guard let pointer else { throw WindowsError.unsupported("Search returned an empty native string.") }
        var count = 0
        while count < 32768, pointer[count] != 0 { count += 1 }
        guard count < 32768 else { throw WindowsError.unsupported("Search string exceeded the Windows limit.") }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF16.self)
    }
    /// Reject non-file URLs, UNC/device namespaces, remote drives and stale paths before returning an action.
    static func localPath(from url: String) throws -> String? {
        guard url.utf16.count < 32768, !url.utf16.contains(0), url.prefix(5).lowercased() == "file:" else { return nil }
        let capacity = max(Int(MAX_PATH), url.utf16.count + 1)
        var buffer = [WCHAR](repeating: 0, count: capacity), count = DWORD(capacity)
        guard withWideString(url, { PathCreateFromUrlW($0, &buffer, &count, 0) }) >= 0 else { return nil }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
        let first = path.utf8.first ?? 0
        guard ((65...90).contains(first) || (97...122).contains(first)), path.dropFirst().hasPrefix(":\\"), !path.dropFirst(2).contains(":"), !path.utf16.contains(0) else { return nil }
        let drive = String(path.prefix(3))
        let kind = withWideString(drive) { GetDriveTypeW($0) }
        guard kind == UINT(DRIVE_FIXED) || kind == UINT(DRIVE_REMOVABLE) || kind == UINT(DRIVE_CDROM) || kind == UINT(DRIVE_RAMDISK), try NativeFiles.exists(path) else { return nil }
        return path
    }
    private static func indexedFiles(_ query: String) throws -> [SearchItem] {
        var classID = GUID(Data1: 0x7d096c5f, Data2: 0xac08, Data3: 0x4f1f, Data4: (0xbe,0xb7,0x5c,0x22,0xc5,0x17,0xce,0x39))
        var managerID = GUID(Data1: 0xab310581, Data2: 0xac80, Data3: 0x11d1, Data4: (0x8d,0xf3,0x00,0xc0,0x4f,0xb6,0xef,0x69)), object: UnsafeMutableRawPointer?
        try check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_LOCAL_SERVER.rawValue | CLSCTX_INPROC_SERVER.rawValue), &managerID, &object), "Open Windows Search")
        let manager = try Reference(object?.assumingMemoryBound(to: STSearchManager.self))
        var catalogPointer: UnsafeMutablePointer<STSearchCatalogManager>?
        try check(withWideString("SystemIndex") { manager.raw.pointee.lpVtbl.pointee.GetCatalog(manager.raw, $0, &catalogPointer) }, "Read Windows Search catalog")
        let catalog = try Reference(catalogPointer)
        var queryPointer: UnsafeMutablePointer<STSearchQueryHelper>?
        try check(catalog.raw.pointee.lpVtbl.pointee.GetQueryHelper(catalog.raw, &queryPointer), "Create native indexed query")
        let helper = try Reference(queryPointer)
        try check(helper.raw.pointee.lpVtbl.pointee.put_QueryMaxResults(helper.raw, 32), "Limit Windows Search results")
        try check(helper.raw.pointee.lpVtbl.pointee.put_QuerySyntax(helper.raw, 1), "Select native search syntax") // SEARCH_ADVANCED_QUERY_SYNTAX; native content locale/default all-property full-text search.
        try check(withWideString("System.ItemNameDisplay,System.ItemUrl,System.ItemTypeText") { helper.raw.pointee.lpVtbl.pointee.put_QuerySelectColumns(helper.raw, $0) }, "Select indexed item metadata")
        try check(withWideString("AND scope='file:'") { helper.raw.pointee.lpVtbl.pointee.put_QueryWhereRestrictions(helper.raw, $0) }, "Restrict indexed results to files")
        var sqlPointer: PWSTR?, connectionPointer: PWSTR?
        defer { CoTaskMemFree(sqlPointer); CoTaskMemFree(connectionPointer) }
        try check(withWideString(query) { helper.raw.pointee.lpVtbl.pointee.GenerateSQLFromUserQuery(helper.raw, $0, &sqlPointer) }, "Generate native indexed query")
        try check(helper.raw.pointee.lpVtbl.pointee.get_ConnectionString(helper.raw, &connectionPointer), "Read native index connection")
        let sql = try nativeText(sqlPointer), connectionString = try nativeText(connectionPointer)
        var adoClass = GUID(Data1: 0x00000514, Data2: 0x0000, Data3: 0x0010, Data4: (0x80,0x00,0x00,0xaa,0x00,0x6d,0x2e,0xa4)), dispatchID = IID_IDispatch
        object = nil
        try check(CoCreateInstance(&adoClass, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &dispatchID, &object), "Open read-only index provider")
        let connection = try Reference(object?.assumingMemoryBound(to: IDispatch.self))
        _ = try invoke(connection, "Mode", flags: WORD(DISPATCH_PROPERTYPUT), arguments: [Value(1)]) // adModeRead
        _ = try invoke(connection, "ConnectionTimeout", flags: WORD(DISPATCH_PROPERTYPUT), arguments: [Value(2)])
        _ = try invoke(connection, "CommandTimeout", flags: WORD(DISPATCH_PROPERTYPUT), arguments: [Value(2)])
        _ = try invoke(connection, "Open", flags: WORD(DISPATCH_METHOD), arguments: [try Value(connectionString)])
        defer { _ = try? invoke(connection, "Close", flags: WORD(DISPATCH_METHOD)) }
        let rows = try invoke(connection, "Execute", flags: WORD(DISPATCH_METHOD), arguments: [try Value(sql)]).dispatch()
        defer { _ = try? invoke(rows, "Close", flags: WORD(DISPATCH_METHOD)) }
        let fields = try invoke(rows, "Fields").dispatch()
        func field(_ index: Int32) throws -> String? {
            let item = try invoke(fields, "Item", arguments: [Value(index)]).dispatch()
            return try invoke(item, "Value").text
        }
        var result: [SearchItem] = []
        for _ in 0..<32 {
            guard try invoke(rows, "EOF").bool == false else { break }
            if let title = try field(0), let url = try field(1), let path = try localPath(from: url), !title.isEmpty {
                let attributes = withWideString(try NativeFiles.windowsPath(path)) { GetFileAttributesW($0) }
                if attributes != DWORD(INVALID_FILE_ATTRIBUTES) {
                    let kind = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 ? "Folder" : "File"
                    result.append(SearchItem(id: "index:" + path.lowercased(), title: title, subtitle: try field(2) ?? kind, path: path, kind: kind))
                }
            }
            _ = try invoke(rows, "MoveNext", flags: WORD(DISPATCH_METHOD))
        }
        return result
    }
    static func query(_ text: String) throws -> [SearchItem] {
        guard !text.trimmingWhitespace().isEmpty else { return [] }
        guard text.utf16.count <= 512, !text.utf16.contains(0) else { throw WindowsError.unsupported("The Windows Search query is too long or invalid.") }
        return try withCOM { try indexedFiles(text) }
    }
    static func applications(onDegraded: (String) -> Void = { Console.writeLine($0) }) throws -> [SearchItem] {
        try withCOM {
            var result: [SearchItem] = [], seen: Set<String> = [], budget = 8192
            for id in [FOLDERID_Programs, FOLDERID_CommonPrograms] {
                var id = id, pointer: PWSTR?
                let status = SHGetKnownFolderPath(&id, DWORD(KF_FLAG_DONT_VERIFY.rawValue), nil, &pointer)
                defer { CoTaskMemFree(pointer) }
                if status >= 0, let path = try? nativeText(pointer), (try? NativeFiles.exists(path)) == true {
                    try startMenu(path, depth: 0, result: &result, seen: &seen, budget: &budget)
                }
            }
            do {
            var folderID = FOLDERID_AppsFolder, itemID = IID_IShellItem, object: UnsafeMutableRawPointer?
            try check(SHGetKnownFolderItem(&folderID, KF_FLAG_DEFAULT, nil, &itemID, &object), "Read Windows application folder")
            let folder = try Reference(object?.assumingMemoryBound(to: IShellItem.self))
            var handler = BHID_EnumItems, enumerationID = IID_IEnumShellItems
            object = nil
            try check(folder.raw.pointee.lpVtbl.pointee.BindToHandler(folder.raw, nil, &handler, &enumerationID, &object), "Enumerate installed Windows applications")
            let enumeration = try Reference(object?.assumingMemoryBound(to: IEnumShellItems.self))
            for _ in 0..<2048 {
                if result.count >= 2048 { break }
                var pointer: UnsafeMutablePointer<IShellItem>?, fetched: ULONG = 0
                let status = enumeration.raw.pointee.lpVtbl.pointee.Next(enumeration.raw, 1, &pointer, &fetched)
                try check(status, "Read installed application")
                if status == S_FALSE || fetched == 0 { break }
                let item = try Reference(pointer)
                var title: PWSTR?, parsing: PWSTR?
                defer { CoTaskMemFree(title); CoTaskMemFree(parsing) }
                if item.raw.pointee.lpVtbl.pointee.GetDisplayName(item.raw, SIGDN_NORMALDISPLAY, &title) >= 0,
                    item.raw.pointee.lpVtbl.pointee.GetDisplayName(item.raw, SIGDN_PARENTRELATIVEPARSING, &parsing) >= 0,
                    let name = try? nativeText(title), let appID = try? nativeText(parsing), validAppID(appID), !name.isEmpty {
                    let path = "shell:AppsFolder\\" + appID
                    if seen.insert(path.lowercased()).inserted { result.append(SearchItem(id: "app:" + appID, title: name, subtitle: "Windows application", path: path, kind: "Application")) }
                }
            }
            } catch {
                guard !result.isEmpty else { throw error }
                onDegraded("Windows application folder could not be fully read. Available application results were retained.")
            }
            return result
        }
    }
    private static func validAppID(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 512 && !value.contains(":") && !value.contains("\\") && !value.contains("/") && !value.utf16.contains(0)
    }
    private static func startMenu(_ directory: String, depth: Int, result: inout [SearchItem], seen: inout Set<String>, budget: inout Int) throws {
        guard depth < 6, result.count < 2048, budget > 0 else { return }
        var data = WIN32_FIND_DATAW()
        let search = withWideString(try NativeFiles.windowsPath(directory + "\\*")) { FindFirstFileW($0, &data) }
        guard let search, search != INVALID_HANDLE_VALUE else { if GetLastError() == DWORD(ERROR_FILE_NOT_FOUND) { return }; throw WindowsError.api("Read Start menu applications", GetLastError()) }
        defer { FindClose(search) }
        var count = 0
        repeat {
            let name = wideString(data.cFileName); count += 1; budget -= 1
            if name != ".", name != "..", data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 {
                let path = directory + "\\" + name
                if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { try startMenu(path, depth: depth + 1, result: &result, seen: &seen, budget: &budget) }
                else if name.lowercased().hasSuffix(".lnk"), seen.insert(path.lowercased()).inserted {
                    result.append(SearchItem(id: "app:" + path.lowercased(), title: String(name.dropLast(4)), subtitle: "Start menu application", path: path, kind: "Application"))
                }
            }
            if count >= 2048 || result.count >= 2048 || budget <= 0 { break }
        } while FindNextFileW(search, &data)
    }
    static func selfCheck() throws {
        guard try localPath(from: "https://example.invalid/document") == nil,
            try localPath(from: "file://server/share/document") == nil,
            !validAppID("shell:AppsFolder\\app"), !validAppID("../app"), validAppID("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App") else {
            throw WindowsError.unsupported("Native indexed search action validation failed.")
        }
        let indexed: [SearchItem], status: String
        do { indexed = try query("documents"); status = "available" }
        catch { indexed = []; status = "Windows Search unavailable; local fallback required" }
        guard indexed.count <= 32, indexed.allSatisfy({ $0.kind == "File" || $0.kind == "Folder" }) else { throw WindowsError.unsupported("Native indexed search result bounds failed.") }
        let apps = try applications()
        guard apps.count <= 2048, apps.allSatisfy({ $0.kind == "Application" }) else { throw WindowsError.unsupported("Native application enumeration bounds failed.") }
        let virtual = apps.filter { $0.path.hasPrefix("shell:AppsFolder\\") }.count
        Console.writeLine("PASS: read-only Windows Search and Start menu/AppsFolder enumeration; index results=\(indexed.count), applications=\(apps.count) (AppsFolder=\(virtual)), status=\(status)")
    }
}
