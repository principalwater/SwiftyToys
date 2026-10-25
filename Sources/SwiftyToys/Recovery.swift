// SPDX-License-Identifier: MIT

import BrightnessCore
import Synchronization
import WinSDK

// Shared with BrightnessCtl: neither app may capture an already dimmed baseline.
let instanceMutex = "Local\\BrightnessCtl.SingleInstance"
let controlWindowTitle = "SwiftyToys.Software.v2"
let brightnessMessage: UINT = 0x8001
let brightnessBusyReply: LRESULT = 102 // Successful level replies are 1...101.
let keyStepMessage: UINT = 0x8002
struct InstanceLock: ~Copyable {
    let handle: OwnedHandle
    let acquired: Bool
    init(timeout: DWORD) throws {
        handle = try OwnedHandle(withWideString(instanceMutex) { CreateMutexW(nil, false, $0) })
        let result = WaitForSingleObject(handle.raw, timeout)
        acquired = result == DWORD(WAIT_OBJECT_0) || result == 0x80  // WAIT_ABANDONED_0
    }
    deinit { if acquired { ReleaseMutex(handle.raw) } }
}
func processStartTicks(_ process: HANDLE) throws(WindowsError) -> UInt64 {
    var created = FILETIME()
    var exited = FILETIME()
    var kernel = FILETIME()
    var user = FILETIME()
    guard GetProcessTimes(process, &created, &exited, &kernel, &user) else {
        throw .api("GetProcessTimes", GetLastError())
    }
    return (UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)) + 504_911_232_000_000_000
}
func executablePath() -> String {
    var buffer = Array(repeating: WCHAR(0), count: 32768)
    let count = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
}
enum RecoveryCheckpointAction: Equatable { case persist, reuse, conflict }

func missingRecoveryIsComplete(expected: ColorLease?, restored: Bool) -> Bool {
    expected == nil || restored
}

struct ColorLease: Sendable, Equatable {
    var version = 1
    let owner: UInt32
    let started: UInt64
    let displayID: String
    let backend: String
    let amdID: String?
    let brightness: Int?
    let contrast: Int?
    let gamma: [UInt16]?
    var automaticBrightness: Bool? = nil
    var restoresCursorVisibility: Bool { backend == "compositor" }
    func checkpointAction(current: Self?) -> RecoveryCheckpointAction {
        guard let current else { return .persist }
        return current == self ? .reuse : .conflict
    }

    static func read() throws -> Self? {
        let path = try NativeFiles.path("scanout-lease.json")
        guard try NativeFiles.exists(path) else { return nil }
        return try decode(NativeFiles.read(path))
    }

    static func decode(_ bytes: [UInt8]) throws -> Self {
        let fields = try StateJSON.decode(bytes)
        guard fields["version"]?.integer == 1, let owner = fields["owner"]?.unsigned.flatMap(UInt32.init(exactly:)),
            let started = fields["started"]?.unsigned, let id = fields["displayID"]?.string,
            let backend = fields["backend"]?.string
        else { throw WindowsError.unsupported("Invalid recovery state.") }
        func optional<Value>(_ key: String, _ extract: (StateField) -> Value?) throws -> Value? {
            guard let field = fields[key], field != .null else { return nil }
            guard let value = extract(field) else { throw WindowsError.unsupported("Invalid recovery field: \(key).") }
            return value
        }
        let lease = ColorLease(
            owner: owner, started: started, displayID: id, backend: backend,
            amdID: try optional("amdID", { $0.string }), brightness: try optional("brightness", { $0.integer }),
            contrast: try optional("contrast", { $0.integer }), gamma: try optional("gamma", { $0.words }),
            automaticBrightness: try optional("automaticBrightness", { $0.bool }))
        guard lease.version == 1, lease.displayID.count < 4096, ["amd", "native", "hardware", "compositor", "composition"].contains(lease.backend),
            lease.backend != "hardware" || lease.brightness.flatMap(DWORD.init(exactly:)) != nil,
            lease.automaticBrightness == nil || lease.backend == "hardware" else {
            throw WindowsError.unsupported("Unsupported output recovery state.")
        }
        return lease
    }
    func encoded() throws -> [UInt8] {
        guard version == 1, displayID.count < 4096, ["amd", "native", "hardware", "compositor", "composition"].contains(backend),
            backend != "hardware" || brightness.flatMap(DWORD.init(exactly:)) != nil,
            automaticBrightness == nil || backend == "hardware" else {
            throw WindowsError.unsupported("Unsupported output recovery state.")
        }
        var fields: [String: StateField] = [
            "version": .unsigned(UInt64(version)), "owner": .unsigned(UInt64(owner)),
            "started": .unsigned(started), "displayID": .string(displayID), "backend": .string(backend),
        ]
        if let amdID { fields["amdID"] = .string(amdID) }
        if let brightness { fields["brightness"] = .signed(Int64(brightness)) }
        if let contrast { fields["contrast"] = .signed(Int64(contrast)) }
        if let gamma { fields["gamma"] = .words(gamma) }
        if let automaticBrightness { fields["automaticBrightness"] = .bool(automaticBrightness) }
        let bytes = StateJSON.encode(fields)
        guard bytes.count < 32768 else { throw WindowsError.unsupported("Invalid recovery-state size.") }
        return bytes
    }
    func write() throws { try NativeFiles.write(encoded(), to: NativeFiles.path("scanout-lease.json")) }
    @discardableResult
    static func remove(_ expected: Self) throws -> Bool {
        guard try read() == expected else { return false }
        try NativeFiles.remove(NativeFiles.path("scanout-lease.json"))
        return true
    }

    static func deferredPath(displayID: String, directory: String) throws -> String {
        var remaining = Array(displayID.utf8)[...]
        let hash = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, remaining.count)
            buffer.copyBytes(from: remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            return count
        }
        let name = hash.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        return directory + "\\display-recovery-" + name + ".json"
    }

    func canDefer(connectedIDs: [String]) -> Bool {
        ["native", "amd", "hardware"].contains(backend) && !connectedIDs.contains(displayID)
    }
}

/// Both files remain recoverable after interruption; never replace a different baseline.
func deferRecoveryFile(_ lease: ColorLease, from source: String, to destination: String) throws {
    guard try ColorLease.decode(NativeFiles.read(source)) == lease else {
        throw WindowsError.unsupported("Recovery ownership changed; its saved state was preserved.")
    }
    if try NativeFiles.exists(destination) {
        guard try ColorLease.decode(NativeFiles.read(destination)) == lease else {
            throw WindowsError.unsupported("A different display calibration is already awaiting recovery.")
        }
        try NativeFiles.remove(source)
    } else {
        guard try withWideString(NativeFiles.windowsPath(source), { source in
            try withWideString(NativeFiles.windowsPath(destination)) {
                MoveFileExW(source, $0, DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }) else { throw WindowsError.api("Preserve disconnected display calibration", GetLastError()) }
    }
}

private func mayClaimRecovery(_ lease: ColorLease) throws -> Bool {
    if lease.owner == GetCurrentProcessId() {
        return try lease.started == processStartTicks(GetCurrentProcess())
    }
    guard let raw = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, lease.owner) else {
        let error = GetLastError()
        if error == DWORD(ERROR_INVALID_PARAMETER) { return true }
        throw WindowsError.api("Check display recovery owner", error)
    }
    let process = try OwnedHandle(raw)
    return try processStartTicks(process.raw) != lease.started
        || WaitForSingleObject(process.raw, 0) == DWORD(WAIT_OBJECT_0)
}

/// A replaced monitor must not block a new one, or lose its original calibration.
func deferDisconnectedRecovery(outputs: [DisplayOutput], expected: ColorLease?) throws -> Bool {
    guard let saved = try ColorLease.read(), expected == nil || saved == expected,
        saved.canDefer(connectedIDs: outputs.map(\.id)), try mayClaimRecovery(saved)
    else { return false }
    try deferRecoveryFile(saved, from: NativeFiles.path("scanout-lease.json"),
        to: ColorLease.deferredPath(displayID: saved.displayID, directory: NativeFiles.directory()))
    Diagnostics.write("recovery: disconnected display calibration preserved for reconnection")
    return true
}

/// Only connected outputs are looked up: no directory scan, timer or idle device polling.
func recoverDeferredOutputs(_ outputs: [DisplayOutput]) throws {
    let active = try ColorLease.read()
    for output in outputs {
        let path = try ColorLease.deferredPath(displayID: output.id, directory: NativeFiles.directory())
        guard try NativeFiles.exists(path) else { continue }
        let lease = try ColorLease.decode(NativeFiles.read(path))
        guard lease.displayID == output.id, ["native", "amd", "hardware"].contains(lease.backend),
            active?.displayID != lease.displayID, try mayClaimRecovery(lease),
            try restoreLease(lease, outputs: outputs) else { continue }
        guard try ColorLease.decode(NativeFiles.read(path)) == lease else {
            throw WindowsError.unsupported("Deferred display recovery ownership changed.")
        }
        try NativeFiles.remove(path)
        Diagnostics.write("recovery: reconnected display calibration restored")
    }
}

private func restoreLease(_ lease: ColorLease, outputs: [DisplayOutput]) throws -> Bool {
    guard let output = outputs.first(where: {
        $0.id == lease.displayID && $0.isPhysical && !$0.isHDR && !$0.isCloned
    }) else { return false }
    if lease.backend == "amd" {
        let control = try AMDControl()
        guard let id = lease.amdID,
            let amd = try control.enumerate().first(where: {
                $0.legacyID == id && equalWindowsNames($0.device, output.device)
            }), let brightness = lease.brightness, let contrast = lease.contrast
        else { throw WindowsError.unsupported("Invalid AMD recovery state.") }
        try control.set(amd, brightness: brightness, contrast: contrast)
    } else if lease.backend == "hardware" {
        guard let saved = lease.brightness.flatMap(DWORD.init(exactly:)) else {
            throw WindowsError.unsupported("Invalid hardware recovery state.")
        }
        let session = try HardwareBrightnessSession(output: output)
        try session.restoreSaved(saved, automatic: lease.automaticBrightness)
    } else {
        guard let gamma = lease.gamma else { throw WindowsError.unsupported("Missing native recovery ramp.") }
        let ramp = try GammaRamp(samples: gamma)
        let session = try NativeGammaSession(output: output, emulateOwnership: true)
        try session.restoreSaved(ramp)
    }
    return true
}
/// Called under the instance mutex before a new backend captures its baseline.
@discardableResult
func recoverOutput(owner: UInt32? = nil, started: UInt64? = nil, expected: ColorLease? = nil,
    expectedRestored: Bool = false) throws -> Bool {
    let saved = try ColorLease.read()
    if saved == nil, !missingRecoveryIsComplete(expected: expected, restored: expectedRestored) { return false }
    if let lease = saved {
        if let expected, lease != expected { return false }
        if let owner, let started, owner != lease.owner || started != lease.started { return false }
        if lease.restoresCursorVisibility {
            // Older releases hid the global cursor; new image-only leases never own it.
            try restoreSoftwareCursorVisibility()
        } else if lease.backend != "composition" {
        guard try restoreLease(lease, outputs: discoverDisplays()) else { return false }
        }
        guard try ColorLease.remove(lease) else { return false }
        Diagnostics.write("recovery: original output color state restored")
    }
    // Preserve the baseline when migrating from the public 0.1.x versions.
    let legacy = try NativeFiles.path("output-color-lease.txt")
    guard try NativeFiles.exists(legacy) else { return true }
    let lines = try NativeFiles.text(legacy).split(whereSeparator: \.isNewline).map(String.init)
    guard lines.count == 7, let brightness = Int(lines[3]), let contrast = Int(lines[4]) else {
        throw WindowsError.unsupported("Invalid legacy recovery state.")
    }
    if let expected {
        guard expected.backend == "amd", lines[0] == String(expected.owner), lines[1] == String(expected.started),
            lines[2] == expected.amdID, brightness == expected.brightness, contrast == expected.contrast else { return false }
    }
    if let owner, let started, lines[0] != String(owner) || lines[1] != String(started) { return false }
    let control = try AMDControl()
    guard let output = try control.enumerate().first(where: { $0.legacyID == lines[2] }) else { return false }
    guard
        try discoverDisplays().contains(where: {
            equalWindowsNames($0.device, output.device) && $0.isPhysical && !$0.isHDR
                && !$0.isCloned
        })
    else { return false }
    try control.set(output, brightness: brightness, contrast: contrast)
    try NativeFiles.remove(legacy)
    return true
}
func runWatchdog(owner: UInt32, started: UInt64) throws {
    if let handle = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, owner) {
        let process = try OwnedHandle(handle)
        guard try processStartTicks(process.raw) == started else { return }
        WaitForSingleObject(process.raw, DWORD(INFINITE))
    }
    let lock = try InstanceLock(timeout: 1000)
    guard lock.acquired else { return }
    NativeFlyout.restore(owner: owner, started: started)
    try recoverOutput(owner: owner, started: started)
}
private let watchdogStarted = Mutex(false)
func startWatchdog() throws {
    try watchdogStarted.withLock { started in
        guard !started else { return }
        try spawnWatchdog()
        started = true
    }
}
private func spawnWatchdog() throws {
    let executable = executablePath()
    let ticks = try processStartTicks(GetCurrentProcess())
    var command = Array("\"\(executable)\" --watchdog \(GetCurrentProcessId()) \(ticks)".utf16) + [0]
    var startup = STARTUPINFOW()
    startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
    var process = PROCESS_INFORMATION()
    guard
        withWideString(
            executable,
            { CreateProcessW($0, &command, nil, nil, false, DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &process) })
    else {
        throw WindowsError.api("Create watchdog", GetLastError())
    }
    CloseHandle(process.hThread)
    CloseHandle(process.hProcess)
}
