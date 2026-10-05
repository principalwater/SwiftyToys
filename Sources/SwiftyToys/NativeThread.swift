// SPDX-License-Identifier: MIT

import CRT
import WinSDK

private final class ThreadBody: Sendable {
    let run: @Sendable () -> Void
    init(_ run: @escaping @Sendable () -> Void) { self.run = run }
}

private func nativeThreadEntry(_ context: UnsafeMutableRawPointer?) -> UInt32 {
    guard let context else { return 0 }
    let body = Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue()
    body.run()
    return 0
}

/// Owns a CRT-initialized thread handle; closing it does not stop the thread.
/// The entry point retains its Sendable closure until the work has finished.
struct NativeThread: ~Copyable {
    private let handle: OwnedHandle

    init(name: String, run: @escaping @Sendable () -> Void) throws(WindowsError) {
        let body = Unmanaged.passRetained(ThreadBody(run))
        let raw = _beginthreadex(nil, 0, nativeThreadEntry, body.toOpaque(), 0, nil)
        guard raw != 0 else {
            var error: UInt32 = 0
            _get_doserrno(&error)
            body.release()
            throw .api("_beginthreadex", error)
        }
        handle = try OwnedHandle(HANDLE(bitPattern: raw))
        _ = withWideString(name) { SetThreadDescription(handle.raw, $0) }
    }
}
