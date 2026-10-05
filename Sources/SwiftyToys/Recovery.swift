// SPDX-License-Identifier: MIT

import BrightnessCore
import Synchronization
import WinSDK

// Shared with BrightnessCtl: neither app may capture an already dimmed baseline.
let instanceMutex = "Local\\BrightnessCtl.SingleInstance"
let controlWindowTitle = "SwiftyToys.Software.v2"
let brightnessMessage: UINT = 0x8001
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
            contrast: try optional("contrast", { $0.integer }), gamma: try optional("gamma", { $0.words }))
        guard lease.version == 1, lease.displayID.count < 4096, ["amd", "native"].contains(lease.backend) else {
            throw WindowsError.unsupported("Unsupported output recovery state.")
        }
        return lease
    }
    func encoded() throws -> [UInt8] {
        guard version == 1, displayID.count < 4096, ["amd", "native"].contains(backend) else {
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
        let bytes = StateJSON.encode(fields)
        guard bytes.count < 32768 else { throw WindowsError.unsupported("Invalid recovery-state size.") }
        return bytes
    }
    func write() throws { try NativeFiles.write(encoded(), to: NativeFiles.path("scanout-lease.json")) }
    static func remove() throws { try NativeFiles.remove(NativeFiles.path("scanout-lease.json")) }
}
/// Called under the instance mutex before a new backend captures its baseline.
@discardableResult
func recoverOutput(owner: UInt32? = nil, started: UInt64? = nil) throws -> Bool {
    if let lease = try ColorLease.read() {
        if let owner, let started, owner != lease.owner || started != lease.started { return false }
        let outputs = try discoverDisplays()
        guard
            let output = outputs.first(where: { $0.id == lease.displayID && $0.isPhysical && !$0.isHDR && !$0.isCloned }
            )
        else { return false }
        if lease.backend == "amd" {
            let control = try AMDControl()
            guard let id = lease.amdID,
                let amd = try control.enumerate().first(where: {
                    $0.legacyID == id && equalWindowsNames($0.device, output.device)
                }),
                let brightness = lease.brightness, let contrast = lease.contrast
            else { throw WindowsError.unsupported("Invalid AMD recovery state.") }
            try control.set(amd, brightness: brightness, contrast: contrast)
        } else {
            guard let gamma = lease.gamma else { throw WindowsError.unsupported("Missing native recovery ramp.") }
            let ramp = try GammaRamp(samples: gamma)
            let session = try NativeGammaSession(output: output, emulateOwnership: true)
            try session.restoreSaved(ramp)
        }
        try ColorLease.remove()
        Diagnostics.write("recovery: original output color state restored")
    }
    // Preserve the baseline when migrating from the public 0.1.x versions.
    let legacy = try NativeFiles.path("output-color-lease.txt")
    guard try NativeFiles.exists(legacy) else { return true }
    let lines = try NativeFiles.text(legacy).split(whereSeparator: \.isNewline).map(String.init)
    guard lines.count == 7, let brightness = Int(lines[3]), let contrast = Int(lines[4]) else {
        throw WindowsError.unsupported("Invalid legacy recovery state.")
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
