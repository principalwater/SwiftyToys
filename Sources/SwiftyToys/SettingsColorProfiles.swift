// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK
import WindowsDisplayABI

let colorProfilesMessage: UINT = 0x8038

/// On-demand WCS reads and an optional installer wait, never on the window thread.
final class SettingsColorProfiles: Sendable {
    struct Report: Sendable {
        let displayID: String
        let snapshot: WindowsColorProfiles.Snapshot?
        let error: String?
        var imported: String? = nil
    }
    private let state = Mutex((busy: false, report: Optional<Report>.none))
    var busy: Bool { state.withLock { $0.busy } }
    var report: Report? { state.withLock { $0.report } }
    func forgetImport() { state.withLock { $0.report?.imported = nil } }

    func load(output: DisplayOutput, destination: MessageDestination) {
        guard begin() else { return }
        do {
            _ = try NativeThread(name: "SwiftyToys color profiles") { [self] in
                let report: Report
                do { report = Report(displayID: output.id, snapshot: try WindowsColorProfiles.snapshot(output: output), error: nil) }
                catch { report = Report(displayID: output.id, snapshot: nil, error: String(describing: error)) }
                finish(report, destination: destination)
            }
        } catch { finish(Report(displayID: output.id, snapshot: nil, error: String(describing: error)), destination: destination) }
    }

    func importProfile(file: String, output: DisplayOutput, destination: MessageDestination) throws {
        guard begin() else { throw WindowsError.unsupported("A color profile operation is already running.") }
        do {
            _ = try NativeThread(name: "SwiftyToys ICC import") { [self] in
                let report: Report
                do {
                    let name = try WindowsColorProfiles.installedName(forFile: file)
                    let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
                    guard initialized >= 0 else { throw WindowsError.status("Initialize ICC installer", initialized) }
                    defer { CoUninitialize() }
                    var execution = SHELLEXECUTEINFOW()
                    execution.cbSize = DWORD(MemoryLayout<SHELLEXECUTEINFOW>.size)
                    execution.fMask = 0x140 // Keep the process handle until the native installer completes.
                    execution.hwnd = destination.window
                    execution.nShow = Int32(SW_HIDE)
                    let launched = withWideString("runas") { verb in
                        withWideString(executablePath()) { executable in
                            withWideString("--install-color-profile " + quoteArgument(file) + " " + quoteArgument(name)) { arguments in
                                execution.lpVerb = verb; execution.lpFile = executable; execution.lpParameters = arguments
                                return ShellExecuteExW(&execution)
                            }
                        }
                    }
                    guard launched else { throw WindowsError.api("Install ICC profile", GetLastError()) }
                    let process = try OwnedHandle(execution.hProcess)
                    guard WaitForSingleObject(process.raw, DWORD(INFINITE)) == DWORD(WAIT_OBJECT_0) else {
                        throw WindowsError.api("Wait for ICC installer", GetLastError())
                    }
                    var code: DWORD = 1
                    guard GetExitCodeProcess(process.raw, &code), code == 0 else {
                        throw WindowsError.unsupported("Windows could not install the ICC profile. Check its validity and administrator approval, then retry. Existing profiles were not replaced.")
                    }
                    let snapshot = try WindowsColorProfiles.snapshot(output: output)
                    guard snapshot.installed.contains(where: { equalWindowsNames($0.fileName, name) }) else {
                        throw WindowsError.unsupported("The imported ICC profile is not available. Refresh Windows color settings before applying.")
                    }
                    report = Report(displayID: output.id, snapshot: snapshot, error: nil, imported: name)
                } catch { report = Report(displayID: output.id, snapshot: nil, error: String(describing: error)) }
                finish(report, destination: destination)
            }
        } catch {
            state.withLock { $0.busy = false }
            throw error
        }
    }

    private func begin() -> Bool {
        state.withLock {
            guard !$0.busy else { return false }
            $0.busy = true
            return true
        }
    }
    private func finish(_ report: Report, destination: MessageDestination) {
        state.withLock { $0.report = report; $0.busy = false }
        _ = destination.post(colorProfilesMessage)
    }

    static func chooseProfile(owner: HWND, title: String) throws -> String? {
        var path = [WCHAR](repeating: 0, count: 32768)
        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = owner
        dialog.nMaxFile = DWORD(path.count)
        dialog.Flags = DWORD(OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_DONTADDTORECENT)
        let chosen = path.withUnsafeMutableBufferPointer { file in
            withWideString("ICC profiles (*.icc;*.icm)\0*.icc;*.icm\0\0") { filter in
                withWideString(title) { title in
                    dialog.lpstrFile = file.baseAddress; dialog.lpstrFilter = filter; dialog.lpstrTitle = title
                    return GetOpenFileNameW(&dialog)
                }
            }
        }
        if chosen { return String(decoding: path.prefix(while: { $0 != 0 }), as: UTF16.self) }
        let error = CommDlgExtendedError()
        guard error == 0 else { throw WindowsError.api("Choose ICC profile", error) }
        return nil
    }
}
