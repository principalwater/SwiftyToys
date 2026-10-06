// SPDX-License-Identifier: MIT

import BrightnessCore
import CRT
import WinSDK
import WindowsDisplayABI

func runCLI(_ args: [String]) throws -> Int32 {
    Console.attach()
    let command = args[0].lowercased()
    if command == "--test-wsl" { try WSLSetup.selfCheck(); return 0 }
    if command == "--test-errors" { try WindowsError.selfCheck(); return 0 }
    if command == "--test-power" { try DesktopPower.selfCheck(); return 0 }
    if command == "--test-keyboard-config" { try KeyboardConfiguration.selfCheck(); return 0 }
    if command == "--wsl-info" {
        let setup = try WSLSetup.current()
        Console.writeLine(setup.title + "\n" + setup.detail)
        Console.writeLine("VMX boot failure: " + (setup.virtualizationBootFailure.map { $0 ? "confirmed" : "not detected" } ?? "unavailable"))
        Console.writeLine("WSL package: \(setup.runtimeInstalled); Ubuntu package: \(setup.ubuntuInstalled); Windows restart pending: \(setup.restartPending); registered Linux distributions: \(setup.distributions.count)")
        return 0
    }
    if command == "--test-driver-trust" { try NativeDriverTrust.selfCheck(); return 0 }
    if command == "--verify-driver-file" {
        guard args.count == 4, args[3] == "apple" || args[3] == "microsoft-hardware" else {
            throw WindowsError.unsupported("Use --verify-driver-file <path> <SHA-256> apple|microsoft-hardware.")
        }
        try NativeDriverTrust.verifyFile(args[1], expected: args[2], signer: args[3] == "apple" ? .apple : .microsoftHardware)
        Console.writeLine("PASS: pinned SHA-256, trusted Authenticode chain and expected publisher"); return 0
    }
    if command == "--test-native-mouse" { try NativeMouseScrolling.selfCheck(); return 0 }
    if command == "--mouse-info" { Console.writeLine(try NativeMouseScrolling.current().summary); return 0 }
    if command == "--driver-info" { Console.writeLine(try BootCampInventory.current().summary); return 0 }
    if command == "--test-driver-info" { BootCampInventory.selfCheck(); return 0 }
    if command == "--test-apple-layouts" { try AppleKeyboardLayouts.selfCheck(); return 0 }
    if command == "--apple-layouts" || command == "--restore-apple-layouts" {
        let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        guard initialized >= 0 else { throw WindowsError.status("Initialize input-profile COM", initialized) }
        defer { CoUninitialize() }
        do {
            if command == "--restore-apple-layouts" { try AppleKeyboardLayouts.restore() }
            else { guard args.count == 2 else { throw WindowsError.unsupported("Use --apple-layouts us|uk.") }; try AppleKeyboardLayouts.use(english: args[1]) }
            if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) { PostMessageW(window, toyActionMessage, 7, 1) }
        } catch {
            if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) { PostMessageW(window, toyActionMessage, 7, 0) }
            throw error
        }
        return 0
    }
    if command == "--hardware-info" {
        guard let id = try Settings().targetID else { throw WindowsError.unsupported("Select a physical display first.") }
        Console.writeLine(try hardwareBrightnessInfo(displayID: id)); return 0
    }
    if command == "backend" {
        let modes = ["auto", "native", "amd", "hardware"]
        guard args.count == 2, let index = modes.firstIndex(of: args[1]),
            let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) else {
            throw WindowsError.unsupported("Use backend auto|native|amd|hardware with SwiftyToys running.")
        }
        _ = try sendResident(window, command: 6, value: index); Console.writeLine("Brightness mode: " + args[1]); return 0
    }
    if command == "--configure-mouse" || command == "--apply-native-mouse" {
        guard args.count == 3, ["0","1"].contains(args[1]), ["0","1"].contains(args[2]) else {
            throw WindowsError.unsupported("Use --configure-mouse / --apply-native-mouse <vertical 0|1> <horizontal 0|1>.")
        }
        if command == "--configure-mouse" {
            do { return try NativeMouseScrolling.configure(vertical: args[1] == "1", horizontal: args[2] == "1") ? 2 : 0 }
            catch WindowsError.api(_, 3) { return 3 }
        }
        guard let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) else { throw WindowsError.unsupported("SwiftyToys resident is not running.") }
        let flags = (args[1] == "1" ? 1 : 0) | (args[2] == "1" ? 2 : 0)
        guard PostMessageW(window, toyActionMessage, 6, LPARAM(flags)) else { throw WindowsError.api("Request native mouse direction", GetLastError()) }
        return 0
    }
    if command == "--version" {
        Console.writeLine("SwiftyToys \(AppVersion.string) (\(AppVersion.implementation))")
        return 0
    }
    if command == "osd" {
        guard args.count == 1 || args.count == 2 else {
            throw WindowsError.unsupported("Use osd custom or osd system.")
        }
        var settings = try Settings()
        if args.count == 2 {
            guard let mode = IndicatorMode(rawValue: args[1].lowercased()) else {
                throw WindowsError.unsupported("Use osd custom or osd system.")
            }
            try settings.setIndicator(mode)
            if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) {
                _ = try sendResident(window, command: 5)
            }
        }
        Console.writeLine(settings.indicator.rawValue)
        return 0
    }
    if command == "--trackpad-info" {
        Console.writeLine(TrackpadStatus.current(localization: Localization()).summary)
        return 0
    }
    if command == "--test-input" {
        try testKeyboardInput()
        return 0
    }
    if command == "--test-worker-wait" { try testWorkerWait(); return 0 }
    if command == "--preview" || command == "--test-ui" {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        try NativeFiles.createDirectory(NativeFiles.directory())
        let preview = try SettingsWindow(
            brightness: 75, keyboard: KeyboardConfiguration(), preview: true, command: { _, _ in "Preview" })
        if command == "--test-ui" {
            try preview.validateLayout()
            Console.writeLine("PASS: all 10 native settings pages, navigation, checkbox toggles and brightness synchronization")
            return 0
        }
        preview.show()
        var message = MSG()
        while BC_GetMessageW(&message, nil, 0, 0) > 0 {
            if !preview.dialogMessage(&message) {
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }
        return 0
    }
    if command == "settings" {
        if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) {
            PostMessageW(window, toyActionMessage, 4, 0)
        } else {
            try startResident()
            Sleep(1000)
            if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) {
                PostMessageW(window, toyActionMessage, 4, 0)
            }
        }
        return 0
    }
    if command == "--test-storage" {
        try testStorage()
        return 0
    }
    if command == "--abi-check" {
        precondition(MemoryLayout<D3DKMT_OPENADAPTERFROMHDC>.size == 24)
        precondition(MemoryLayout<D3DKMT_CREATEDEVICE>.size == 64)
        precondition(MemoryLayout<D3DKMT_SETGAMMARAMP>.size == 32)
        precondition(MemoryLayout<D3DDDI_GAMMA_RAMP_RGB256x3x16>.size == 1536)
        precondition(MemoryLayout<BC_ADLAdapter>.size == 1572)
        precondition(MemoryLayout<BC_ADLDisplayInfo>.size == 552)
        var message = MSG()
        let testWindow = withWideString("STATIC") {
            CreateWindowExW(0, $0, nil, 0, 0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil)
        }
        guard let testWindow else { throw WindowsError.api("Create ABI-check window", GetLastError()) }
        DestroyWindow(testWindow)
        precondition(BC_GetMessageW(&message, testWindow, 0, 0) == -1)
        Console.writeLine("PASS: native SDK layouts and signed message-loop result")
        return 0
    }
    if command == "--watchdog", args.count == 3, let owner = UInt32(args[1]), let started = UInt64(args[2]) {
        try runWatchdog(owner: owner, started: started)
        return 0
    }
    if command == "--probe-native" {
        let lock = try InstanceLock(timeout: 0)
        guard lock.acquired else { throw WindowsError.unsupported("Exit the resident before running a native probe.") }
        let outputs = try discoverDisplays().filter { $0.isPhysical && !$0.isCloned && !$0.isHDR }
        guard outputs.count == 1, let output = outputs.first else {
            throw WindowsError.unsupported("Probe needs exactly one physical SDR output.")
        }
        let session = try NativeGammaSession(output: output, emulateOwnership: true)
        defer { try? session.restore() }
        for percent in [100, 60, 90, 60, 90, 100] {
            try session.apply(BrightnessLevel(percent))
            Console.writeLine("Native scanout: \(percent)%")
            Sleep(4000)
        }
        return 0
    }
    if command == "list" || command == "--list" || command == "select" {
        let displays = try discoverDisplays()
        if command == "select" {
            guard args.count == 2,
                let output = displays.first(where: { equalWindowsNames($0.id, args[1]) }),
                output.isPhysical, !output.isCloned, !output.isHDR
            else {
                throw WindowsError.unsupported(
                    "Use select <output-id> from list; select only an independent physical SDR display.")
            }
            var settings = try Settings()
            try settings.select(output.id)
            if let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) {
                _ = try sendResident(window, command: 3)
            }
            Console.writeLine("Selected \(output.name)")
        } else {
            for output in displays {
                Console.writeLine(
                    "\(output.id)  \(output.name) [physical=\(output.isPhysical), clone=\(output.isCloned), HDR=\(output.isHDR)]"
                )
            }
        }
        return 0
    }
    var operation = 0
    var value = 0
    switch command {
    case "get", "info": operation = 0
    case "rescan": operation = 3
    case "exit": operation = 4
    default:
        guard let parsed = Int(command), (-100...100).contains(parsed) else {
            throw WindowsError.unsupported("Use 0–100, +5, -5, get, info, list, select, osd, rescan, exit.")
        }
        operation = command.hasPrefix("+") || command.hasPrefix("-") ? 2 : 1
        value = parsed
    }
    var window = withWideString(controlWindowTitle) { FindWindowW(nil, $0) }
    if window == nil && operation >= 1 && operation <= 3 {
        try startResident()
        for _ in 0..<150 {
            Sleep(100)
            window = withWideString(controlWindowTitle) { FindWindowW(nil, $0) }
            if window != nil { break }
        }
    }
    guard let window else { throw WindowsError.unsupported("SwiftyToys resident is not running.") }
    let current = try sendResident(window, command: operation, value: value)
    if command == "info" {
        let data = try NativeFiles.read(NativeFiles.path("display-status.json"))
        let state = try DisplayState.decode(data)
        let settings = try Settings()
        Console.writeLine("Version : \(AppVersion.string) (\(AppVersion.implementation))")
        Console.writeLine("Level   : \(current)%")
        Console.writeLine("Backend : \(state.backend)")
        Console.writeLine("Target  : \(state.connected ? state.device : "disconnected; level saved")")
        Console.writeLine("Step    : \(settings.step)%")
        Console.writeLine("OSD     : \(settings.indicator.rawValue)")
        if let id = settings.targetID {
            Console.writeLine("Hardware: \(try hardwareBrightnessInfo(displayID: id))")
        } else {
            Console.writeLine("Hardware: maximum enforcement disabled")
        }
    } else if operation != 4 {
        Console.writeLine(String(current))
    }
    return 0
}
private func sendResident(_ window: HWND, command: Int, value: Int = 0) throws -> Int {
    var result: DWORD_PTR = 0
    let sent = SendMessageTimeoutW(
        window, brightnessMessage, WPARAM(command), LPARAM(value), UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 16000, &result)
    guard sent != 0, result > 0 else {
        throw WindowsError.unsupported("Resident did not apply the requested brightness.")
    }
    return Int(result) - 1
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if !args.isEmpty { exit(try runCLI(args)) }
    let lock = try InstanceLock(timeout: 2000)
    if !lock.acquired { exit(0) }
    for name in ["scanout-lease.json", "output-color-lease.txt"] {
        if try NativeFiles.exists(NativeFiles.legacyDirectory() + "\\" + name) {
            throw WindowsError.unsupported(
                "BrightnessCtl recovery is pending. Run the migration installer after restoring the old resident.")
        }
    }
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
    NativeFlyout.restore()
    do { try recoverOutput() } catch { Diagnostics.write("recovery pending: \(error)") }
    let app = try TrayApplication(settings: Settings())
    defer { app.shutdown() }
    try app.run()
} catch {
    Diagnostics.write("error: \(error)")
    Console.writeLine("SwiftyToys: \(error)")
    exit(1)
}
