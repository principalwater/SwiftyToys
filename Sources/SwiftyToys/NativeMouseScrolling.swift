// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI

let mouseScrollResultMessage: UINT = 0x8023
/// The immutable child-process handle stays alive through its background wait.
private final class MouseScrollOperation: @unchecked Sendable {
    let process: OwnedHandle
    let destination: MessageDestination
    let flags: Int
    init(process: HANDLE?, destination: MessageDestination, flags: Int) throws {
        self.process = try OwnedHandle(process)
        self.destination = destination
        self.flags = flags
    }
    func wait() {
        var code: DWORD = 1
        var result = WaitForSingleObject(process.raw, 60000)
        if result == DWORD(WAIT_TIMEOUT) {
            _ = destination.post(mouseScrollResultMessage, value: 4, data: flags)
            // Do not terminate a driver installer or permit an overlapping operation.
            result = WaitForSingleObject(process.raw, DWORD(INFINITE))
        }
        if result == DWORD(WAIT_OBJECT_0) { GetExitCodeProcess(process.raw, &code) }
        _ = destination.post(mouseScrollResultMessage, value: Int(code), data: flags)
    }
}
enum NativeMouseScrolling {
    struct State {
        let devices: [(name: String, vertical: Bool, horizontal: Bool)]
        var vertical: Bool? { let values = Set(devices.map(\.vertical)); return values.count == 1 ? values.first : nil }
        var horizontal: Bool? { let values = Set(devices.map(\.horizontal)); return values.count == 1 ? values.first : nil }
        func matches(vertical: Bool, horizontal: Bool) -> Bool {
            !devices.isEmpty && devices.allSatisfy { $0.vertical == vertical && $0.horizontal == horizontal }
        }
        var summary: String { devices.map { "\($0.name): vertical=\($0.vertical ? 1 : 0), horizontal=\($0.horizontal ? 1 : 0)" }.joined(separator: "\n") }
    }
    private struct Target {
        var device: SP_DEVINFO_DATA
        let key: HKEY
        let name: String
        let vertical: DWORD?
        let horizontal: DWORD?
    }
    /// Only Windows mouhid mice qualify; Magic Trackpad keeps its Precision settings.
    static func supports(service: String, hardwareID: String) -> Bool {
        let id = hardwareID.lowercased()
        return service.lowercased() == "mouhid" && id.hasPrefix("hid\\")
            && !["vid_05ac", "vid&0001004c", "vid&01004c"].contains(where: id.containsText)
    }
    /// Reads a bounded native flag, preserving the difference between missing and zero.
    private static func direction(_ key: HKEY, _ name: String) throws -> DWORD? {
        var value: DWORD = 0; var size = DWORD(MemoryLayout<DWORD>.size); var type: DWORD = 0
        let status = withWideString(name) { name in
            withUnsafeMutableBytes(of: &value) { RegQueryValueExW(key, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
        }
        if status == ERROR_FILE_NOT_FOUND { return nil }
        guard status == ERROR_SUCCESS else { throw WindowsError.api("Read mouse direction", DWORD(status)) }
        guard type == REG_DWORD, size == 4, value <= 1 else { throw WindowsError.unsupported("Unexpected mouse direction registry value.") }
        return value
    }
    private static func setDirection(_ key: HKEY, _ name: String, _ value: DWORD?) throws {
        let status: LSTATUS
        if var value {
            guard value <= 1 else { throw WindowsError.unsupported("Mouse direction must be 0 or 1.") }
            status = withWideString(name) { name in
                withUnsafeBytes(of: &value) { RegSetValueExW(key, name, 0, DWORD(REG_DWORD), $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count)) }
            }
        } else { status = withWideString(name) { RegDeleteValueW(key, $0) } }
        guard status == ERROR_SUCCESS || (value == nil && status == ERROR_FILE_NOT_FOUND) else { throw WindowsError.api("Write mouse direction", DWORD(status)) }
    }
    private static func property(_ key: DWORD, _ devices: HDEVINFO, _ device: inout SP_DEVINFO_DATA) -> String {
        var buffer = Array(repeating: WCHAR(0), count: 4096)
        var size: DWORD = 0
        let valid = buffer.withUnsafeMutableBytes { SetupDiGetDeviceRegistryPropertyW(devices, &device, key, nil, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count), &size) }
        return valid ? String(decoding: buffer.prefix(min(buffer.count, Int(size / 2))), as: UTF16.self).split(separator: "\0").joined(separator: " ") : ""
    }
    /// Requests a native driver restart without explicitly leaving a device disabled.
    private static func restart(_ devices: HDEVINFO, _ device: inout SP_DEVINFO_DATA) -> Bool {
        var change = SP_PROPCHANGE_PARAMS()
        change.ClassInstallHeader.cbSize = DWORD(MemoryLayout<SP_CLASSINSTALL_HEADER>.size)
        change.ClassInstallHeader.InstallFunction = DI_FUNCTION(DIF_PROPERTYCHANGE)
        change.StateChange = DWORD(DICS_PROPCHANGE); change.Scope = DWORD(DICS_FLAG_CONFIGSPECIFIC)
        let set = withUnsafeMutablePointer(to: &change) { pointer in
            pointer.withMemoryRebound(to: SP_CLASSINSTALL_HEADER.self, capacity: 1) {
                SetupDiSetClassInstallParamsW(devices, &device, $0, DWORD(MemoryLayout<SP_PROPCHANGE_PARAMS>.size))
            }
        }
        guard set else { return false }
        defer { SetupDiSetClassInstallParamsW(devices, &device, nil, 0) }
        guard SetupDiCallClassInstaller(DI_FUNCTION(DIF_PROPERTYCHANGE), devices, &device) else { return false }
        var parameters = SP_DEVINSTALL_PARAMS_W(); parameters.cbSize = DWORD(MemoryLayout<SP_DEVINSTALL_PARAMS_W>.size)
        guard SetupDiGetDeviceInstallParamsW(devices, &device, &parameters), parameters.Flags & DWORD(DI_NEEDRESTART | DI_NEEDREBOOT) == 0 else { return false }
        let deadline = GetTickCount64() + 2000
        repeat {
            var status: ULONG = 0; var problem: ULONG = 0
            if CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == 0 && problem == 0,
                status & ULONG(DN_STARTED) != 0, status & ULONG(DN_HAS_PROBLEM) == 0 { return true }
            Sleep(50)
        } while GetTickCount64() < deadline
        return false
    }
    /// Shared enumeration keeps the read-only UI and elevated writer on the same device scope.
    private static func withTargets<Result>(access: REGSAM, body: (HDEVINFO, inout [Target]) throws -> Result) throws -> Result {
        var mouseClass = GUID(Data1: 0x4d36e96f, Data2: 0xe325, Data3: 0x11ce, Data4: (0xbf,0xc1,0x08,0x00,0x2b,0xe1,0x03,0x18))
        guard let devices = SetupDiGetClassDevsW(&mouseClass, nil, nil, DWORD(DIGCF_PRESENT)), devices != HANDLE(bitPattern: -1) else { throw WindowsError.api("Enumerate HID mice", GetLastError()) }
        defer { SetupDiDestroyDeviceInfoList(devices) }
        var targets: [Target] = []
        defer { for target in targets { RegCloseKey(target.key) } }
        for index in 0..<256 {
            var device = SP_DEVINFO_DATA(); device.cbSize = DWORD(MemoryLayout<SP_DEVINFO_DATA>.size)
            guard SetupDiEnumDeviceInfo(devices, DWORD(index), &device) else {
                if GetLastError() != ERROR_NO_MORE_ITEMS { throw WindowsError.api("Enumerate mouse", GetLastError()) }
                break
            }
            guard supports(service: property(DWORD(SPDRP_SERVICE), devices, &device), hardwareID: property(DWORD(SPDRP_HARDWAREID), devices, &device)) else { continue }
            let key = SetupDiOpenDevRegKey(devices, &device, DWORD(DICS_FLAG_GLOBAL), 0, DWORD(DIREG_DEV), access)
            guard let key, key != HKEY(bitPattern: -1) else { throw WindowsError.api("Open native mouse settings", GetLastError()) }
            do { targets.append(Target(device: device, key: key, name: property(DWORD(SPDRP_DEVICEDESC), devices, &device), vertical: try direction(key, "FlipFlopWheel"), horizontal: try direction(key, "FlipFlopHScroll"))) }
            catch { RegCloseKey(key); throw error }
        }
        return try body(devices, &targets)
    }
    static func current() throws -> State {
        try withTargets(access: REGSAM(KEY_QUERY_VALUE)) { _, targets in
            State(devices: targets.map { ($0.name, ($0.vertical ?? 0) == 1, ($0.horizontal ?? 0) == 1) })
        }
    }
    /// Configures physical HID reports in Windows; returns true if a manual reconnect is needed.
    static func configure(vertical: Bool, horizontal: Bool) throws -> Bool {
        guard IsUserAnAdmin() else { throw WindowsError.unsupported("Native mouse configuration requires Windows administrator approval.") }
        let lock = try OwnedHandle(withWideString("Global\\SwiftyToys.MouseConfiguration") { CreateMutexW(nil, false, $0) })
        let locked = WaitForSingleObject(lock.raw, 0)
        guard locked == DWORD(WAIT_OBJECT_0) || locked == 0x80 else { throw WindowsError.unsupported("Another native mouse configuration is running.") }
        defer { ReleaseMutex(lock.raw) }
        return try withTargets(access: REGSAM(KEY_QUERY_VALUE | KEY_SET_VALUE)) { devices, targets in
        guard !targets.isEmpty else { throw WindowsError.unsupported("No supported HID mice connected. Precision Touchpad and vendor drivers retain their own settings.") }
        var changed: [Int] = []
        do {
            for index in targets.indices {
                let target = targets[index]
                guard (target.vertical ?? 0) != (vertical ? 1 : 0) || (target.horizontal ?? 0) != (horizontal ? 1 : 0) else { continue }
                changed.append(index)
                if (target.vertical ?? 0) != (vertical ? 1 : 0) { try setDirection(target.key, "FlipFlopWheel", vertical ? 1 : 0) }
                if (target.horizontal ?? 0) != (horizontal ? 1 : 0) { try setDirection(target.key, "FlipFlopHScroll", horizontal ? 1 : 0) }
            }
        } catch {
            let failure = error
            var restorationFailed = false
            for index in changed {
                let target = targets[index]
                for (name, value) in [("FlipFlopWheel", target.vertical), ("FlipFlopHScroll", target.horizontal)] {
                    do { try setDirection(target.key, name, value) }
                    catch { restorationFailed = true }
                }
            }
            if restorationFailed { throw WindowsError.api("Mouse state requires verification after failed rollback", 3) }
            throw failure
        }
        var reconnect = false
        for index in changed { if !restart(devices, &targets[index].device) { reconnect = true } }
        return reconnect
        }
    }
    /// Checks real registry access on a disposable per-user key, without touching a device.
    static func selfCheck() throws {
        guard supports(service: "mouhid", hardwareID: "HID\\VID_046D&PID_C547"),
            !supports(service: "vendor", hardwareID: "HID\\VID_046D&PID_C547"),
            !supports(service: "mouhid", hardwareID: "HID\\VID_05AC&PID_0265"),
            !supports(service: "mouhid", hardwareID: "HID\\{00001124}_VID&0001004C_PID&0265"),
            !supports(service: "mouhid", hardwareID: "HID\\VID&01004C_PID&0324"),
            !supports(service: "mouhid", hardwareID: "HID\\first-id HID\\VID_05AC&PID_030E") else { throw WindowsError.unsupported("Native mouse device scope failed.") }
        let name = "Software\\SwiftyToys\\Tests\\Mouse-\(GetCurrentProcessId())-\(GetTickCount64())"
        var key: HKEY?
        let created = withWideString(name) { RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, REGSAM(KEY_QUERY_VALUE | KEY_SET_VALUE), nil, &key, nil) }
        guard created == ERROR_SUCCESS, let key else { throw WindowsError.api("Create mouse registry test", DWORD(created)) }
        defer { RegCloseKey(key); _ = withWideString(name) { RegDeleteKeyW(HKEY_CURRENT_USER, $0) } }
        guard try direction(key, "FlipFlopWheel") == nil else { throw WindowsError.unsupported("Mouse flag was not initially absent.") }
        try setDirection(key, "FlipFlopWheel", 1); try setDirection(key, "FlipFlopHScroll", 0)
        guard try direction(key, "FlipFlopWheel") == 1, try direction(key, "FlipFlopHScroll") == 0 else { throw WindowsError.unsupported("Mouse DWORD flags failed.") }
        try setDirection(key, "FlipFlopWheel", 0); try setDirection(key, "FlipFlopHScroll", nil)
        guard try direction(key, "FlipFlopWheel") == 0, try direction(key, "FlipFlopHScroll") == nil else { throw WindowsError.unsupported("Mouse flag restoration failed.") }
        do { try setDirection(key, "FlipFlopWheel", 2); throw WindowsError.unsupported("Invalid mouse direction accepted.") }
        catch let error as WindowsError { guard String(describing: error).containsText("must be 0 or 1") else { throw error } }
        Console.writeLine("PASS: native mouse scope, registry DWORDs, missing values, restoration and invalid direction rejection")
    }
    static func apply(owner: HWND, vertical: Bool, horizontal: Bool) throws {
        let arguments = "--configure-mouse \(vertical ? 1 : 0) \(horizontal ? 1 : 0)"
        let destination = MessageDestination(owner)
        let flags = (vertical ? 1 : 0) | (horizontal ? 2 : 0)
        let ownerAddress = UInt(bitPattern: owner)
        _ = try NativeThread(name: "SwiftyToys native mouse configuration") {
        let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
        guard initialized >= 0 else { _ = destination.post(mouseScrollResultMessage, value: 1, data: flags); return }
        defer { CoUninitialize() }
        var execution = SHELLEXECUTEINFOW()
        execution.cbSize = DWORD(MemoryLayout<SHELLEXECUTEINFOW>.size)
        execution.fMask = 0x140 // SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC
        execution.hwnd = HWND(bitPattern: ownerAddress)
        execution.nShow = Int32(SW_HIDE)
        let launched = withWideString("runas") { verb in
            withWideString(executablePath()) { file in
                withWideString(arguments) { parameters in
                    execution.lpVerb = verb; execution.lpFile = file; execution.lpParameters = parameters
                    return ShellExecuteExW(&execution)
                }
            }
        }
        guard launched else {
            _ = destination.post(mouseScrollResultMessage, value: GetLastError() == DWORD(ERROR_CANCELLED) ? 1223 : 1, data: flags)
            return
        }
        do { try MouseScrollOperation(process: execution.hProcess, destination: destination, flags: flags).wait() }
        catch { _ = destination.post(mouseScrollResultMessage, value: 1, data: flags) }
        }
    }
}
