// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

private struct MonitorSearch {
    var device: String
    var monitor: HMONITOR?
}

func monitorAutomaticBrightness(_ value: DWORD, maximum: DWORD) -> Bool? {
    guard maximum == 2, value == 1 || value == 2 else { return nil }
    return value == 2
}

func monitorBrightnessLevel(_ value: DWORD, minimum: DWORD, maximum: DWORD) -> BrightnessLevel? {
    guard maximum > minimum, (minimum...maximum).contains(value) else { return nil }
    let span = UInt64(maximum - minimum)
    return try? BrightnessLevel(Int((UInt64(value - minimum) * 100 + span / 2) / span))
}

private func readMonitorAutomaticBrightness(_ handle: HANDLE?) -> Bool? {
    var value: DWORD = 0, maximum: DWORD = 0
    guard GetVCPFeatureAndVCPFeatureReply(handle, 0x66, nil, &value, &maximum) else { return nil }
    return monitorAutomaticBrightness(value, maximum: maximum)
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
    let originalAutomaticBrightness: Bool?
    private(set) var automaticBrightness: Bool?
    private let minimum: DWORD
    private let maximum: DWORD
    private var applied: DWORD?
    init(output: DisplayOutput) throws {
        let values = try withDDCLock { () throws -> (HANDLE?, DWORD, DWORD, DWORD, Bool?) in
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
            // Qualified on Thunderbolt Display; other monitors can pack vendor bits into 0x66.
            let automatic = output.id.lowercased().hasPrefix("\\\\?\\display#app9227#")
                ? readMonitorAutomaticBrightness(handle) : nil
            return (handle, minimum, current, maximum, automatic)
        }
        handle = values.0; minimum = values.1; original = values.2; maximum = values.3; applied = original
        originalAutomaticBrightness = values.4
        automaticBrightness = values.4
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
    func setAutomaticBrightness(_ enabled: Bool) throws {
        guard originalAutomaticBrightness != nil else {
            throw WindowsError.unsupported("This monitor does not expose supported automatic brightness.")
        }
        guard automaticBrightness != enabled else { return }
        try withDDCLock {
            automaticBrightness = nil
            guard SetVCPFeature(handle, 0x66, enabled ? 2 : 1),
                readMonitorAutomaticBrightness(handle) == enabled else {
                throw WindowsError.unsupported("The monitor did not confirm its automatic brightness mode. Its recovery state is preserved.")
            }
            automaticBrightness = enabled
        }
    }
    func apply(_ level: BrightnessLevel, automatic: Bool? = nil) throws {
        if originalAutomaticBrightness != nil, automaticBrightness == nil {
            automaticBrightness = try withDDCLock { readMonitorAutomaticBrightness(handle) }
        }
        if let automatic { try setAutomaticBrightness(automatic) }
        let value = level.hardwareValue(in: minimum...maximum)
        if value != applied { try write(value) }
    }
    func invalidate() { applied = nil; automaticBrightness = nil }
    func invalidateBrightness() { applied = nil }
    /// Reads the actual backlight without changing the user's manual preference or sensor mode.
    func currentLevel() throws -> BrightnessLevel {
        try withDDCLock {
            var low: DWORD = 0, current: DWORD = 0, high: DWORD = 0
            guard GetMonitorBrightness(handle, &low, &current, &high),
                low == minimum, high == maximum,
                let level = monitorBrightnessLevel(current, minimum: low, maximum: high) else {
                throw WindowsError.unsupported("The monitor's current brightness could not be read. Its saved preference is unchanged.")
            }
            return level
        }
    }
    func restore() throws { try restoreSaved(original, automatic: originalAutomaticBrightness) }
    func restoreSaved(_ value: DWORD, automatic: Bool? = nil) throws {
        let previousMode = automatic ?? originalAutomaticBrightness
        if previousMode != nil {
            automaticBrightness = nil // Recovery must not trust a mode cached before an external change.
            try setAutomaticBrightness(false)
        }
        try write(value)
        if let previousMode { try setAutomaticBrightness(previousMode) }
    }
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
