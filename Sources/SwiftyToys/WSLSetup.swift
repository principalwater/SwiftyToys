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
        if restartPending && (runtimeInstalled || ubuntuInstalled) { return "Windows restart pending" }
        if ubuntuInstalled { return "Ubuntu first launch required" }
        if runtimeInstalled { return "WSL installed; add Linux" }
        return "Install WSL + Ubuntu"
    }
    var detail: String {
        if !distributions.isEmpty {
            return
                "Linux distributions are registered for this Windows user.\nHomebrew needs WSL 2 and a non-root Linux user."
        }
        if restartPending && (runtimeInstalled || ubuntuInstalled) {
            return
                "WSL setup packages are installed. Windows has a restart pending.\nRestart Windows, then open Ubuntu to finish Linux setup and refresh this page."
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
            "Install WSL and Ubuntu, then follow the terminal instructions.\nWindows may require a restart before Linux setup can finish."
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
    /// Resolve trusted Windows executables, independent of PATH or the working directory.
    static func executable(_ name: String) throws -> String {
        var directory = [WCHAR](repeating: 0, count: 32768)
        let size = GetSystemDirectoryW(&directory, UINT(directory.count))
        guard size > 0, size < directory.count else {
            throw WindowsError.api("Resolve Windows system directory", GetLastError())
        }
        return String(decoding: directory.prefix(Int(size)), as: UTF16.self) + "\\" + name
    }
    static func install(owner: HWND?) throws {
        // Fixed command only. /d disables AutoRun; pause keeps diagnostics visible without leaving an admin shell.
        // Linux first launch is a separate, unelevated action in the current user's profile.
        let wsl = try executable("wsl.exe")
        try shellOpen(
            executable("cmd.exe"), arguments: "/d /s /c \"\"\(wsl)\" --install --no-launch -d Ubuntu & pause\"",
            elevated: true, owner: owner)
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
        try expect(missing.title == "Install WSL + Ubuntu", "an unrelated restart must not imply WSL installation")
        let installed = WSLSetup(runtimeInstalled: true, ubuntuInstalled: true, restartPending: true, distributions: [])
        try expect(installed.title == "Windows restart pending", "installed packages before reboot")
        let firstLaunch = WSLSetup(
            runtimeInstalled: true, ubuntuInstalled: true, restartPending: false, distributions: [])
        try expect(firstLaunch.title == "Ubuntu first launch required", "package without registered Linux")
        let runtime = WSLSetup(runtimeInstalled: true, ubuntuInstalled: false, restartPending: false, distributions: [])
        try expect(runtime.title == "WSL installed; add Linux", "runtime without distro")
        let user = LinuxDistribution(name: "Ubuntu", version: 2)
        try expect(
            user.canInstallHomebrew && !LinuxDistribution(name: "Legacy", version: 1).canInstallHomebrew,
            "WSL 2 readiness")
        let ready = WSLSetup(
            runtimeInstalled: false, ubuntuInstalled: false, restartPending: true, distributions: [user])
        try expect(ready.title == "Choose a Linux distribution", "registered inbox/imported WSL without Store packages")
        Console.writeLine(
            "PASS: WSL package/restart/first-launch states and WSL 2 readiness; no system changes")
    }
}
