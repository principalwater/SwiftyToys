// SPDX-License-Identifier: MIT

import BrightnessCore
import SearchCore
import CRT
import WinSDK
import WindowsDisplayABI

func runCLI(_ args: [String]) throws -> Int32 {
    let command = args[0].lowercased()
    if command == "--test-color-profiles" {
        try WindowsColorProfiles.selfCheck()
        try ColorProfileNotifications.selfCheck()
        return 0
    }
    if command == "--install-color-profile" {
        guard args.count == 2 || args.count == 3 else { throw WindowsError.unsupported("Choose one ICC profile to install.") }
        _ = try WindowsColorProfiles.install(file: args[1], expectedName: args.count == 3 ? args[2] : nil)
        return 0
    }
    if command == "--color-profile-info" {
        Console.attach()
        for output in try discoverDisplays().filter({ $0.isPhysical && !$0.isCloned && !$0.isHDR }) {
            let snapshot = try WindowsColorProfiles.snapshot(output: output)
            Console.writeLine("Display: " + output.name + "\nWindows profile: " + snapshot.effective)
            Console.writeLine(snapshot.perUser ? "Scope: current user" : "Scope: system default")
            for profile in snapshot.installed { Console.writeLine("Installed: " + profile.fileName) }
        }
        return 0
    }
    if command == "--apply-color-profile" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --apply-color-profile <installed filename|system-default> with the resident closed.") }
        let lock = try InstanceLock(timeout: 2000)
        guard lock.acquired else { throw WindowsError.unsupported("Close SwiftyToys before using the standalone color-profile command. In the running app, use Brightness settings.") }
        guard try recoverOutput() else { throw WindowsError.unsupported("Display recovery is pending. Restore brightness before changing its profile.") }
        let settings = try Settings()
        let outputs = try discoverDisplays().filter { $0.isPhysical && !$0.isHDR && !$0.isCloned }
        let selected = try selectDisplay(from: outputs.map(\.candidate), savedID: settings.targetID)
        guard let output = outputs.first(where: { $0.id == selected.id }) else {
            throw WindowsError.unsupported("Select one connected physical SDR display.")
        }
        try WindowsColorProfiles.setDefault(fileName: args[1] == "system-default" ? nil : args[1], output: output)
        Console.attach()
        Console.writeLine("Windows color profile: " + (try WindowsColorProfiles.snapshot(output: output)).effective)
        return 0
    }
    if command == "--process-path-fixture" { return 0 }
    if command == "--library-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid library worker request.") }
        return NativeSearchLibraryRuntime.runWorker(pipeName: args[1])
    }
    if command == "--embedding-worker-model" || command == "--embedding-worker-model-test" {
        let testing = command == "--embedding-worker-model-test"
        guard args.count == (testing ? 4 : 3) else { throw WindowsError.unsupported("Invalid model worker request.") }
        let model = try NativeSearchModelCatalog.descriptor(repositoryID: args[testing ? 3 : 2])
        return NativeEmbedding.runWorker(pipeName:args[1],assetDirectory:testing ? args[2] : nil,model:model)
    }
    if command == "--test-model-catalog" { try NativeSearchModelCatalog.selfCheck(); return 0 }
    if command == "--test-search-region" { try NativeSearchRegion.selfCheck(); return 0 }
    if command == "--test-search-rates" { try NativeSearchRates.selfCheck(); return 0 }
    if command == "--test-search-rates-live" { try NativeSearchRates.selfCheckLive(); return 0 }
    if command == "--test-search-library" { try NativeSearchLibraryStore.selfCheck(); return 0 }
    if command == "--test-search-content" { try NativeSearchContentSelfTest.run(); return 0 }
    if command == "--test-search-library-runtime" { try NativeSearchLibraryRuntime.selfCheck(); return 0 }
    if command == "--test-search-library-supervisor" { try NativeSearchLibraryRuntime.selfCheckSupervisor(); return 0 }
    if command == "--test-search-library-models" {
        guard args.count == 3 else { throw WindowsError.unsupported("Use --test-search-library-models <verified Gemma folder> <verified MiniLM folder>.") }
        try NativeSearchLibraryRuntime.selfCheckModels(gemmaDirectory: args[1], miniLMDirectory: args[2]); return 0
    }
    if command == "--search-media-inference-test" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --search-media-inference-test <verified test asset folder>.") }
        try NativeEmbeddingMediaSelfTest.run(assetDirectory: args[1]); return 0
    }
    if command == "--embedding-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid embedding worker request.") }
        return NativeEmbedding.runWorker(pipeName:args[1])
    }
    if command == "--embedding-worker-test" {
        guard args.count == 3 else { throw WindowsError.unsupported("Invalid embedding test worker request.") }
        return NativeEmbedding.runWorker(pipeName:args[1],assetDirectory:args[2])
    }
    if command == "--search-library-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid library query worker request.") }
        return try NativeSearchProcess.runWorker(folder:args[1],library:true)
    }
    if command == "--search-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid search worker request.") }
        return try NativeSearchProcess.runWorker(folder:args[1])
    }
    if command == "--search-rates-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid reference-rate worker request.") }
        return try NativeSearchProcess.runWorker(folder:args[1],rates:true)
    }
    if command == "--search-apps-worker" {
        guard args.count == 2 else { throw WindowsError.unsupported("Invalid application-search worker request.") }
        return try NativeSearchProcess.runWorker(folder:args[1],applications:true)
    }
    if command == "--package-setup" {
        guard args.count == 2 || args.count == 3 else { throw WindowsError.unsupported("Use --package-setup wsl|ubuntu|homebrew [registered distribution].") }
        return try NativePackageSetup.runCLI(action: args[1], distro: args.count == 3 ? args[2] : nil)
    }
    if command == "--installer" {
        guard args.count == 1 || args.count == 2 && args[1] == "--install" else { throw WindowsError.unsupported("Use --installer [--install] from a complete extracted release.") }
        let module = executablePath()
        guard let separator = module.lastIndex(of: "\\") else { throw WindowsError.unsupported("Cannot find installer package.") }
        let setup = try SetupWindow(source: String(module[..<separator]))
        try setup.run(automatic: args.count == 2)
        return 0
    }
    if command == "--trackpad-install" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --trackpad-install apple|imbushuo|rollback|repair-bluetooth.") }
        let setup = try SetupWindow(source: "", trackpadAction: args[1])
        try setup.run(automatic: true)
        return 0
    }
    Console.attach()
    if command == "--preview-search" {
        var preview: NativeSearchWindow?
        weak var panel: NativeSearchWindow?
        defer { preview=nil; NativeSearchBackdrop.shutdown() }
        preview = try NativeSearchWindow(designPreview:true,onQuery:{ query in
            guard let panel else { return }
            let answer=SearchAnswers.quick(query)
            let rows=answer.map { [NativeSearchResult(id:"answer",title:$0.value,subtitle:$0.detail,kind:$0.title)] } ?? []
            _=try? panel.apply(NativeSearchSnapshot(generation:panel.generation,results:rows,
                status:"Read-only design preview",quickAnswer:answer?.value))
        },onActivate:{ _ in },onPreview:{ _ in
            guard let panel else { return }
            _=try? panel.applyPreview(generation:panel.generation,resultID:"answer",title:"Calculator",text:"Local calculation preview")
        },onCopy:{ _ in },onDismiss:{ PostQuitMessage(0) })
        panel=preview
        try preview?.show(query:args.count > 1 ? args[1] : "2+3*4")
        var message=MSG()
        while BC_GetMessageW(&message,nil,0,0)>0 {
            if preview?.dialogMessage(&message) != true { TranslateMessage(&message); DispatchMessageW(&message) }
        }
        return 0
    }
    if command == "--test-search-policy" {
        try NativeSearchProcess.selfCheck()
        try testNativeSearchPolicy()
        return 0
    }
    if command == "--test-search-layering" { try NativeSearchWindow.layeringCheck(); return 0 }
    if command == "--test-search-ui-worker" { try NativeSearchUI.selfCheck(); return 0 }
    if command == "--test-search-ui" {
        // Measure XAML resources before Rich Edit/accessibility can queue unrelated OS work.
        try NativeSearchBackdrop.selfCheck()
        try NativeSearchWindow.selfCheck()
        Console.writeLine("PASS: native Search material lifecycle, high contrast, click-through sizing and terminal shutdown; fixture stayed hidden")
        return 0
    }
    if command == "--test-search-index" { try NativeIndexedSearch.selfCheck(); return 0 }
    if command == "--test-tokenizer" { try GemmaBPETokenizer.selfCheck(); return 0 }
    if command == "--test-embedding" { try NativeEmbedding.selfCheck(); return 0 }
    if command == "--test-embedding-live" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --test-embedding-live <verified test asset folder>.") }
        try NativeEmbedding.selfCheck(assetDirectory:args[1]); return 0
    }
    if command == "--test-embedding-model-live" {
        guard args.count == 3 else { throw WindowsError.unsupported("Use --test-embedding-model-live <verified test asset folder> <owner/model>.") }
        let model = try NativeSearchModelCatalog.descriptor(repositoryID: args[2])
        try NativeEmbedding.selfCheck(assetDirectory: args[1], model: model); return 0
    }
    if command == "--download-search-model" {
        guard args.count == 2, args[1] == "--accept-component-licenses" else { throw WindowsError.unsupported("Read the supplied Microsoft Windows ML Runtime and Apache 2.0 licenses, then use --download-search-model --accept-component-licenses.") }
        try NativeEmbeddingAssets.download(progress:{ value in
            Console.writeLine(value.stage + " " + String(value.completed) + "/" + String(value.total))
        },cancelled:{false})
        Console.writeLine("Optional model downloaded; inference will validate it when used."); return 0
    }
    if command == "--remove-search-model" { try NativeEmbeddingAssets.remove(); Console.writeLine("Optional model removed."); return 0 }
    if command == "--search-query" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --search-query <query> for a read-only search check.") }
        let result = try NativeSearchProcess.query(args[1],cancelled:{false})
        Console.writeLine(result.status)
        for item in result.items { Console.writeLine(item.kind + ": " + item.title) }
        return 0
    }
    if command == "--search-apps" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --search-apps <app name>.") }
        for item in try NativeSearchProcess.applications(args[1],cancelled:{false}) { Console.writeLine(item.title) }
        return 0
    }
    if command == "--search-answer" {
        guard args.count == 2 else { throw WindowsError.unsupported("Use --search-answer <expression or conversion>.") }
        let region = NativeSearchRegion.current()
        var answer = SearchAnswers.quick(args[1], region: region.region)
            .map { NativeSearchRegion.format($0, context: region) }
            ?? NativeSearchClock.quick(args[1], localeName: region.localeName)
        if answer == nil, let conversion = NativeSearchRegion.currencyQuery(args[1], context: region) {
            guard !conversion.to.isEmpty else {
                throw WindowsError.unsupported("Windows has no regional currency. Specify a target currency.")
            }
            if conversion.from == conversion.to {
                answer = SearchAnswer(title: "Currency conversion", value: NativeSearchRegion.number(conversion.amount, context: region) + " " + conversion.to, detail: "Same currency")
            } else {
                let rates = try NativeSearchProcess.rates(from: conversion.from, to: conversion.to, cancelled: { false })
                answer = rates.0.convert(conversion, cached: rates.cached)
                    .map { NativeSearchRegion.format($0, context: region) }
            }
        }
        guard let answer else { throw WindowsError.unsupported("No calculation or supported conversion was recognized.") }
        Console.writeLine(answer.value + "\n" + answer.detail); return 0
    }
    if command == "search" {
        guard let window = withWideString(controlWindowTitle, { FindWindowW(nil,$0) }) else { throw WindowsError.unsupported("Start SwiftyToys before opening Search.") }
        guard MessageDestination(window).post(toyActionMessage,value:10) else { throw WindowsError.api("Open Search",GetLastError()) }
        return 0
    }
    if command == "--test-package-setup" { try NativePackageSetup.selfCheck(); return 0 }
    if command == "--test-installer-ui" { try SetupWindow.selfCheck(); return 0 }
    if command == "--test-trackpad-installer" { try NativeTrackpadInstaller.selfCheck(); return 0 }
    if command == "--test-installer" { try NativeInstaller.selfCheck(); return 0 }
    if command == "--test-shell-integration" { try ShellIntegration.selfCheck(); return 0 }
    if command == "--configure-shortcut" {
        guard args.count == 3 else { throw WindowsError.unsupported("Use --configure-shortcut <Start menu shortcut> <icon file>.") }
        try ShellIntegration.configureShortcut(path: args[1], iconPath: args[2])
        try ShellIntegration.refreshIcons(paths: [executablePath(), args[1], args[2]])
        Console.writeLine("Shortcut identity and icon configured.")
        return 0
    }
    if command == "--test-wsl" { try WSLSetup.selfCheck(); return 0 }
    if command == "--test-errors" { try WindowsError.selfCheck(); return 0 }
    if command == "--test-power" { try DesktopPower.selfCheck(); return 0 }
    if command == "--test-brightness-policy" { try Settings.selfCheck(); return 0 }
    if command == "--test-display-queue" { try DisplayRequestQueue.selfCheck(); return 0 }
    if command == "--test-cursor-policy" { try testSoftwareBrightnessPolicy(); return 0 }
    if command == "--test-keyboard-config" { try KeyboardConfiguration.selfCheck(); return 0 }
    if command == "--test-foreground" { try KeyboardRemapper.selfCheck(); return 0 }
    if command == "--test-indicator-mailboxes" { try testIndicatorMailboxes(); return 0 }
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
        let modes = Settings.modes
        guard args.count == 2, let index = modes.firstIndex(of: args[1]),
            let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) else {
                throw WindowsError.unsupported("Use backend auto|native|amd|hardware with SwiftyToys running.")
        }
        _ = try sendResident(window, command: 6, value: index); Console.writeLine("Brightness mode: " + args[1]); return 0
    }
    if command == "auto-brightness" {
        guard args.count == 2, ["on", "off"].contains(args[1]),
            let window = withWideString(controlWindowTitle, { FindWindowW(nil, $0) }) else {
            throw WindowsError.unsupported("Use auto-brightness on|off with hardware brightness enabled and SwiftyToys running.")
        }
        _ = try sendResident(window, command: 7, value: args[1] == "on" ? 1 : 0)
        Console.writeLine("Automatic brightness: " + args[1]); return 0
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
        try preview.showPreview(page: args.count > 1 ? Int(args[1]) ?? -1 : 0)
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
        Console.writeLine("DDC/CI  : \(settings.ddcEnabled ? "on" : "off (software dimming)")")
        Console.writeLine("Automatic: " + (state.automaticBrightness.map { $0 ? "on" : "off" } ?? "unavailable"))
        if state.automaticBrightness == true { Console.writeLine("Preference: \(state.level.percent)%") }
        if let id = settings.targetID {
            Console.writeLine("Hardware: \(try hardwareBrightnessInfo(displayID: id))")
        } else {
            Console.writeLine("Hardware: no physical display selected")
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
    guard sent != 0 else {
        throw WindowsError.unsupported("Resident did not apply the requested brightness.")
    }
    return try decodeBrightnessReply(result)
}
do {
    try ShellIntegration.configureProcessIdentity()
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
