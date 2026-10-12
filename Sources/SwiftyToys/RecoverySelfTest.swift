// SPDX-License-Identifier: MIT

import BrightnessCore

/// Pure mapping checks: never reads a local lease or calls a display API.
func testRecoveryStateMapping() throws {
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
    guard try ColorLease.decode(hardware.encoded()) == hardware else { throw WindowsError.unsupported("Hardware brightness recovery mapping failed.") }
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
}
