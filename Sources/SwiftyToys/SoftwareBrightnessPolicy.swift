// SPDX-License-Identifier: MIT
import WinSDK
import WindowsDisplayABI

/// The retired copied-desktop backend can never be selected, including by old saved settings.
func testSoftwareBrightnessPolicy() throws {
    guard !Settings.modes.contains("compositor"), !Settings.softwareModes.contains("compositor"),
        try Settings(contents: "backend=compositor\nddcEnabled=0").backend == "auto",
        try Settings(contents: "backend=compositor\nddcEnabled=1").backend == "hardware" else {
        throw WindowsError.unsupported("Retired desktop-copy backend migration failed.")
    }
    Console.writeLine("PASS: no copied-desktop backend, software migration and explicit DDC preference retained")
}

/// Old cursor-owning leases still restore visibility; normal brightness never calls this API.
func restoreSoftwareCursorVisibility() throws(WindowsError) {
    guard MagInitialize() else { throw .api("Initialize cursor visibility recovery", GetLastError()) }
    defer { MagUninitialize() }
    guard MagShowSystemCursor(true) else { throw .api("Recover system cursor visibility", GetLastError()) }
}
