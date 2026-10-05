// SPDX-License-Identifier: MIT

import BrightnessCore

/// Pure mapping checks: never reads a local lease or calls a display API.
func testRecoveryStateMapping() throws {
    let native = ColorLease(
        owner: UInt32.max, started: UInt64.max, displayID: "display/🍎\\\"",
        backend: "native", amdID: nil, brightness: nil, contrast: nil, gamma: GammaRamp().array)
    guard try ColorLease.decode(native.encoded()) == native else {
        throw WindowsError.unsupported("Native lease mapping changed its baseline or timestamp.")
    }
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
        ("version", .unsigned(2)), ("brightness", .string("5")),
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
