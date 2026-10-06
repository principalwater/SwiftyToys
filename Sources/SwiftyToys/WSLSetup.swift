// SPDX-License-Identifier: MIT
import WinSDK

/// Package installation precedes Windows restart and per-user Linux registration.
/// Query only native metadata; never start Linux to render settings.
struct WSLSetup {
    let runtimeInstalled: Bool
    let ubuntuInstalled: Bool
    let restartPending: Bool
    let distributions: [LinuxDistribution]

    var title: String {
        if !distributions.isEmpty { return "Choose a Linux distribution" }
        if restartPending { return "Windows restart pending" }
        if ubuntuInstalled { return "Ubuntu first launch required" }
        if runtimeInstalled { return "WSL installed; add Linux" }
        return "Set up WSL + Ubuntu"
    }
    var detail: String {
        if !distributions.isEmpty {
            return
                "Linux distributions are registered for this Windows user.\nHomebrew needs WSL 2 and a non-root Linux user."
        }
        if restartPending {
            return ubuntuInstalled
                ? "Windows has a restart pending. If WSL setup requested it, restart first.\nThen open Ubuntu, finish Linux setup and refresh this page."
                : "Windows has a restart pending. If WSL setup requested it, restart first.\nThen install Ubuntu for this Windows user and refresh this page."
        }
        if ubuntuInstalled {
            return
                "Ubuntu is installed but has not completed its first launch.\nOpen Ubuntu, create your Linux user, then refresh this page."
        }
        if runtimeInstalled {
            return
                "The WSL package is installed; no Linux distribution is registered yet.\nInstall Ubuntu, complete its first launch, then refresh this page."
        }
        return
            "Install WSL components first and restart Windows if requested.\nThen install Ubuntu for this Windows user and complete its first launch."
    }
    static func current() throws -> WSLSetup {
        let runtime = try hasPackage("MicrosoftCorporationII.WindowsSubsystemForLinux_8wekyb3d8bbwe")
        let ubuntu = try hasPackage("CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc")
        var key: HKEY?
        let result = withWideString(
            "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending"
        ) {
            RegOpenKeyExW(HKEY_LOCAL_MACHINE, $0, 0, REGSAM(0x20119), &key)  // KEY_READ | KEY_WOW64_64KEY
        }
        if let key { RegCloseKey(key) }
        guard result == ERROR_SUCCESS || result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND else {
            throw WindowsError.api("Read Windows restart state", DWORD(result))
        }
        return WSLSetup(
            runtimeInstalled: runtime, ubuntuInstalled: ubuntu,
            restartPending: result == ERROR_SUCCESS, distributions: LinuxDistribution.installed())
    }
    private static func hasPackage(_ family: String) throws -> Bool {
        var count: UINT32 = 0
        var length: UINT32 = 0
        let result = withWideString(family) { GetPackagesByPackageFamily($0, &count, nil, &length, nil) }
        guard result == ERROR_SUCCESS || result == ERROR_INSUFFICIENT_BUFFER else {
            throw WindowsError.api("Read installed WSL packages", DWORD(result))
        }
        return count > 0
    }
    static func install(owner: HWND?) throws {
        try openInstaller(arguments: "--install --no-distribution", elevated: true, owner: owner)
    }
    static func installUbuntu(owner: HWND?) throws {
        try openInstaller(arguments: "--install --no-launch -d Ubuntu", elevated: false, owner: owner)
    }
    private static func openInstaller(arguments: String, elevated: Bool, owner: HWND?) throws {
        // Fixed command only. /d disables AutoRun; pause keeps diagnostics visible without leaving an admin shell.
        // Ubuntu package installation and first launch both stay in the current user's profile.
        let wsl = try systemExecutable("wsl.exe")
        try shellOpen(
            systemExecutable("cmd.exe"), arguments: "/d /s /c \"\"\(wsl)\" \(arguments) & pause\"",
            elevated: elevated, owner: owner)
    }
    static func openUbuntu() throws {
        // Activate the current user's official Ubuntu package, including first-time registration.
        try shellOpen("shell:AppsFolder\\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc!ubuntu")
    }
    static func selfCheck() throws {
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw WindowsError.unsupported("WSL setup check failed: " + message) }
        }
        let missing = WSLSetup(runtimeInstalled: false, ubuntuInstalled: false, restartPending: true, distributions: [])
        try expect(
            missing.detail.starts(with: "Windows has a restart pending."),
            "an unrelated restart must not imply WSL installation")
        let installed = WSLSetup(runtimeInstalled: true, ubuntuInstalled: true, restartPending: true, distributions: [])
        try expect(installed.title == "Windows restart pending", "installed packages before reboot")
        let firstLaunch = WSLSetup(
            runtimeInstalled: true, ubuntuInstalled: true, restartPending: false, distributions: [])
        try expect(firstLaunch.title == "Ubuntu first launch required", "package without registered Linux")
        let runtime = WSLSetup(runtimeInstalled: true, ubuntuInstalled: false, restartPending: false, distributions: [])
        try expect(runtime.title == "WSL installed; add Linux", "runtime without distro")
        let fixturePath = "Software\\SwiftyToys.WSLTest-\(GetCurrentProcessId())-\(GetTickCount64())"
        var opened: HKEY?
        let created = withWideString(fixturePath) {
            RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, REGSAM(0x2001F), nil, &opened, nil)
        }
        guard created == ERROR_SUCCESS, let key = opened else {
            throw WindowsError.api("Create WSL test fixture", DWORD(created))
        }
        defer {
            RegCloseKey(key)
            _ = withWideString(fixturePath) { RegDeleteKeyW(HKEY_CURRENT_USER, $0) }
        }
        func write(_ name: String, _ value: DWORD) throws {
            var value = value
            let result = withWideString(name) { name in
                withUnsafeBytes(of: &value) {
                    RegSetValueExW(
                        key, name, 0, DWORD(REG_DWORD), $0.baseAddress!.assumingMemoryBound(to: BYTE.self), 4)
                }
            }
            guard result == ERROR_SUCCESS else { throw WindowsError.api("Write WSL fixture", DWORD(result)) }
        }
        try write("Version", 2)
        try expect(LinuxDistribution.wslVersion(in: key) == 0, "missing flags must not use filesystem Version")
        let modes: [(DWORD, UInt32)] = [(0x7, 1), (0xF, 2), (0x8, 2), (0, 1)]
        for (flags, version) in modes {
            try write("Flags", flags)
            try expect(
                LinuxDistribution.wslVersion(in: key) == version, "WSL mode flag independent of filesystem Version")
        }
        var malformed: DWORD = 8
        let invalid = withWideString("Flags") { name in
            withUnsafeBytes(of: &malformed) {
                RegSetValueExW(key, name, 0, DWORD(REG_BINARY), $0.baseAddress!.assumingMemoryBound(to: BYTE.self), 4)
            }
        }
        guard invalid == ERROR_SUCCESS else { throw WindowsError.api("Write malformed WSL fixture", DWORD(invalid)) }
        try expect(LinuxDistribution.wslVersion(in: key) == 0, "binary flags must not be treated as a DWORD")
        let user = LinuxDistribution(name: "Ubuntu", version: 2)
        try expect(
            user.canInstallHomebrew && !LinuxDistribution(name: "Legacy", version: 1).canInstallHomebrew,
            "WSL 2 readiness")
        let ready = WSLSetup(
            runtimeInstalled: false, ubuntuInstalled: false, restartPending: true, distributions: [user])
        try expect(ready.title == "Choose a Linux distribution", "registered inbox/imported WSL without Store packages")
        Console.writeLine(
            "PASS: WSL setup stages, native registry VM-mode flags and WSL 2 readiness; temporary fixture removed, no WSL setting changed"
        )
    }
}
