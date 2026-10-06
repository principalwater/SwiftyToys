// SPDX-License-Identifier: MIT
import WinSDK

final class DesktopTools {
    private let pinProperty = "SwiftyToys.Pinned"
    private var pinned: [UInt: DWORD] = [:]
    private(set) var awakeUntil: UInt64 = 0
    /// Minimizes the selected top-level application window through Windows.
    func minimize(_ window: HWND?) throws {
        guard let window, IsWindow(window), let root = GetAncestor(window, UINT(GA_ROOTOWNER)),
            root != GetShellWindow(), root != GetDesktopWindow() else { throw WindowsError.unsupported("Choose an application window to minimize.") }
        var name = Array(repeating: WCHAR(0), count: 256)
        let count = GetClassNameW(root, &name, Int32(name.count))
        guard !["WorkerW", "Progman", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"].contains(String(decoding: name.prefix(Int(max(0, count))), as: UTF16.self)) else {
            throw WindowsError.unsupported("Choose an application window to minimize.")
        }
        guard ShowWindowAsync(root, Int32(SW_MINIMIZE)) else { throw WindowsError.api("Minimize window", GetLastError()) }
    }
    func togglePin(_ window: HWND?) throws {
        guard let window, IsWindow(window), !IsHungAppWindow(window) else {
            throw WindowsError.unsupported("Select an application window first.")
        }
        var pid: DWORD = 0
        GetWindowThreadProcessId(window, &pid)
        guard pid != GetCurrentProcessId(), window != GetShellWindow(), window != GetDesktopWindow() else {
            throw WindowsError.unsupported("Choose a regular application window.")
        }
        let key = UInt(bitPattern: window)
        if pinned[key] != nil || withWideString(pinProperty, { GetPropW(window, $0) }) != nil {
            guard SetWindowPos(window, HWND(bitPattern: -2), 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
            else { throw WindowsError.api("Unpin window", GetLastError()) }
            pinned.removeValue(forKey: key)
            _ = withWideString(pinProperty) { RemovePropW(window, $0) }
        } else {
            guard GetWindowLongPtrW(window, Int32(GWL_EXSTYLE)) & LONG_PTR(WS_EX_TOPMOST) == 0 else {
                throw WindowsError.unsupported("This window is already topmost.")
            }
            guard SetWindowPos(window, HWND(bitPattern: -1), 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
            else { throw WindowsError.api("Pin window", GetLastError()) }
            guard withWideString(pinProperty, { SetPropW(window, $0, HANDLE(bitPattern:UInt(GetCurrentProcessId()))) }) else {
                SetWindowPos(window, HWND(bitPattern:-2), 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
                throw WindowsError.api("Mark pinned window", GetLastError())
            }
            pinned[key] = pid
        }
    }
    func awake(minutes: Int, display: Bool) throws {
        let flags =
            EXECUTION_STATE(ES_CONTINUOUS) | (minutes > 0 ? EXECUTION_STATE(ES_SYSTEM_REQUIRED) : 0)
            | (minutes > 0 && display ? EXECUTION_STATE(ES_DISPLAY_REQUIRED) : 0)
        guard SetThreadExecutionState(flags) != 0 else { throw WindowsError.api("Keep awake", GetLastError()) }
        awakeUntil = minutes > 0 ? GetTickCount64() + UInt64(min(480, minutes) * 60000) : 0
    }
    func tick() { if awakeUntil > 0, GetTickCount64() >= awakeUntil { try? awake(minutes: 0, display: false) } }
    func stop() {
        try? awake(minutes: 0, display: false)
        for (key, pid) in pinned {
            guard let window = HWND(bitPattern: key), IsWindow(window) else { continue }
            var current: DWORD = 0
            GetWindowThreadProcessId(window, &current)
            if current == pid, withWideString(pinProperty, { GetPropW(window, $0) }) == HANDLE(bitPattern:UInt(GetCurrentProcessId())) {
                SetWindowPos(window, HWND(bitPattern: -2), 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
                _ = withWideString(pinProperty) { RemovePropW(window, $0) }
            }
        }
        pinned.removeAll()
    }
    deinit { stop() }
}

func switchLanguage(in foreground: HWND?) throws {
    try requestLanguage(in: foreground, layouts: configuredLayouts(), mode: "cycle", pair: [])
}
func configuredLayouts() -> [HKL] {
    var registry: HKEY?
    let opened = withWideString("Keyboard Layout\\Preload") {
        RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(0x20019), &registry)
    }
    var layouts: [HKL] = []
    if opened == ERROR_SUCCESS, let registry {
        defer { RegCloseKey(registry) }
        for index in 1...16 {
            var buffer = Array(repeating: WCHAR(0), count: 32)
            var size = DWORD(buffer.count * 2)
            let status = withWideString(String(index)) { name in
                buffer.withUnsafeMutableBytes {
                    RegQueryValueExW(
                        registry, name, nil, nil, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size)
                }
            }
            if status != ERROR_SUCCESS { break }
            if let layout = buffer.withUnsafeBufferPointer({
                LoadKeyboardLayoutW($0.baseAddress, UINT(KLF_SUBSTITUTE_OK | KLF_NOTELLSHELL))
            }) {
                layouts.append(layout)
            }
        }
    }
    return layouts
}
func requestLanguage(in foreground: HWND?, layouts: [HKL], mode: String, pair: [UInt16]) throws {
    guard let foreground else { throw WindowsError.unsupported("No active application.") }
    let thread = GetWindowThreadProcessId(foreground, nil)
    guard let current = GetKeyboardLayout(thread), layouts.count > 1 else {
        throw WindowsError.unsupported("Add at least two Windows input languages.")
    }
    var layouts = layouts
    if mode == "pair", pair.count == 2 {
        layouts = layouts.filter { pair.contains(UInt16(truncatingIfNeeded: UInt(bitPattern: $0))) }
    }
    if mode == "latin" {
        let latin: Set<UInt16> = [0x09, 0x0C, 0x07, 0x0A, 0x10, 0x16, 0x15, 0x13, 0x1D, 0x06, 0x14, 0x0B]
        let currentIsLatin = latin.contains(UInt16(truncatingIfNeeded: UInt(bitPattern: current)) & 0x03FF)
        let opposite = layouts.filter {
            latin.contains(UInt16(truncatingIfNeeded: UInt(bitPattern: $0)) & 0x03FF) != currentIsLatin
        }
        if let target = opposite.first { layouts = [current, target] }
    }
    guard layouts.count > 1 else { throw WindowsError.unsupported("Choose two installed languages.") }
    let index =
        layouts.firstIndex(of: current) ?? layouts.firstIndex {
            UInt(bitPattern: $0) & 0xFFFF == UInt(bitPattern: current) & 0xFFFF
        } ?? 0
    let target = layouts[(index + 1) % layouts.count]
    var info = GUITHREADINFO()
    info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
    GetGUIThreadInfo(thread, &info)
    guard
        PostMessageW(info.hwndFocus ?? foreground, UINT(WM_INPUTLANGCHANGEREQUEST), 0, LPARAM(Int(bitPattern: target)))
    else { throw WindowsError.api("Switch input language", GetLastError()) }
}
func languageName(_ language: UInt16) -> String {
    var buffer = Array(repeating: WCHAR(0), count: 256)
    let count = GetLocaleInfoW(LCID(language), LCTYPE(LOCALE_SLANGUAGE), &buffer, Int32(buffer.count))
    return count > 1 ? String(decoding: buffer.prefix(Int(count - 1)), as: UTF16.self) : "Language \(language)"
}

func shellOpen(_ target: String, arguments: String? = nil, elevated: Bool = false, owner: HWND? = nil) throws {
    let result = withWideString(elevated ? "runas" : "open") { verb in
        withWideString(target) { path in
            if let arguments {
                return withWideString(arguments) { ShellExecuteW(owner, verb, path, $0, nil, Int32(SW_SHOWNORMAL)) }
            }
            return ShellExecuteW(owner, verb, path, nil, nil, Int32(SW_SHOWNORMAL))
        }
    }
    guard Int(bitPattern: result) > 32 else {
        throw WindowsError.unsupported("Windows could not open this action (\(Int(bitPattern: result))).")
    }
}

struct LinuxDistribution {
    let name: String
    let version: UInt32
    static func installed() -> [LinuxDistribution] {
        var root: HKEY?
        guard
            withWideString(
                "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss",
                { RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(0x20019), &root) }) == ERROR_SUCCESS, let root
        else { return [] }
        defer { RegCloseKey(root) }
        var result: [LinuxDistribution] = []
        for index in 0..<64 {
            var name = Array(repeating: WCHAR(0), count: 256)
            var length: DWORD = 256
            if RegEnumKeyExW(root, DWORD(index), &name, &length, nil, nil, nil, nil) != ERROR_SUCCESS { break }
            var key: HKEY?
            guard
                name.withUnsafeBufferPointer({ RegOpenKeyExW(root, $0.baseAddress, 0, REGSAM(0x20019), &key) })
                    == ERROR_SUCCESS, let key
            else { continue }
            defer { RegCloseKey(key) }
            var buffer = Array(repeating: WCHAR(0), count: 256)
            var size = DWORD(buffer.count * 2)
            let read = withWideString("DistributionName") { value in
                buffer.withUnsafeMutableBytes {
                    RegQueryValueExW(key, value, nil, nil, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size)
                }
            }
            var version: DWORD = 0
            size = 4
            _ = withWideString("Version") { value in
                withUnsafeMutableBytes(of: &version) {
                    RegQueryValueExW(key, value, nil, nil, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size)
                }
            }
            let distro = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
            if read == ERROR_SUCCESS, !distro.isEmpty, distro.count < 100,
                distro.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
            {
                result.append(LinuxDistribution(name: distro, version: version))
            }
        }
        return result
    }
    func openHomebrewInstaller() throws {
        guard version == 2 else {
            throw WindowsError.unsupported("Upgrade this distribution to WSL 2 before installing Homebrew.")
        }
        let script =
            "set -e; printf 'SwiftyToys: Homebrew in WSL 2\\nhttps://docs.brew.sh/Installation\\n'; if ! command -v curl >/dev/null || ! command -v git >/dev/null || ! command -v gcc >/dev/null; then if command -v apt-get >/dev/null; then sudo apt-get update; sudo apt-get install build-essential procps curl file git; else printf 'Install build tools, procps, curl, file and git first.\\n'; exit 1; fi; fi; installer=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh); /bin/bash -c \"$installer\"; if test -x /home/linuxbrew/.linuxbrew/bin/brew; then line='eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"'; grep -Fqx \"$line\" ~/.bashrc 2>/dev/null || printf '\\n%s\\n' \"$line\" >> ~/.bashrc; eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"; brew --version; fi"
        // Fixed installer script, strictly validated distro, one escaped Windows argument.
        let wrapped =
            "( " + script
            + " ); status=$?; printf '\\nFinished with status %s. You can close this terminal.\\n' \"$status\"; exec bash"
        try shellOpen("wsl.exe", arguments: "--distribution \(name) --exec bash -c \(quoteArgument(wrapped))")
    }
}

func quoteArgument(_ value: String) -> String {
    var result = "\""
    var slashes = 0
    for character in value {
        if character == "\\" {
            slashes += 1
            continue
        }
        if character == "\"" {
            result += String(repeating: "\\", count: slashes * 2 + 1) + "\""
        } else {
            result += String(repeating: "\\", count: slashes) + String(character)
        }
        slashes = 0
    }
    return result + String(repeating: "\\", count: slashes * 2) + "\""
}
