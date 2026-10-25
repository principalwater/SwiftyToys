// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK

struct DisplayState: Sendable, Equatable {
    let level: BrightnessLevel
    let device: String
    let backend: String
    let connected: Bool
    var automaticBrightness: Bool? = nil
    var hardwareLevel: BrightnessLevel? = nil
    var displayedLevel: BrightnessLevel { hardwareLevel ?? level }
    func encoded() -> [UInt8] {
        StateJSON.encode([
            "level": .unsigned(UInt64(level.percent)), "device": .string(device),
            "backend": .string(backend), "connected": .bool(connected),
            "automaticBrightness": automaticBrightness.map(StateField.bool) ?? .null,
            "hardwareLevel": hardwareLevel.map { .unsigned(UInt64($0.percent)) } ?? .null,
        ])
    }
    static func decode(_ bytes: [UInt8]) throws -> Self {
        let fields = try StateJSON.decode(bytes)
        guard let percentage = fields["level"]?.integer, let device = fields["device"]?.string,
            let backend = fields["backend"]?.string, let connected = fields["connected"]?.bool
        else { throw WindowsError.unsupported("Invalid display status.") }
        let automatic = fields["automaticBrightness"]
        guard automatic == nil || automatic == .null || automatic?.bool != nil else {
            throw WindowsError.unsupported("Invalid automatic brightness status.")
        }
        let hardware = fields["hardwareLevel"]
        guard hardware == nil || hardware == .null || hardware?.integer != nil else {
            throw WindowsError.unsupported("Invalid physical brightness status.")
        }
        return Self(level: try BrightnessLevel(percentage), device: device, backend: backend,
            connected: connected, automaticBrightness: automatic?.bool,
            hardwareLevel: try hardware?.integer.map { try BrightnessLevel($0) })
    }
}
private final class NativeBackend {
    let session: NativeGammaSession
    init(_ output: DisplayOutput) throws { session = try NativeGammaSession(output: output, emulateOwnership: true) }
}

func sameDisplayBinding(_ bound: DisplayOutput, _ current: DisplayOutput) -> Bool {
    bound.isPhysical && current.isPhysical && !bound.isCloned && !current.isCloned
        && !bound.isHDR && !current.isHDR && bound.id == current.id
        && bound.adapterLow == current.adapterLow && bound.adapterHigh == current.adapterHigh
        && bound.source == current.source && bound.target == current.target
        && equalWindowsNames(bound.device, current.device)
}

func needsBrightnessApply(_ target: BrightnessLevel, lastApplied: BrightnessLevel?) -> Bool {
    lastApplied != target
}

/// All driver state and recovery I/O are isolated to one dedicated executor.
actor DisplayController {
    nonisolated let executor: DisplayExecutor
    nonisolated let commandAdmission = DisplayCommandAdmission()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var settings: Settings
    private var output: DisplayOutput?
    private var amd: AMDControl?
    private var amdOutput: AMDOutput?
    private var native: NativeBackend?
    private var hardware: HardwareBrightnessSession?
    private var baselineBrightness = 0
    private var baselineContrast = 100
    private var level: BrightnessLevel
    private var watchdog = false
    private var exiting = false
    private var lastState: DisplayState?
    private var lastApplied: BrightnessLevel?
    private var hardwareLevel: BrightnessLevel?
    private var recoveryConflict = false
    private var pendingRecovery: ColorLease?
    private var recoveryOutputs: [String] = []

    init(settings: Settings) throws {
        executor = try DisplayExecutor()
        self.settings = settings
        level = settings.brightness
    }
    // Pending actor jobs keep this controller alive. Stop its executor only when
    // those jobs have finished, including replies that outlive a UI timeout.
    deinit { executor.stop() }

    private func lease() throws -> ColorLease {
        guard let output else { throw WindowsError.unsupported("Output is disconnected.") }
        return ColorLease(
            owner: GetCurrentProcessId(), started: try processStartTicks(GetCurrentProcess()), displayID: output.id,
            backend: hardware != nil ? "hardware" : native == nil ? "amd" : "native", amdID: amdOutput?.legacyID,
            brightness: hardware.map { Int($0.original) } ?? (native == nil ? baselineBrightness : nil),
            contrast: hardware == nil && native == nil ? baselineContrast : nil, gamma: native?.session.original.array,
            automaticBrightness: hardware?.originalAutomaticBrightness)
    }

    /// Restore through the device that already owns the source before releasing
    /// it. Opening a second EMULATED owner fails on some WDDM drivers.
    @discardableResult
    private func restoreAndRelease() throws -> Bool {
        lastApplied = nil
        hardwareLevel = nil
        var expected: ColorLease?
        var checkpointReady = false
        var cachedRestored = false
        do {
            guard !recoveryConflict else {
                throw WindowsError.unsupported("Recovery ownership changed. Its saved state is preserved; restart SwiftyToys before retrying.")
            }
            let hadBackend = hardware != nil || native != nil || (amd != nil && amdOutput != nil)
            expected = hadBackend ? try lease() : pendingRecovery
            pendingRecovery = expected
            if let expected {
                switch expected.checkpointAction(current: try ColorLease.read()) {
                case .persist: try expected.write()
                case .reuse: break
                case .conflict:
                    recoveryConflict = true
                    throw WindowsError.unsupported("Recovery ownership changed. Its saved state is preserved; restart SwiftyToys before retrying.")
                }
                if !watchdog { try startWatchdog(); watchdog = true }
            }
            checkpointReady = true
            if hadBackend {
                guard let output, try discoverDisplays().contains(where: { sameDisplayBinding(output, $0) }) else {
                    throw WindowsError.unsupported("The display binding changed; recovery must reopen the saved target.")
                }
            }
            if let hardware {
                try hardware.restore()
            } else if let native {
                try native.session.restore()
            } else if let amd, let amdOutput {
                try amd.set(amdOutput, brightness: baselineBrightness, contrast: baselineContrast)
            }
            if hadBackend, let expected {
                guard try ColorLease.remove(expected) else {
                    recoveryConflict = true
                    throw WindowsError.unsupported("Recovery ownership changed. Its saved state is preserved; restart SwiftyToys before retrying.")
                }
                cachedRestored = true
                pendingRecovery = nil
            }
        } catch { Diagnostics.write("restore through current device: \(error)") }
        native = nil
        hardware = nil
        amdOutput = nil
        amd = nil
        output = nil
        // Never recover a lease that unexpectedly replaced this live session's baseline.
        guard checkpointReady, !recoveryConflict else { return false }
        // A disconnected device or failed restore retains its lease for retry.
        let restored = try recoverOutput(expected: expected, expectedRestored: cachedRestored)
        if restored { pendingRecovery = nil }
        else if let expected, let saved = try ColorLease.read(), saved != expected { recoveryConflict = true }
        return restored
    }

    private func bind() throws {
        guard !recoveryConflict else {
            throw WindowsError.unsupported("Recovery ownership changed. Its saved state is preserved; restart SwiftyToys before retrying.")
        }
        let outputs = try discoverDisplays()
        let eligible = outputs.filter { $0.isPhysical && !$0.isCloned && !$0.isHDR }
        let recoverableIDs = eligible.map(\.id).sorted()
        if recoveryOutputs != recoverableIDs {
            try recoverDeferredOutputs(eligible)
            recoveryOutputs = recoverableIDs
        }
        var saved = settings.targetID
        if saved == nil, let legacy = settings.legacyTarget {
            guard let driver = try? AMDControl() else {
                _ = try restoreAndRelease()
                return
            }
            if let match = try driver.enumerate().first(where: { $0.legacyID == legacy }) {
                saved = eligible.first(where: { equalWindowsNames($0.device, match.device) })?.id
            }
            if saved == nil {
                _ = try restoreAndRelease()
                return
            }
        }
        let id: String
        do { id = try selectDisplay(from: eligible.map(\.candidate), savedID: saved).id } catch BrightnessError
            .displayDisconnected
        {
            _ = try restoreAndRelease()
            return
        }
        let selected = eligible.first { $0.id == id }!
        if let output, sameDisplayBinding(output, selected) {
            if hardware != nil || native != nil {
                self.output = selected
                return
            }
            if let amd, let previous = amdOutput,
                let refreshed = try amd.enumerate().first(where: {
                    $0.legacyID == previous.legacyID
                        && equalWindowsNames($0.device, selected.device)
                })
            {
                amdOutput = refreshed
                self.output = selected
                return
            }
        }
        // Preserve a disconnected target's calibration before binding its replacement.
        if try !restoreAndRelease() {
            guard try deferDisconnectedRecovery(outputs: outputs, expected: pendingRecovery) else { return }
            pendingRecovery = nil
        }
        if settings.backend == "hardware" {
            hardware = try HardwareBrightnessSession(output: selected)
        } else if settings.backend != "amd" {
            do { native = try NativeBackend(selected) } catch {
                Diagnostics.write("native backend unavailable: \(error)")
            }
        }
        if hardware == nil, native == nil, settings.backend != "native", let driver = try? AMDControl(),
            let match = try driver.enumerate().first(where: {
                equalWindowsNames($0.device, selected.device)
            })
        {
            baselineBrightness = try driver.get(match, type: 1)
            baselineContrast = try driver.get(match, type: 2)
            amd = driver
            amdOutput = match
        }
        guard hardware != nil || native != nil || (amd != nil && amdOutput != nil) else {
            throw WindowsError.unsupported(
                "Driver supports neither native WDDM gamma nor the AMD fallback on this output.")
        }
        output = selected
        if settings.targetID == nil { try settings.select(id) }
        Diagnostics.write("brightness backend: \(backendName)")
    }

    private var backendName: String {
        hardware != nil ? "native DDC/CI" : native == nil ? "AMD RGB gain" : "native WDDM gamma"
    }

    private func checkpoint() throws {
        let original = try lease()
        if let saved = try ColorLease.read() {
            guard saved == original else {
                recoveryConflict = true
                throw WindowsError.unsupported("Another output still has pending recovery; brightness remains unchanged.")
            }
        } else { try original.write() }
        if !watchdog { try startWatchdog(); watchdog = true }
    }

    private func apply(_ target: BrightnessLevel) throws {
        guard !exiting else { throw WindowsError.unsupported("SwiftyToys is shutting down.") }
        try bind()
        if output != nil {
            if !needsBrightnessApply(target, lastApplied: lastApplied) { level = target; return }
            try checkpoint()  // Persist recovery before the first display write.
            do {
                if let hardware {
                    try hardware.apply(target, automatic: output.flatMap { settings.automaticBrightness(for: $0.id) })
                } else if let native {
                    try native.session.apply(target)
                } else if let amd, let amdOutput {
                    let gain = AMDColorGain(brightness: Int32(baselineBrightness), contrast: Int32(baselineContrast))
                        .scaled(to: target)
                    try amd.set(amdOutput, brightness: Int(gain.brightness), contrast: Int(gain.contrast))
                }
                if try target != level
                    || !NativeFiles.exists(NativeFiles.path("software.txt"))
                {
                    try settings.saveBrightness(target)
                }
                lastApplied = target
            } catch {
                // Both halves of an AMD update and native ramps are transactional.
                if let hardware {
                    try? hardware.apply(level)
                } else if let native {
                    try? native.session.apply(level)
                } else if let amd, let amdOutput {
                    let previous = AMDColorGain(
                        brightness: Int32(baselineBrightness), contrast: Int32(baselineContrast)
                    ).scaled(to: level)
                    try? amd.set(amdOutput, brightness: Int(previous.brightness), contrast: Int(previous.contrast))
                }
                _ = try? restoreAndRelease()  // Rebuild removed/reset devices on the next request.
                throw error
            }
        }
        if output == nil && target != level { try settings.saveBrightness(target) }
        level = target
    }

    func command(_ command: Int, value: Int = 0) throws -> DisplayState {
        let relativeBase = command == 2 ? try hardware?.currentLevel() : nil
        // An automatic adjustment makes a cached manual write an invalid reason to skip a user action.
        if command == 1 || command == 2, hardware != nil {
            lastApplied = nil
            hardware?.invalidateBrightness()
        }
        switch command {
        case 0: try apply(level)
        case 3:
            settings = try Settings()
            try restoreAndRelease()
            try apply(level)
        case 4:
            // Idle ticks never retry an unresolved physical recovery or open a driver.
            if output != nil { try apply(level) }
            else if !settings.ddcEnabled, (try ColorLease.read())?.backend != "hardware" { try apply(level) }
        case 5:
            lastApplied = nil
            let current = try Settings()
            if current.backend != settings.backend || current.targetID != settings.targetID {
                settings = current
                try restoreAndRelease()
            } else { hardware?.invalidate() }
            try apply(level)
        case 8:
            // A resolution change does not reset a physical monitor's backlight.
            // bind() still reopens changed targets and preserves their recovery state.
            if hardware == nil { lastApplied = nil }
            try apply(level)
        case 7:
            guard value == 0 || value == 1, settings.ddcEnabled else {
                throw WindowsError.unsupported("Enable hardware brightness before changing automatic brightness.")
            }
            try bind()
            guard let output, let hardware, let previous = hardware.automaticBrightness else {
                throw WindowsError.unsupported("This display does not expose supported automatic brightness.")
            }
            try checkpoint()
            do {
                try hardware.setAutomaticBrightness(value == 1)
                try settings.setAutomaticBrightness(value == 1, displayID: output.id)
            } catch {
                do { try hardware.setAutomaticBrightness(previous) }
                catch { _ = try? restoreAndRelease() }
                throw error
            }
        case 1: try apply(BrightnessLevel(max(0, min(100, value))))
        case 2:
            try apply((relativeBase ?? level).adjusted(by: value))
        default: break
        }
        if let hardware {
            if command != 4 || value == 1 {
                hardwareLevel = nil
                do { hardwareLevel = try hardware.currentLevel() }
                catch { Diagnostics.write("physical brightness readback: \(error)") }
            }
        } else { hardwareLevel = nil }
        let state = DisplayState(
            level: level, device: output?.device ?? "",
            backend: output == nil ? "unavailable" : backendName,
            connected: output != nil, automaticBrightness: hardware?.automaticBrightness,
            hardwareLevel: hardwareLevel)
        if state != lastState {
            try NativeFiles.write(state.encoded(), to: NativeFiles.path("display-status.json"))
            lastState = state
        }
        return state
    }

    func setColorProfile(fileName: String?, displayID: String) throws -> DisplayState {
        guard !exiting else { throw WindowsError.unsupported("SwiftyToys is shutting down.") }
        try bind()
        guard let selected = output, selected.id == displayID else {
            throw WindowsError.unsupported("The selected display changed. Refresh color profiles before applying.")
        }
        // A profile must never become the baseline of an older dimming lease.
        let releasedSoftware = hardware == nil
        if releasedSoftware {
            guard try restoreAndRelease() else {
                throw WindowsError.unsupported("Restore display brightness before changing its color profile. Recovery state is preserved.")
            }
        }
        do {
            try WindowsColorProfiles.setDefault(fileName: fileName, output: selected)
        } catch {
            let profileError = String(describing: error)
            do { if releasedSoftware { try apply(level) } }
            catch {
                throw WindowsError.unsupported(profileError + "\n\nBrightness recovery did not finish. Use Reconnect display; its recovery state is preserved.")
            }
            throw WindowsError.unsupported(profileError)
        }
        do { return try command(0) }
        catch {
            throw WindowsError.unsupported("Windows saved the color profile, but brightness could not be reapplied. Use Reconnect display.\n" + String(describing: error))
        }
    }

    func shutdown() -> Bool {
        exiting = true
        do { return try restoreAndRelease() }
        catch {
            Diagnostics.write("restore pending: \(error)")
            return false
        }
    }
}
