// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import Synchronization

let deviceReportMessage: UINT = 0x8034
/// At most one read-only scan per device page; returning to a page uses its cache.
final class SettingsDeviceReports: Sendable {
    private let state = Mutex((busy: Set<Int>(), reports: [Int: (locale: String, text: String)]()))
    func text(_ page: Int, locale: String) -> String? { state.withLock { $0.reports[page].flatMap { $0.locale == locale ? $0.text : nil } } }
    func load(_ page: Int, language: LanguagePack, destination: MessageDestination, refresh: Bool = false) {
        guard state.withLock({ value in
            if value.busy.contains(page) { return false }
            if !refresh, value.reports[page]?.locale == language.locale { return false }
            value.busy.insert(page); return true
        }) else { return }
        do {
            _ = try NativeThread(name: "SwiftyToys device report") { [self] in
                let report: String
                do { report = page == 6 ? TrackpadStatus.current(localization: Localization(pack: language)).summary : try BootCampInventory.current().summary }
                catch { report = String(describing: error) }
                state.withLock { $0.busy.remove(page); $0.reports[page] = (language.locale, report) }
                _ = destination.post(deviceReportMessage, value: page)
            }
        } catch { state.withLock { $0.busy.remove(page) }; Diagnostics.write("device report: \(error)") }
    }
}

/// Read-only Boot Camp driver inventory. It reports installed metadata only: no signature check,
/// no latest-version or compatibility claim, and nothing is modified.
struct BootCampInventory {
    let summary: String

    /// Matches physical PCI/USB nodes only; ROOT/SWD virtual displays and paired Bluetooth nodes never match.
    static func classify(_ hardwareIDs: [String], deviceClass: String) -> String? {
        guard let bus = hardwareIDs.first?.lowercased().split(separator: "\\").first, bus == "pci" || bus == "usb" else { return nil }
        let tokens = hardwareIDs.flatMap { $0.lowercased().split(whereSeparator: { $0 == "\\" || $0 == "&" }) }
        if bus == "pci", tokens.contains("ven_1002"), deviceClass.lowercased() == "display" { return "AMD display" }
        if tokens.contains("ven_14e4") || tokens.contains("vid_0a5c") { return "Broadcom" }
        // PCI SUBSYS_<device><vendor>: the low 16 bits are the subsystem vendor (Apple = 106B).
        if tokens.contains("vid_05ac") || tokens.contains("ven_106b")
            || tokens.contains(where: { $0.hasPrefix("subsys_") && $0.hasSuffix("106b") }) { return "Apple" }
        return nil
    }

    static func current() throws -> BootCampInventory {
        var lines = ["Model: " + model()]
        guard let devices = SetupDiGetClassDevsW(nil, nil, nil, DWORD(DIGCF_PRESENT | DIGCF_ALLCLASSES)),
            devices != HANDLE(bitPattern: -1) else { throw WindowsError.api("Enumerate devices", GetLastError()) }
        defer { SetupDiDestroyDeviceInfoList(devices) }
        for index in 0..<4096 {
            var device = SP_DEVINFO_DATA()
            device.cbSize = DWORD(MemoryLayout<SP_DEVINFO_DATA>.size)
            guard SetupDiEnumDeviceInfo(devices, DWORD(index), &device) else { break }
            let ids = property(DWORD(SPDRP_HARDWAREID), devices, &device)
            guard let kind = classify(ids, deviceClass: property(DWORD(SPDRP_CLASS), devices, &device).first ?? "") else { continue }
            if lines.count > 64 { lines.append("List truncated at 64 devices."); break }
            let name = property(DWORD(SPDRP_FRIENDLYNAME), devices, &device).first
                ?? property(DWORD(SPDRP_DEVICEDESC), devices, &device).first ?? "unnamed"
            let service = property(DWORD(SPDRP_SERVICE), devices, &device).first ?? "none"
            var status: ULONG = 0; var problem: ULONG = 0
            let code = CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == 0 ? String(problem) : "unknown"
            var info = [String](repeating: "unknown", count: 4)
            if let key = SetupDiOpenDevRegKey(devices, &device, DWORD(DICS_FLAG_GLOBAL), 0, DWORD(DIREG_DRV), REGSAM(0x20019)),
                key != HKEY(bitPattern: -1) {
                info = ["ProviderName", "DriverVersion", "DriverDate", "InfPath"].map { registryString(key, $0) ?? "unknown" }
                RegCloseKey(key)
            }
            lines.append("\(kind): \(name)\n  IDs: \(ids.joined(separator: "; "))\n  service=\(service) provider=\(info[0]) version=\(info[1]) date=\(info[2]) inf=\(info[3]) problem=\(code)")
        }
        // ponytail: only PCI/USB nodes, 64 devices; add other buses if a model needs them.
        lines.append("Installed metadata only; signatures and newer compatible drivers are not verified. Use Windows Update or Device Manager.")
        return BootCampInventory(summary: lines.joined(separator: "\n"))
    }

    /// Deterministic and read-only: exercises only the matcher, never the device list.
    static func selfCheck() {
        let amd = ["PCI\\VEN_1002&DEV_679A&SUBSYS_0126106B&REV_00", "PCI\\VEN_1002&DEV_679A"]
        let checks: [([String], String, String?)] = [
            (amd, "Display", "AMD display"),
            (["SWD\\INDIRECTDISPLAY\\VDD", "ROOT\\VEN_1002"], "Display", nil),
            (["PCI\\VEN_1002&DEV_AAB0&SUBSYS_AAB0AAB0"], "MEDIA", nil),
            (["USB\\VID_0A5C&PID_6412"], "Bluetooth", "Broadcom"),
            (["PCI\\VEN_14E4&DEV_43A0"], "Net", "Broadcom"),
            (["USB\\VID_05AC&PID_0265&MI_01"], "HIDClass", "Apple"),
            (["PCI\\VEN_8086&DEV_1C26&SUBSYS_1C26106B"], "USB", "Apple"),
            (["BTHENUM\\{00001124}_VID&0001004C_PID&0265"], "HIDClass", nil),
            (["PCI\\VEN_10DE&DEV_1234&SUBSYS_1234106C"], "Display", nil),
            ([], "", nil),
        ]
        for (ids, deviceClass, expected) in checks {
            precondition(classify(ids, deviceClass: deviceClass) == expected, "Boot Camp ID match failed: \(ids)")
        }
        Console.writeLine("PASS: Boot Camp ID matching accepts physical Apple, Broadcom and AMD display IDs and rejects virtual, Bluetooth and unrelated IDs")
    }

    private static func model() -> String {
        var key: HKEY?
        guard withWideString("HARDWARE\\DESCRIPTION\\System\\BIOS", { RegOpenKeyExW(HKEY_LOCAL_MACHINE, $0, 0, 0x20019, &key) }) == ERROR_SUCCESS,
            let key else { return "unavailable" }
        defer { RegCloseKey(key) }
        return ["SystemManufacturer", "SystemProductName"].map { registryString(key, $0) ?? "unknown" }.joined(separator: " ")
    }
    private static func registryString(_ key: HKEY, _ name: String) -> String? {
        var buffer = Array(repeating: WCHAR(0), count: 256); var size = DWORD(buffer.count * 2)
        var type: DWORD = 0
        let read = withWideString(name) { name in
            buffer.withUnsafeMutableBytes { RegQueryValueExW(key, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
        }
        guard read == ERROR_SUCCESS, type == REG_SZ else { return nil }
        let text = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
        return text.isEmpty ? nil : text
    }
    /// Returns every entry of a REG_SZ/REG_MULTI_SZ device property, bounded to 2048 UTF-16 units.
    private static func property(_ key: DWORD, _ devices: HDEVINFO, _ device: inout SP_DEVINFO_DATA) -> [String] {
        var buffer = Array(repeating: WCHAR(0), count: 2048)
        let read = buffer.withUnsafeMutableBytes {
            SetupDiGetDeviceRegistryPropertyW(devices, &device, key, nil, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count), nil)
        }
        guard read else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
    }
}
