// SPDX-License-Identifier: MIT

import WinSDK
import WindowsDisplayABI

private struct MonitorSearch {
    var device: String
    var monitor: HMONITOR?
}
func monitorForDevice(_ device: String) -> HMONITOR? {
    guard !device.isEmpty else { return nil }
    var search = MonitorSearch(device: device)
    _ = withUnsafeMutablePointer(to: &search) { pointer in
        EnumDisplayMonitors(
            nil, nil,
            { monitor, _, _, data in
                guard let pointer = UnsafeMutablePointer<MonitorSearch>(bitPattern: Int(data)), let monitor else {
                    return true
                }
                var info = MONITORINFOEXW()
                info.cbSize = DWORD(MemoryLayout<MONITORINFOEXW>.size)
                let success = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: MONITORINFO.self, capacity: 1) { GetMonitorInfoW(monitor, $0) }
                }
                if success && equalWindowsNames(wideString(info.szDevice), pointer.pointee.device) {
                    pointer.pointee.monitor = monitor
                }
                return true
            }, LPARAM(Int(bitPattern: pointer)))
    }
    return search.monitor
}
/// Short-lived DDC handles are acquired only for the selected, physical output.
/// This runs on a separate thread from UI, keyboard input and gamma updates.
func ensureHardwareMaximum(displayID: String) throws -> String {
    guard let output = try discoverDisplays().first(where: { $0.id == displayID && $0.isPhysical && !$0.isCloned }),
        let monitor = monitorForDevice(output.device)
    else { return "Selected output disconnected" }
    var count: DWORD = 0
    guard GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count), count > 0, count <= 16 else {
        return "DDC/CI unavailable"
    }
    var monitors = Array(repeating: PHYSICAL_MONITOR(), count: Int(count))
    guard GetPhysicalMonitorsFromHMONITOR(monitor, count, &monitors) else { return "DDC/CI unavailable" }
    defer { DestroyPhysicalMonitors(count, &monitors) }
    var allMaximum = true
    for physical in monitors {
        var minimum: DWORD = 0
        var current: DWORD = 0
        var maximum: DWORD = 0
        var read = false
        for _ in 0..<3 {
            if GetMonitorBrightness(physical.hPhysicalMonitor, &minimum, &current, &maximum) {
                read = true
                break
            }
            Sleep(40)
        }
        guard read, maximum > minimum else {
            allMaximum = false
            continue
        }
        if current != maximum {
            var set = false
            for _ in 0..<3 {
                if SetMonitorBrightness(physical.hPhysicalMonitor, maximum) {
                    set = true
                    break
                }
                Sleep(40)
            }
            if !set { set = SetVCPFeature(physical.hPhysicalMonitor, 0x10, maximum) }
            Sleep(80)
            if !set || !GetMonitorBrightness(physical.hPhysicalMonitor, &minimum, &current, &maximum)
                || current != maximum
            {
                allMaximum = false
            }
        }
    }
    return allMaximum ? "100% physical backlight" : "DDC/CI maximum not confirmed"
}
