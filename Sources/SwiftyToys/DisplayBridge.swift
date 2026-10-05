// SPDX-License-Identifier: MIT

import Synchronization
import WinSDK

/// Kernel events are thread-safe; ownership lasts through any delayed completion.
private final class ReplyEvent: @unchecked Sendable {
    let handle: OwnedHandle
    let reply = Mutex<Result<DisplayState, WindowsError>?>(nil)
    init() throws { handle = try OwnedHandle(CreateEventW(nil, true, false, nil)) }
}
/// Win32's message loop owns UI state. It does not run Swift's MainActor queue.
func displayCommand(_ controller: DisplayController, command: Int, value: Int = 0) throws -> DisplayState {
    let event = try ReplyEvent()
    Task {
        let result: Result<DisplayState, WindowsError>
        do { result = .success(try await controller.command(command, value: value)) } catch let error as WindowsError {
            result = .failure(error)
        } catch { result = .failure(.unsupported(String(describing: error))) }
        event.reply.withLock { $0 = result }
        SetEvent(event.handle.raw)
    }
    guard WaitForSingleObject(event.handle.raw, 15000) == DWORD(WAIT_OBJECT_0),
        let reply = event.reply.withLock({ $0 })
    else { throw WindowsError.unsupported("Display driver did not finish within 15 seconds.") }
    return try reply.get()
}
func stopDisplay(_ controller: DisplayController) {
    guard let event = try? ReplyEvent() else { return }
    Task {
        await controller.shutdown()
        SetEvent(event.handle.raw)
    }
    _ = WaitForSingleObject(event.handle.raw, 15000)
    // The actor's deinit stops the executor after all outstanding jobs finish.
}
