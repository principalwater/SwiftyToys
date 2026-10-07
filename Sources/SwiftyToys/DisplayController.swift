// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK

struct DisplayState: Sendable, Equatable {
    let level: BrightnessLevel
    let device: String
    let backend: String
    let connected: Bool
    func encoded() -> [UInt8] {
        StateJSON.encode([
            "level": .unsigned(UInt64(level.percent)), "device": .string(device),
            "backend": .string(backend), "connected": .bool(connected),
        ])
    }
    static func decode(_ bytes: [UInt8]) throws -> Self {
        let fields = try StateJSON.decode(bytes)
        guard let percentage = fields["level"]?.integer, let device = fields["device"]?.string,
            let backend = fields["backend"]?.string, let connected = fields["connected"]?.bool
        else { throw WindowsError.unsupported("Invalid display status.") }
        return Self(level: try BrightnessLevel(percentage), device: device, backend: backend, connected: connected)
    }
}
private final class NativeBackend {
    let session: NativeGammaSession
    init(_ output: DisplayOutput) throws { session = try NativeGammaSession(output: output, emulateOwnership: true) }
}
/// All driver state and recovery I/O are isolated to one dedicated executor.
actor DisplayController {
    nonisolated let executor: DisplayExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var settings: Settings
    private var output: DisplayOutput?
    private var amd: AMDControl?
    private var amdOutput: AMDOutput?
    private var native: NativeBackend?
    private var hardware: HardwareBrightnessSession?
    private var compositor: SoftwareCursorDimmingSession?
    private var baselineBrightness = 0
    private var baselineContrast = 100
    private var level: BrightnessLevel
    private var watchdog = false
    private var exiting = false
    private var lastState: DisplayState?

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
            backend: compositor != nil ? "compositor" : hardware != nil ? "hardware" : native == nil ? "amd" : "native", amdID: amdOutput?.legacyID,
            brightness: hardware.map { Int($0.original) } ?? (native == nil && compositor == nil ? baselineBrightness : nil),
            contrast: hardware == nil && native == nil && compositor == nil ? baselineContrast : nil, gamma: native?.session.original.array)
    }

    /// Restore through the device that already owns the source before releasing
    /// it. Opening a second EMULATED owner fails on some WDDM drivers.
    @discardableResult
    private func restoreAndRelease() throws -> Bool {
        do {
            let hadBackend = compositor != nil || hardware != nil || native != nil || (amd != nil && amdOutput != nil)
            if let compositor {
                try compositor.restore()
            } else if let hardware {
                try hardware.restore()
            } else if let native {
                try native.session.restore()
            } else if let amd, let amdOutput {
                try amd.set(amdOutput, brightness: baselineBrightness, contrast: baselineContrast)
            }
            if hadBackend, let output, let saved = try ColorLease.read(), saved.owner == GetCurrentProcessId(),
                saved.displayID == output.id
            {
                try ColorLease.remove()
            }
        } catch { Diagnostics.write("restore through current device: \(error)") }
        native = nil
        hardware = nil
        compositor = nil
        amdOutput = nil
        amd = nil
        output = nil
        // A disconnected device or failed restore retains its lease for retry.
        return try recoverOutput()
    }

    private func bind() throws {
        // Validate hints before discovery: a failed query must restore the cursor,
        // not leave a stale viewport active because discovery threw first.
        try compositor?.validateTopology()
        let outputs = try discoverDisplays()
        let eligible = outputs.filter { $0.isPhysical && !$0.isCloned && !$0.isHDR }
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
        if let output, output.id == selected.id, output.adapterLow == selected.adapterLow,
            output.adapterHigh == selected.adapterHigh, output.source == selected.source
        {
            if hardware != nil || native != nil || compositor?.isValid == true {
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
        // A reconnected target must first recover its original calibration.
        guard try restoreAndRelease() else { return }  // Never overwrite a pending lease for another target.
        if settings.backend == "compositor" {
            compositor = try SoftwareCursorDimmingSession(output: selected)
        } else if settings.backend == "hardware" {
            hardware = try HardwareBrightnessSession(output: selected)
        } else if settings.backend != "amd" {
            do { native = try NativeBackend(selected) } catch {
                Diagnostics.write("native backend unavailable: \(error)")
            }
        }
        if compositor == nil, hardware == nil, native == nil, settings.backend != "native", let driver = try? AMDControl(),
            let match = try driver.enumerate().first(where: {
                equalWindowsNames($0.device, selected.device)
            })
        {
            baselineBrightness = try driver.get(match, type: 1)
            baselineContrast = try driver.get(match, type: 2)
            amd = driver
            amdOutput = match
        }
        guard compositor != nil || hardware != nil || native != nil || (amd != nil && amdOutput != nil) else {
            throw WindowsError.unsupported(
                "Driver supports neither native WDDM gamma nor the AMD fallback on this output.")
        }
        output = selected
        if settings.targetID == nil { try settings.select(id) }
        Diagnostics.write("brightness backend: \(backendName)")
    }

    private var backendName: String {
        compositor != nil ? "Windows compositor (cursor included)" : hardware != nil ? "native DDC/CI" : native == nil ? "AMD RGB gain" : "native WDDM gamma"
    }

    private func apply(_ target: BrightnessLevel) throws {
        guard !exiting else { throw WindowsError.unsupported("SwiftyToys is shutting down.") }
        try bind()
        if output != nil {
            let original = try lease()
            if let saved = try ColorLease.read() {
                guard saved == original else {
                    throw WindowsError.unsupported(
                        "Another output still has pending recovery; brightness remains unchanged.")
                }
            } else if compositor == nil || target.percent < 100 {
                try original.write()
            }  // Persist recovery before the first display write.
            if !watchdog && (compositor == nil || target.percent < 100) {
                try startWatchdog()
                watchdog = true
            }
            do {
                if let compositor {
                    try compositor.apply(target)
                } else if let hardware {
                    try hardware.apply(target)
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
                if compositor != nil, target.percent == 100 { try ColorLease.remove() }
            } catch {
                // Both halves of an AMD update and native ramps are transactional.
                if let compositor {
                    try? compositor.apply(level)
                } else if let hardware {
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
            let current = try Settings()
            if current.backend != settings.backend || current.targetID != settings.targetID {
                settings = current
                try restoreAndRelease()
            } else { hardware?.invalidate() }
            try apply(level)
        case 1: try apply(BrightnessLevel(max(0, min(100, value))))
        case 2: try apply(level.adjusted(by: value))
        default: break
        }
        let state = DisplayState(
            level: level, device: output?.device ?? "",
            backend: output == nil ? "unavailable" : backendName,
            connected: output != nil)
        if state != lastState {
            try NativeFiles.write(state.encoded(), to: NativeFiles.path("display-status.json"))
            lastState = state
        }
        return state
    }

    func shutdown() {
        exiting = true
        do { try restoreAndRelease() } catch { Diagnostics.write("restore: \(error)") }
        native = nil
        hardware = nil
        compositor = nil
        amdOutput = nil
        amd = nil
    }
}
