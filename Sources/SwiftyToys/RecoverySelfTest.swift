// SPDX-License-Identifier: MIT

import BrightnessCore

/// Pure mapping checks: never reads a local lease or calls a display API.
func testRecoveryStateMapping() throws {
    guard monitorBrightnessLevel(0, minimum: 0, maximum: 65535)?.percent == 0,
        monitorBrightnessLevel(65535, minimum: 0, maximum: 65535)?.percent == 100,
        monitorBrightnessLevel(49161, minimum: 0, maximum: 65535)?.percent == 75,
        monitorBrightnessLevel(175, minimum: 100, maximum: 200)?.percent == 75,
        monitorBrightnessLevel(UInt32.max / 2, minimum: 0, maximum: UInt32.max)?.percent == 50,
        monitorBrightnessLevel(99, minimum: 100, maximum: 200) == nil,
        monitorBrightnessLevel(201, minimum: 100, maximum: 200) == nil,
        monitorBrightnessLevel(0, minimum: 0, maximum: 0) == nil else {
        throw WindowsError.unsupported("Physical brightness readback scaling or validation failed.")
    }
    guard monitorAutomaticBrightness(1, maximum: 2) == false,
        monitorAutomaticBrightness(2, maximum: 2) == true,
        monitorAutomaticBrightness(0, maximum: 2) == nil,
        monitorAutomaticBrightness(0x82, maximum: 0xff) == nil,
        monitorAutomaticBrightness(2, maximum: 3) == nil else {
        throw WindowsError.unsupported("Nonstandard sensor values must not become a monitor mode.")
    }
    let applied = try BrightnessLevel(60)
    guard !needsBrightnessApply(applied, lastApplied: applied),
        needsBrightnessApply(try BrightnessLevel(65), lastApplied: applied),
        needsBrightnessApply(applied, lastApplied: nil) else {
        throw WindowsError.unsupported("Idle brightness caching suppressed a changed, refreshed or rebound level.")
    }
    func output(id: String = "physical", device: String = "DISPLAY", low: UInt32 = 1,
        high: Int32 = 0, source: UInt32 = 0, target: UInt32 = 1,
        physical: Bool = true, cloned: Bool = false, hdr: Bool = false) -> DisplayOutput {
        DisplayOutput(id: id, name: "Test", device: device, adapterLow: low, adapterHigh: high,
            source: source, target: target, isPhysical: physical, isCloned: cloned, isHDR: hdr)
    }
    let bound = output()
    guard sameDisplayBinding(bound, output()), sameDisplayBinding(bound, output(device: "display")) else {
        throw WindowsError.unsupported("Unchanged display binding was rejected.")
    }
    for replacement in [output(id: "another"), output(device: "another"), output(low: 2),
        output(high: 1), output(source: 1), output(target: 2), output(physical: false),
        output(cloned: true), output(hdr: true)] {
        guard !sameDisplayBinding(bound, replacement) else {
            throw WindowsError.unsupported("Changed display binding retained a cached session.")
        }
    }
    for backend in ["compositor", "composition"] {
        let lease = ColorLease(owner: 1, started: 1, displayID: "physical", backend: backend,
            amdID: nil, brightness: nil, contrast: nil, gamma: nil)
        let decoded = try ColorLease.decode(lease.encoded())
        guard decoded == lease, decoded.restoresCursorVisibility == (backend == "compositor") else {
            throw WindowsError.unsupported("Legacy/new composition cursor-ownership recovery check failed.")
        }
    }
    let native = ColorLease(
        owner: UInt32.max, started: UInt64.max, displayID: "display/🍎\\\"",
        backend: "native", amdID: nil, brightness: nil, contrast: nil, gamma: GammaRamp().array)
    guard try ColorLease.decode(native.encoded()) == native else {
        throw WindowsError.unsupported("Native lease mapping changed its baseline or timestamp.")
    }
    guard native.checkpointAction(current: nil) == .persist,
        native.checkpointAction(current: native) == .reuse,
        !missingRecoveryIsComplete(expected: native, restored: false),
        missingRecoveryIsComplete(expected: native, restored: true),
        missingRecoveryIsComplete(expected: nil, restored: false) else {
        throw WindowsError.unsupported("Missing recovery checkpoint was confused with completed restoration.")
    }
    var changedRamp = native.gamma!
    changedRamp[0] = changedRamp[0] == 0 ? 1 : 0
    for (key, value) in [
        ("owner", StateField.unsigned(1)), ("started", .unsigned(1)),
        ("displayID", .string("another display")), ("backend", .string("amd")),
        ("amdID", .string("another adapter")), ("brightness", .signed(50)),
        ("contrast", .signed(75)), ("gamma", .words(changedRamp)),
    ] {
        var replacement = try StateJSON.decode(native.encoded())
        replacement[key] = value
        let changed = try ColorLease.decode(StateJSON.encode(replacement))
        guard changed != native, native.checkpointAction(current: changed) == .conflict else {
            throw WindowsError.unsupported("Recovery accepted a replaced lease: \(key).")
        }
    }
    let hardware = ColorLease(owner: 1, started: 1, displayID: "physical", backend: "hardware", amdID: nil, brightness: 73, contrast: nil, gamma: nil)
    for lease in [native, hardware] {
        guard lease.canDefer(connectedIDs: ["replacement"]),
            !lease.canDefer(connectedIDs: [lease.displayID]) else {
            throw WindowsError.unsupported("Connected display recovery was deferred or replacement was blocked.")
        }
    }
    let global = ColorLease(owner: 1, started: 1, displayID: "missing", backend: "compositor",
        amdID: nil, brightness: nil, contrast: nil, gamma: nil)
    guard !global.canDefer(connectedIDs: []) else {
        throw WindowsError.unsupported("Global cursor recovery must finish before display replacement.")
    }
    guard try ColorLease.decode(hardware.encoded()) == hardware else { throw WindowsError.unsupported("Hardware brightness recovery mapping failed.") }
    for enabled in [false, true] {
        var automatic = hardware
        automatic.automaticBrightness = enabled
        guard try ColorLease.decode(automatic.encoded()) == automatic else {
            throw WindowsError.unsupported("Original monitor sensor mode was lost from recovery.")
        }
    }
    var invalidAutomatic = try StateJSON.decode(hardware.encoded())
    invalidAutomatic["automaticBrightness"] = .signed(2)
    var invalidAutomaticRejected = false
    do { _ = try ColorLease.decode(StateJSON.encode(invalidAutomatic)) } catch { invalidAutomaticRejected = true }
    guard invalidAutomaticRejected else { throw WindowsError.unsupported("Invalid sensor recovery value accepted.") }
    var invalidHardware = try StateJSON.decode(hardware.encoded())
    invalidHardware["brightness"] = .signed(-1)
    var hardwareRejected = false
    do { _ = try ColorLease.decode(StateJSON.encode(invalidHardware)) } catch is WindowsError { hardwareRejected = true }
    guard hardwareRejected else { throw WindowsError.unsupported("Invalid hardware recovery level accepted.") }
    let amd = ColorLease(
        owner: 1, started: 638_952_000_000_000_001, displayID: "display", backend: "amd",
        amdID: "adapter/display", brightness: -50, contrast: 100, gamma: nil)
    var fields = try StateJSON.decode(amd.encoded())
    fields["gamma"] = .null
    guard try ColorLease.decode(StateJSON.encode(fields)) == amd else {
        throw WindowsError.unsupported("AMD lease mapping did not preserve absent/null fields.")
    }
    for (key, value) in [
        ("owner", StateField.unsigned(UInt64(UInt32.max) + 1)),
        ("version", .unsigned(2)), ("brightness", .string("5")), ("backend", .string("unknown")),
    ] {
        var invalid = fields
        invalid[key] = value
        var rejected = false
        do { _ = try ColorLease.decode(StateJSON.encode(invalid)) } catch is WindowsError { rejected = true }
        guard rejected else { throw WindowsError.unsupported("Invalid recovery field was accepted: \(key).") }
    }
    for id in [String(repeating: "x", count: 4096), String(repeating: "\u{0301}", count: 17000)] {
        let invalid = ColorLease(
            owner: 1, started: 1, displayID: id, backend: "native", amdID: nil,
            brightness: nil, contrast: nil, gamma: native.gamma)
        var rejected = false
        do { _ = try invalid.encoded() } catch is WindowsError { rejected = true }
        guard rejected else { throw WindowsError.unsupported("Writer produced an unreadable recovery lease.") }
    }
    let state = DisplayState(
        level: try BrightnessLevel(75), device: "\\\\.\\DISPLAY1", backend: "native", connected: true)
    guard try DisplayState.decode(state.encoded()) == state else {
        throw WindowsError.unsupported("Display status mapping changed its schema.")
    }
    for enabled in [false, true] {
        var automatic = state
        automatic.automaticBrightness = enabled
        automatic.hardwareLevel = try BrightnessLevel(100)
        guard try DisplayState.decode(automatic.encoded()) == automatic,
            automatic.level.percent == 75, automatic.displayedLevel.percent == 100 else {
            throw WindowsError.unsupported("Automatic brightness status mapping failed.")
        }
    }
    for invalid in [StateField.string("75"), .unsigned(101)] {
        var fields = try StateJSON.decode(state.encoded())
        fields["hardwareLevel"] = invalid
        var rejected = false
        do { _ = try DisplayState.decode(StateJSON.encode(fields)) } catch { rejected = true }
        guard rejected else { throw WindowsError.unsupported("Invalid physical brightness status accepted.") }
    }
}

/// Synthetic files only; does not open a monitor or read the user's calibration.
func testDeferredRecoveryStorage(directory: String) throws {
    let lease = ColorLease(owner: 1, started: 1, displayID: "old/display:🍎", backend: "hardware",
        amdID: nil, brightness: 73, contrast: nil, gamma: nil)
    let source = directory + "\\active.json"
    let destination = try ColorLease.deferredPath(displayID: lease.displayID, directory: directory)
    defer { try? NativeFiles.remove(source); try? NativeFiles.remove(destination) }
    guard destination != (try ColorLease.deferredPath(displayID: "new/display", directory: directory)) else {
        throw WindowsError.unsupported("Different display recovery paths collided.")
    }
    let different = ColorLease(owner: 2, started: 2, displayID: lease.displayID, backend: "hardware",
        amdID: nil, brightness: 40, contrast: nil, gamma: nil)
    try NativeFiles.write(lease.encoded(), to: source)
    try NativeFiles.write(different.encoded(), to: destination)
    var rejected = false
    do { try deferRecoveryFile(lease, from: source, to: destination) } catch { rejected = true }
    guard rejected, try ColorLease.decode(NativeFiles.read(source)) == lease,
        try ColorLease.decode(NativeFiles.read(destination)) == different else {
        throw WindowsError.unsupported("Deferral overwrote another calibration.")
    }
    try NativeFiles.remove(destination)
    try deferRecoveryFile(lease, from: source, to: destination)
    guard try !NativeFiles.exists(source), try ColorLease.decode(NativeFiles.read(destination)) == lease else {
        throw WindowsError.unsupported("Disconnected calibration was not preserved.")
    }
    // Retry after interruption with two identical checkpoints.
    try NativeFiles.write(lease.encoded(), to: source)
    try deferRecoveryFile(lease, from: source, to: destination)
    guard try !NativeFiles.exists(source), try ColorLease.decode(NativeFiles.read(destination)) == lease else {
        throw WindowsError.unsupported("Interrupted calibration deferral was not recoverable.")
    }
}
