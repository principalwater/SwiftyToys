// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

private struct MonitorSearch {
    var device: String
    var monitor: HMONITOR?
}
/// Serializes native DDC operations from the display executor and explicit diagnostics.
private func withDDCLock<Result>(_ body: () throws -> Result) throws -> Result {
    let lock = try OwnedHandle(withWideString("Local\\SwiftyToys.DDC") { CreateMutexW(nil, false, $0) })
    let result = WaitForSingleObject(lock.raw, 2000)
    guard result == DWORD(WAIT_OBJECT_0) || result == 0x80 else { throw WindowsError.unsupported("Physical brightness is busy.") }
    defer { ReleaseMutex(lock.raw) }
    return try body()
}
/// Physical brightness dims the entire monitor, including hardware and application cursors.
final class HardwareBrightnessSession {
    private let handle: HANDLE?
    let original: DWORD
    private let minimum: DWORD
    private let maximum: DWORD
    private var applied: DWORD?
    init(output: DisplayOutput) throws {
        let values = try withDDCLock { () throws -> (HANDLE?, DWORD, DWORD, DWORD) in
            guard output.isPhysical, !output.isHDR, !output.isCloned,
                let monitor = monitorForDevice(output.device) else { throw WindowsError.unsupported("Select one physical SDR display.") }
            var count: DWORD = 0
            guard GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count), count == 1 else {
                throw WindowsError.unsupported("Hardware brightness needs one unambiguous physical monitor.")
            }
            var physical = PHYSICAL_MONITOR()
            guard GetPhysicalMonitorsFromHMONITOR(monitor, 1, &physical) else {
                throw WindowsError.api("Open physical monitor", GetLastError())
            }
            // DXVA2 supplies an opaque monitor token; this driver returns zero.
            // Successful retrieval plus a valid native brightness query establish usability.
            let handle = physical.hPhysicalMonitor
            var minimum: DWORD = 0; var current: DWORD = 0; var maximum: DWORD = 0
            guard GetMonitorBrightness(handle, &minimum, &current, &maximum), maximum > minimum,
                current >= minimum, current <= maximum else {
                DestroyPhysicalMonitor(handle)
                throw WindowsError.unsupported("Monitor does not expose a valid native brightness range.")
            }
            return (handle, minimum, current, maximum)
        }
        handle = values.0; minimum = values.1; original = values.2; maximum = values.3; applied = original
    }
    deinit { DestroyPhysicalMonitor(handle) }
    private func write(_ value: DWORD) throws {
        guard value >= minimum, value <= maximum else { throw WindowsError.unsupported("Saved physical brightness is outside the monitor range.") }
        try withDDCLock {
            applied = nil // A failed readback must not suppress the following rollback write.
            guard SetMonitorBrightness(handle, value) else { throw WindowsError.api("Set physical brightness", GetLastError()) }
            var low: DWORD = 0; var current: DWORD = 0; var high: DWORD = 0
            guard GetMonitorBrightness(handle, &low, &current, &high), current == value else {
                throw WindowsError.unsupported("Physical brightness readback did not match the requested value.")
            }
            applied = value
        }
    }
    func apply(_ level: BrightnessLevel) throws {
        let value = level.hardwareValue(in: minimum...maximum)
        if value != applied { try write(value) }
    }
    func invalidate() { applied = nil }
    func restore() throws { try write(original) }
    func restoreSaved(_ value: DWORD) throws { try write(value) }
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
/// Read-only DDC capability check; never changes physical brightness.
func hardwareBrightnessInfo(displayID: String) throws -> String {
    return try withDDCLock {
    guard let output = try discoverDisplays().first(where: { $0.id == displayID && $0.isPhysical && !$0.isCloned }),
        let monitor = monitorForDevice(output.device) else { return "Selected physical output disconnected" }
    var count: DWORD = 0
    guard GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count), count > 0, count <= 16 else { return "DDC/CI unavailable" }
    var monitors = Array(repeating: PHYSICAL_MONITOR(), count: Int(count))
    guard GetPhysicalMonitorsFromHMONITOR(monitor, count, &monitors) else { return "DDC/CI unavailable" }
    defer { DestroyPhysicalMonitors(count, &monitors) }
    return monitors.map { physical in
        var minimum: DWORD = 0; var current: DWORD = 0; var maximum: DWORD = 0
        let read = GetMonitorBrightness(physical.hPhysicalMonitor, &minimum, &current, &maximum)
        return wideString(physical.szPhysicalMonitorDescription) + (read ? ": brightness \(current), range \(minimum)...\(maximum)" : ": brightness query unsupported")
    }.joined(separator: "\n")
    }
}
