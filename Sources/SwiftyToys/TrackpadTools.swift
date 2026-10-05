// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI
import BrightnessCore

/// Read-only PnP detection. Windows and the separately installed driver own touch processing.
struct TrackpadStatus {
    let summary: String
    static func current(localization: Localization) -> TrackpadStatus {
        guard let devices = SetupDiGetClassDevsW(nil, nil, nil, DWORD(DIGCF_PRESENT | DIGCF_ALLCLASSES)),
            devices != HANDLE(bitPattern: -1) else {
            return TrackpadStatus(summary: localization.text("Device detection is unavailable. Open Windows touchpad settings."))
        }
        defer { SetupDiDestroyDeviceInfoList(devices) }
        var connections = Set<String>()
        var precision = false
        var drivers = Set<String>()
        var problems = Set<DWORD>()
        for index in 0..<4096 {
            var device = SP_DEVINFO_DATA()
            device.cbSize = DWORD(MemoryLayout<SP_DEVINFO_DATA>.size)
            guard SetupDiEnumDeviceInfo(devices, DWORD(index), &device) else { break }
            let ids = property(DWORD(SPDRP_HARDWAREID), devices, &device).lowercased()
            guard (ids.containsText("vid_05ac") || ids.containsText("vid&0001004c")),
                ids.containsText("pid_0265") || ids.containsText("pid&0265") || ids.containsText("pid_0324") || ids.containsText("pid&0324") else { continue }
            let transport = ids.hasPrefix("usb\\") ? "USB" : ids.hasPrefix("bthenum\\") ? "Bluetooth" : nil
            if let transport {
                connections.insert(transport)
                if (transport == "Bluetooth" || ids.containsText("&mi_01")), let driver = driverDescription(devices, &device) { drivers.insert(transport + ": " + driver) }
                var status: ULONG = 0; var problem: ULONG = 0
                if CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == 0, problem != 0 { problems.insert(problem) }
            }
            if ids.containsText("00001124") { connections.insert("Bluetooth") }
            let name = property(DWORD(SPDRP_FRIENDLYNAME), devices, &device)
                + " " + property(DWORD(SPDRP_DEVICEDESC), devices, &device)
            // ponytail: driver names identify candidates; physical gesture testing confirms behavior.
            precision = precision || name.lowercased().containsText("precision")
        }
        guard !connections.isEmpty else {
            return TrackpadStatus(summary: localization.text("No connected Magic Trackpad 2 detected. Connect USB or pair in Windows Bluetooth settings."))
        }
        let connection = connections.sorted().joined(separator: " + ")
        var summary = localization.text("Magic Trackpad • {0}\n{1}", [connection, localization.text(precision
            ? "Precision driver detected. Configure taps, scrolling and gestures in Windows."
            : "Legacy / standard input driver detected. Install a Precision Touchpad driver for gestures.")])
        if !drivers.isEmpty { summary += "\n" + drivers.sorted().joined(separator: " • ") }
        if !problems.isEmpty { summary += "\n" + localization.text("Windows device problem: {0}", [problems.sorted().map(String.init).joined(separator: ", ")]) }
        return TrackpadStatus(summary: summary)
    }
    private static func driverDescription(_ devices: HDEVINFO, _ device: inout SP_DEVINFO_DATA) -> String? {
        let key = SetupDiOpenDevRegKey(devices, &device, DWORD(DICS_FLAG_GLOBAL), 0, DWORD(DIREG_DRV), REGSAM(0x20019))
        guard let key, key != HKEY(bitPattern: -1) else { return nil }
        defer { RegCloseKey(key) }
        func value(_ name: String) -> String {
            var buffer = Array(repeating: WCHAR(0), count: 512); var size = DWORD(buffer.count * 2)
            var type: DWORD = 0
            let read = withWideString(name) { name in
                buffer.withUnsafeMutableBytes { RegQueryValueExW(key, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
            }
            guard read == ERROR_SUCCESS, type == REG_SZ else { return "" }
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
        }
        let description = [value("ProviderName"), value("DriverVersion")].filter { !$0.isEmpty }.joined(separator: " ")
        return description.isEmpty ? nil : description
    }
    private static func property(_ key: DWORD, _ devices: HDEVINFO, _ device: inout SP_DEVINFO_DATA) -> String {
        var buffer = Array(repeating: WCHAR(0), count: 4096)
        let read = buffer.withUnsafeMutableBytes {
            SetupDiGetDeviceRegistryPropertyW(devices, &device, key, nil,
                $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count), nil)
        }
        guard read else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
    static func openInstaller(owner: HWND, source: String = "Apple", rollback: Bool = false, repairBluetooth: Bool = false) throws {
        let path = executablePath().split(separator: "\\").dropLast().joined(separator: "\\") + "\\install-trackpad.ps1"
        guard try NativeFiles.exists(path) else {
            throw WindowsError.unsupported("Install from the complete release ZIP to use the trackpad installer.")
        }
        guard source == "Apple" || source == "Imbushuo" else { throw WindowsError.unsupported("Unknown driver source.") }
        try shellOpen("powershell.exe", arguments: "-NoProfile -ExecutionPolicy Bypass -File " + quoteArgument(path) + " -Source " + source + (rollback ? " -Rollback" : "") + (repairBluetooth ? " -RepairBluetooth" : ""), elevated: true, owner: owner)
    }
}
