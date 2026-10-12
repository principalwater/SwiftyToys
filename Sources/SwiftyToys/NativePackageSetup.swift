// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

/// Cold setup orchestration. Windows and the official Linux installers own their installations.
enum NativePackageSetup {
    private struct Result { let code: Int32; let output: String }
    private struct CommandFailure: Error { let step: String; let code: Int32 }
    private static let homebrewURL = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
    private static let brew = "/home/linuxbrew/.linuxbrew/bin/brew"
    private static let shellenv = "eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""
    private static func validDistro(_ name: String) -> Bool {
        !name.isEmpty && name.count < 100 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
    private static func validLinuxPath(_ path: String) -> Bool {
        path.hasPrefix("/") && (2...1024).contains(path.utf8.count) && path.utf8.allSatisfy { $0 >= 32 && $0 != 127 }
            && !path.contains("\\") && !path.contains(":") && !path.contains("\"")
            && path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validate(action: String, distro: String?) throws {
        guard ["wsl", "ubuntu", "homebrew"].contains(action),
            action == "homebrew" ? distro.map(validDistro) == true : distro == nil else {
            throw WindowsError.unsupported("Use --package-setup wsl|ubuntu|homebrew [registered distribution].")
        }
    }
    private static func wslArguments(action: String) -> [String] {
        action == "wsl" ? ["--install", "--no-distribution"] : ["--install", "--no-launch", "-d", "Ubuntu"]
    }
    static func open(action: String, distro: String? = nil, owner: HWND? = nil) throws {
        try validate(action: action, distro: distro)
        let arguments = ["--package-setup", action] + (distro.map { [$0] } ?? [])
        // Ubuntu and Homebrew stay in the current Windows user's profile.
        try shellOpen(executablePath(), arguments: arguments.map(quoteArgument).joined(separator: " "), elevated: action == "wsl", owner: owner)
    }
    private static func userSID() throws -> String {
        var raw: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &raw) else { throw WindowsError.api("Read setup user", GetLastError()) }
        let token = try OwnedHandle(raw)
        var count: DWORD = 0
        _ = GetTokenInformation(token.raw, TokenUser, nil, 0, &count)
        guard count >= MemoryLayout<TOKEN_USER>.size, count <= 65536 else { throw WindowsError.unsupported("Invalid setup user token.") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(count), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token.raw, TokenUser, buffer, count, &count) else { throw WindowsError.api("Read setup user identity", GetLastError()) }
        var text: PWSTR?
        guard ConvertSidToStringSidW(buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid, &text), let text else { throw WindowsError.api("Encode setup user", GetLastError()) }
        defer { _ = LocalFree(text) }
        var length = 0
        while length < 256, text[length] != 0 { length += 1 }
        guard length < 256 else { throw WindowsError.unsupported("Invalid setup user identity.") }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
    }
    static func runCLI(action: String, distro: String? = nil) throws -> Int32 {
        try validate(action: action, distro: distro)
        let ownsConsole = GetConsoleWindow() == nil && AllocConsole()
        guard ownsConsole || GetConsoleWindow() != nil else { throw WindowsError.api("Open setup console", GetLastError()) }
        var icons: [ApplicationIcon] = []
        if ownsConsole {
            _ = withWideString("SwiftyToys — Linux setup") { SetConsoleTitleW($0) }
            if let window = GetConsoleWindow() {
                for (kind, size) in [(ICON_BIG, SM_CXICON), (ICON_SMALL, SM_CXSMICON)] {
                    if let icon = try? ApplicationIcon(size: GetSystemMetrics(Int32(size))) {
                        icons.append(icon)
                        SendMessageW(window, UINT(WM_SETICON), WPARAM(kind), LPARAM(Int(bitPattern: icon.handle)))
                    }
                }
            }
        }
        defer {
            withExtendedLifetime(icons) {
                if ownsConsole {
                    Console.writeLine("Press Enter to close.")
                    if let input = GetStdHandle(DWORD(bitPattern: -10)), input != INVALID_HANDLE_VALUE {
                        var mode: DWORD = 0, read: DWORD = 0, character: WCHAR = 0
                        if GetConsoleMode(input, &mode) { _ = ReadConsoleW(input, &character, 1, &read, nil) }
                    }
                    _ = FreeConsole()
                }
            }
        }
        do {
            // This mutex is released on leaving the operation, before the console pause.
            let name = "Local\\SwiftyToys.PackageSetup." + (try userSID()) + "." + action + "." + (distro?.lowercased() ?? "")
            let operation = try OwnedHandle(withWideString(name) { CreateMutexW(nil, false, $0) })
            let acquired = WaitForSingleObject(operation.raw, 0)
            if acquired == DWORD(WAIT_TIMEOUT) { throw WindowsError.unsupported("This setup operation is already running. Finish it before retrying.") }
            guard acquired == DWORD(WAIT_OBJECT_0) || acquired == 0x80 else { throw WindowsError.api("Acquire package setup lock", GetLastError()) }
            defer { ReleaseMutex(operation.raw) }
            let code: Int32
            if action == "homebrew" { code = try installHomebrew(distro!) }
            else {
                Console.writeLine(action == "wsl" ? "Installing Windows Subsystem for Linux components…" : "Installing Ubuntu for this Windows account…")
                code = try run(systemExecutable("wsl.exe"), arguments: wslArguments(action: action)).code
                if code == 0 { Console.writeLine("Setup completed. Restart Windows if requested, then open Ubuntu to create your Linux user.") }
                else {
                    Console.writeLine(String(describing: WindowsError.status("WSL setup", code)))
                    if WSLSetup.readBootDiagnostic() == true {
                    Console.writeLine("Windows reports that Hyper-V could not start because VMX is disabled or unavailable. Enable virtualization in firmware or your supported boot configuration, then restart Windows.")
                    }
                }
            }
            Console.writeLine("Finished with status \(code).")
            return code
        } catch let failure as CommandFailure {
            Console.writeLine(failure.code < 0 ? String(describing: WindowsError.status(failure.step, failure.code)) : "\(failure.step) failed with exit status \(failure.code).")
            if WSLSetup.readBootDiagnostic() == true {
                Console.writeLine("Windows reports that Hyper-V could not start because VMX is disabled or unavailable. Enable virtualization in firmware or your supported boot configuration, then restart Windows.")
            }
            return failure.code
        } catch {
            Console.writeLine("Setup failed: \(error)")
            return 1
        }
    }
    private static func run(_ executable: String, arguments: [String], capture: Bool = false, input: [UInt8]? = nil) throws -> Result {
        guard !capture || input == nil, input.map({ $0.count <= 4096 }) ?? true,
            arguments.allSatisfy({ !$0.utf16.contains(0) }) else { throw WindowsError.unsupported("Invalid setup process arguments or fixed pipe input budget.") }
        var command = Array(([quoteArgument(executable)] + arguments.map(quoteArgument)).joined(separator: " ").utf16) + [0]
        guard command.count <= 32767 else { throw WindowsError.unsupported("Setup process command is too long.") }
        var pipeRead: HANDLE?, pipeWrite: HANDLE?
        defer { if let pipeRead { CloseHandle(pipeRead) }; if let pipeWrite { CloseHandle(pipeWrite) } }
        var startup = STARTUPINFOW(), information = PROCESS_INFORMATION()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        if capture || input != nil {
            var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
            guard CreatePipe(&pipeRead, &pipeWrite, &security, 4096),
                SetHandleInformation(capture ? pipeRead : pipeWrite, DWORD(HANDLE_FLAG_INHERIT), 0) else { throw WindowsError.api("Create bounded setup pipe", GetLastError()) }
            startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.hStdInput = input != nil ? pipeRead : GetStdHandle(DWORD(bitPattern: -10))
            startup.hStdOutput = capture ? pipeWrite : GetStdHandle(DWORD(bitPattern: -11))
            startup.hStdError = GetStdHandle(DWORD(bitPattern: -12))
        }
        guard withWideString(executable, { CreateProcessW($0, &command, nil, nil, capture || input != nil, 0, nil, nil, &startup, &information) }) else { throw WindowsError.api("Start native package utility", GetLastError()) }
        let process = try OwnedHandle(information.hProcess), thread = try OwnedHandle(information.hThread)
        _ = thread.raw
        defer {
            // On an I/O failure, close pipe ends before joining; never abandon or kill an installer.
            if let pipeRead { CloseHandle(pipeRead) }; pipeRead = nil
            if let pipeWrite { CloseHandle(pipeWrite) }; pipeWrite = nil
            _ = WaitForSingleObject(process.raw, DWORD(INFINITE))
        }
        var output: [UInt8] = [], oversized = false
        if capture {
            if let pipeWrite { CloseHandle(pipeWrite) }; pipeWrite = nil
            var buffer = [UInt8](repeating: 0, count: 1024), count: DWORD = 0
            while true {
                guard buffer.withUnsafeMutableBytes({ ReadFile(pipeRead, $0.baseAddress, DWORD($0.count), &count, nil) }) else {
                    if GetLastError() == DWORD(ERROR_BROKEN_PIPE) { break }
                    throw WindowsError.api("Read package utility output", GetLastError())
                }
                if count == 0 { break }
                // Keep draining after the limit so a child never blocks on a full output pipe.
                if output.count + Int(count) <= 8192 { output += buffer.prefix(Int(count)) } else { oversized = true }
            }
        } else if let input {
            if let pipeRead { CloseHandle(pipeRead) }; pipeRead = nil
            var count: DWORD = 0
            guard input.withUnsafeBytes({ WriteFile(pipeWrite, $0.baseAddress, DWORD($0.count), &count, nil) }), count == input.count else { throw WindowsError.api("Write package setup input", GetLastError()) }
            if let pipeWrite { CloseHandle(pipeWrite) }; pipeWrite = nil
        }
        guard WaitForSingleObject(process.raw, DWORD(INFINITE)) == DWORD(WAIT_OBJECT_0) else { throw WindowsError.api("Wait for package setup", GetLastError()) }
        var code: DWORD = 0
        guard GetExitCodeProcess(process.raw, &code) else { throw WindowsError.api("Read package setup result", GetLastError()) }
        if code != 0 {
            var diagnostic: String
            if output.contains(0), output.count % 2 == 0 {
                let words = stride(from: 0, to: output.count, by: 2).map { UInt16(output[$0]) | UInt16(output[$0 + 1]) << 8 }
                diagnostic = String(decoding: words, as: UTF16.self)
            } else { diagnostic = String(decoding: output, as: UTF8.self) }
            if !diagnostic.isEmpty { Console.writeLine(diagnostic) }
            if oversized { Console.writeLine("Diagnostic output was truncated.") }
            return Result(code: Int32(bitPattern: code), output: diagnostic)
        }
        guard !oversized, let text = String(validating: output, as: UTF8.self) else { throw WindowsError.unsupported("Package setup returned oversized or invalid output.") }
        return Result(code: 0, output: text)
    }
    private static func linux(_ distro: String, _ command: [String], capture: Bool = false, input: [UInt8]? = nil) throws -> Result {
        try run(systemExecutable("wsl.exe"), arguments: ["--distribution", distro, "--exec"] + command, capture: capture, input: input)
    }
    private static func checked(_ result: Result, step: String) throws -> String {
        guard result.code == 0 else { throw CommandFailure(step: step, code: result.code) }
        return result.output
    }
    private static func installHomebrew(_ distro: String) throws -> Int32 {
        guard LinuxDistribution.installed().contains(where: { equalWindowsNames($0.name, distro) && $0.canInstallHomebrew }) else { throw WindowsError.unsupported("Choose a registered WSL 2 distribution before installing Homebrew.") }
        Console.writeLine("SwiftyToys: Homebrew in WSL 2\nhttps://docs.brew.sh/Installation\nEnter your Linux sudo password yourself when requested.")
        let user = try checked(linux(distro, ["/usr/bin/id", "-u"], capture: true), step: "Read Linux user")
        guard let uid = UInt32(user.trimmingWhitespace()), uid > 0 else { throw WindowsError.unsupported("Create a non-root Linux user before installing Homebrew.") }
        let homeField = try checked(linux(distro, ["/usr/bin/printenv", "--null", "HOME"], capture: true), step: "Read Linux home")
        guard homeField.last == "\u{0}" else { throw WindowsError.unsupported("Linux did not return a complete home directory.") }
        let home = String(homeField.dropLast())
        guard validLinuxPath(home) else { throw WindowsError.unsupported("The Linux home directory is not a valid absolute path.") }
        _ = try checked(linux(distro, ["/usr/bin/test", "-d", home]), step: "Validate Linux home directory")
        var dependenciesReady = true
        for tool in ["curl", "git", "gcc", "ps", "file"] {
            if try linux(distro, ["/usr/bin/env", tool, "--version"], capture: true).code != 0 { dependenciesReady = false }
        }
        if !dependenciesReady {
            guard try linux(distro, ["/usr/bin/env", "apt-get", "--version"], capture: true).code == 0 else { throw WindowsError.unsupported("Install build tools, procps, curl, file and git in this distribution first.") }
            Console.writeLine("Installing Homebrew prerequisites with your Linux account…")
            _ = try checked(linux(distro, ["/usr/bin/env", "sudo", "apt-get", "update"]), step: "Update Linux package metadata")
            _ = try checked(linux(distro, ["/usr/bin/env", "sudo", "apt-get", "install", "build-essential", "procps", "curl", "file", "git"]), step: "Install Linux build prerequisites")
        }
        let temporary = try checked(linux(distro, ["/usr/bin/mktemp", "--tmpdir=/tmp", "--", "swiftytoys-homebrew.XXXXXXXXXX"], capture: true), step: "Create official installer download").trimmingWhitespace()
        guard validLinuxPath(temporary), temporary.hasPrefix("/tmp/swiftytoys-homebrew."), !temporary.dropFirst(5).contains("/") else { throw WindowsError.unsupported("Invalid Linux installer temporary path.") }
        defer { _ = try? linux(distro, ["/usr/bin/rm", "-f", "--", temporary]) }
        Console.writeLine("Downloading the official Homebrew installer over HTTPS…")
        _ = try checked(linux(distro, ["/usr/bin/env", "curl", "-q", "--fail", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--output", temporary, homebrewURL]), step: "Download official Homebrew installer")
        _ = try checked(linux(distro, ["/bin/bash", temporary]), step: "Official Homebrew installer")
        _ = try checked(linux(distro, ["/usr/bin/test", "-x", brew]), step: "Check installed Homebrew")
        let bashrc = home + "/.bashrc"
        let exists = try linux(distro, ["/usr/bin/test", "-e", bashrc]).code
        guard exists == 0 || exists == 1 else { throw CommandFailure(step: "Read Bash configuration", code: exists) }
        let present = exists == 0 ? try linux(distro, ["/usr/bin/grep", "-Fqx", "--", shellenv, bashrc]).code : 1
        guard present == 0 || present == 1 else { throw CommandFailure(step: "Check Bash PATH setup", code: present) }
        if present == 1 {
            _ = try checked(linux(distro, ["/usr/bin/tee", "-a", "--", bashrc], input: Array(("\n" + shellenv + "\n").utf8)), step: "Append Homebrew Bash PATH setup")
        }
        _ = try checked(linux(distro, [brew, "--version"]), step: "Verify Homebrew")
        Console.writeLine("Homebrew is installed. Open a new Bash terminal to use brew from PATH.")
        return 0
    }
    static func selfCheck() throws {
        try validate(action: "wsl", distro: nil); try validate(action: "ubuntu", distro: nil)
        try validate(action: "homebrew", distro: "Ubuntu-24.04")
        guard wslArguments(action: "wsl") == ["--install", "--no-distribution"],
            wslArguments(action: "ubuntu") == ["--install", "--no-launch", "-d", "Ubuntu"],
            validLinuxPath("/home/user"), validLinuxPath("/home/a user"), !validLinuxPath("/home/../root"),
            !validLinuxPath("/home/user\n/root"), !validLinuxPath("/home/user\n"), !validLinuxPath("/home/user\u{0}"),
            !validLinuxPath("C:\\home"), !validLinuxPath("/"),
            shellenv == "eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"", homebrewURL.hasPrefix("https://") else { throw WindowsError.unsupported("Native package setup policy check failed.") }
        for name in ["", "Ubuntu\" --user root", "Ubuntu;echo", "../Ubuntu", "Ubuntu\\other", "Ubuntu\u{0}"] {
            guard !validDistro(name) else { throw WindowsError.unsupported("Invalid Linux distribution name accepted.") }
        }
        for (action, distro) in [("cmd", Optional<String>.none), ("wsl", "Ubuntu"), ("homebrew", nil)] {
            var rejected = false
            do { try validate(action: action, distro: distro) } catch { rejected = true }
            guard rejected else { throw WindowsError.unsupported("Invalid package setup action accepted.") }
        }
        Console.writeLine("PASS: native package setup fixed commands, action/distro/home validation and Bash PATH line; no Linux process, download or setting change")
    }
}
