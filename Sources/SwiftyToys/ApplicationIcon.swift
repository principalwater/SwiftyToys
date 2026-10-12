// SPDX-License-Identifier: MIT
import WinSDK

/// Each native surface owns its requested resolution; shared icon caches can reuse the wrong size.
final class ApplicationIcon {
    let handle: HICON

    init(size: Int32) throws {
        guard let image = LoadImageW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 101), UINT(IMAGE_ICON), size, size, 0) else {
            throw WindowsError.api("Load application icon", GetLastError())
        }
        handle = image.assumingMemoryBound(to: HICON__.self)
    }

    deinit { DestroyIcon(handle) }
}
