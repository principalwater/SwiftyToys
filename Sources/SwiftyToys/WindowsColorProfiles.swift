// SPDX-License-Identifier: MIT

import WinSDK
import WindowsDisplayABI

/// Windows owns profile preferences. Call on the display executor after releasing software gamma.
enum WindowsColorProfiles {
    struct Profile: Sendable {
        let fileName: String
        let description: String
    }

    struct Snapshot: Sendable {
        let installed: [Profile]
        let associated: [String]
        let effective: String
        let perUser: Bool
        let defaultProfile: String?
    }

    private struct State {
        let key: String
        let perUser: Bool
        let userDefault: String?
        let systemDefault: String?
        let userAssociations: [String]
        let effective: String
    }

    private static let maximumProfileBytes = 16 * 1024 * 1024
    private static let monitorClass: DWORD = 0x6D6E7472  // ICC 'mntr'.
    private static let rgbSpace: DWORD = 0x52474220  // ICC 'RGB '.

    private static func require(_ succeeded: Bool, _ operation: String) throws {
        guard succeeded else { throw WindowsError.api(operation, GetLastError()) }
    }

    private static func name(_ value: String) throws -> String {
        let result = String(value.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "")
        guard !result.isEmpty, result != ".", result != "..", result.utf16.count < 260,
            !result.utf16.contains(0), !result.contains(":"), !result.contains("|") else {
            throw WindowsError.unsupported("Invalid color profile filename.")
        }
        return result
    }

    private static func same(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case (.some(let left), .some(let right)): equalWindowsNames(left, right)
        default: false
        }
    }

    private static func colorDirectory() throws -> String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        var bytes = DWORD(buffer.count * 2)
        try require(GetColorDirectoryW(nil, &buffer, &bytes), "Find Windows color directory")
        guard bytes <= buffer.count * 2 else {
            throw WindowsError.unsupported("Unexpected color directory size.")
        }
        return try terminated(buffer)
    }

    private static func terminated(_ buffer: [WCHAR]) throws -> String {
        guard let end = buffer.firstIndex(of: 0), end > 0,
            let text = String(validating: buffer[..<end], as: UTF16.self) else {
            throw WindowsError.unsupported("Invalid Windows color profile string.")
        }
        return text
    }

    /// Rechecks topology and matches the monitor interface, never a friendly name or source ordinal.
    private static func monitorKey(output: DisplayOutput) throws -> String {
        let current = try discoverDisplays().filter { equalWindowsNames($0.id, output.id) }
        guard current.count == 1, let active = current.first, active.isPhysical,
            !active.isCloned, !active.isHDR, equalWindowsNames(active.device, output.device),
            active.adapterLow == output.adapterLow, active.adapterHigh == output.adapterHigh,
            active.source == output.source, active.target == output.target,
            let interface = output.id.split(separator: "|", omittingEmptySubsequences: false).first,
            !interface.isEmpty else {
            throw WindowsError.unsupported("Color profiles require one active physical SDR display.")
        }
        var matches: [String] = []
        try withWideString(output.device) { source in
            for index in 0...64 {
                var child = DISPLAY_DEVICEW()
                child.cb = DWORD(MemoryLayout<DISPLAY_DEVICEW>.size)
                guard EnumDisplayDevicesW(source, DWORD(index), &child, DWORD(EDD_GET_DEVICE_INTERFACE_NAME)) else {
                    break
                }
                guard index < 64 else {
                    throw WindowsError.unsupported("Unexpected monitor child count.")
                }
                if equalWindowsNames(wideString(child.DeviceID), String(interface)),
                    child.StateFlags & DWORD(DISPLAY_DEVICE_ACTIVE) != 0 {
                    matches.append(wideString(child.DeviceKey))
                }
            }
        }
        guard matches.count == 1, let key = matches.first, !key.isEmpty else {
            throw WindowsError.unsupported("The active monitor color-management key is ambiguous.")
        }
        return key
    }

    private static func defaultProfile(
        key: String, scope: WCS_PROFILE_MANAGEMENT_SCOPE
    ) throws -> String? {
        try withWideString(key) { device -> String? in
            var bytes: DWORD = 0
            if !WcsGetDefaultColorProfileSize(scope, device, CPT_ICC, CPST_NONE, 0, &bytes) {
                let error = GetLastError()
                if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_NOT_FOUND) { return nil }
                throw WindowsError.api("Read default color profile size", error)
            }
            guard bytes >= 2, bytes <= 65536, bytes % 2 == 0 else {
                throw WindowsError.unsupported("Unexpected default color profile size.")
            }
            var buffer = [WCHAR](repeating: 0, count: Int(bytes / 2))
            try require(
                WcsGetDefaultColorProfile(scope, device, CPT_ICC, CPST_NONE, 0, bytes, &buffer),
                "Read default color profile")
            return try name(terminated(buffer))
        }
    }

    private static func multiStrings(_ units: [WCHAR], count: DWORD) throws -> [String] {
        guard count <= 4096, !units.isEmpty else {
            throw WindowsError.unsupported("Unexpected color profile list size.")
        }
        if count == 0 {
            guard units.allSatisfy({ $0 == 0 }) else {
                throw WindowsError.unsupported("Invalid empty color profile list.")
            }
            return []
        }
        var result: [String] = []
        var position = 0
        for _ in 0..<count {
            guard position < units.count, let end = units[position...].firstIndex(of: 0),
                end > position, let text = String(validating: units[position..<end], as: UTF16.self) else {
                throw WindowsError.unsupported("Invalid color profile list entry.")
            }
            result.append(try name(text))
            position = end + 1
        }
        guard position < units.count, units[position...].allSatisfy({ $0 == 0 }) else {
            throw WindowsError.unsupported("Invalid color profile list terminator.")
        }
        return result
    }

    private static func profiles(key: String?, scope: WCS_PROFILE_MANAGEMENT_SCOPE) throws -> [String] {
        func read(_ device: UnsafePointer<WCHAR>?) throws -> [String] {
            var criteria = ENUMTYPEW()
            criteria.dwSize = DWORD(MemoryLayout<ENUMTYPEW>.size)
            criteria.dwVersion = DWORD(ENUM_TYPE_VERSION)
            if let device {
                criteria.dwFields = DWORD(ET_DEVICENAME)
                criteria.pDeviceName = device
            } else {
                criteria.dwFields = DWORD(ET_CLASS | ET_DATACOLORSPACE)
                criteria.dwClass = monitorClass
                criteria.dwDataColorSpace = rgbSpace
            }
            var bytes: DWORD = 0
            try require(WcsEnumColorProfilesSize(scope, &criteria, &bytes), "Size color profile list")
            guard bytes >= 2, bytes <= 1_048_576, bytes % 2 == 0 else {
                throw WindowsError.unsupported("Unexpected color profile enumeration size.")
            }
            var buffer = [WCHAR](repeating: 0, count: Int(bytes / 2))
            var count: DWORD = 0
            try buffer.withUnsafeMutableBytes {
                try require(
                    WcsEnumColorProfiles(scope, &criteria, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), bytes, &count),
                    "Enumerate color profiles")
            }
            return try multiStrings(buffer, count: count)
        }
        if let key { return try withWideString(key) { try read($0) } }
        return try read(nil)
    }

    private static func effectiveProfile(output: DisplayOutput) throws -> String {
        guard let dc = withWideString("DISPLAY", { driver in
            withWideString(output.device) { CreateDCW(driver, $0, nil, nil) }
        }) else {
            throw WindowsError.api("Open display color context", GetLastError())
        }
        defer { DeleteDC(dc) }
        var count: DWORD = 0
        _ = GetICMProfileW(dc, &count, nil)
        guard count > 1, count <= 32768 else {
            throw WindowsError.api("Size effective display profile", GetLastError())
        }
        var buffer = [WCHAR](repeating: 0, count: Int(count))
        try require(GetICMProfileW(dc, &count, &buffer), "Read effective display profile")
        return try name(terminated(buffer))
    }

    private static func state(output: DisplayOutput) throws -> State {
        let key = try monitorKey(output: output)
        var perUser: WindowsBool = false
        try withWideString(key) {
            try require(WcsGetUsePerUserProfiles($0, monitorClass, &perUser), "Read per-user profile mode")
        }
        let userDefault = try defaultProfile(key: key, scope: WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER)
        let systemDefault = try defaultProfile(key: key, scope: WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE)
        // GDI can retain an earlier profile for this process even in a newly created DC.
        // WCS's scoped default is authoritative; an independent process verifies GDI in validation.
        let active = perUser.boolValue ? userDefault : systemDefault
        return try State(
            key: key, perUser: perUser.boolValue,
            userDefault: userDefault, systemDefault: systemDefault,
            userAssociations: profiles(key: key, scope: WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER),
            effective: active ?? standardRGBProfile())
    }

    static func snapshot(output: DisplayOutput) throws -> Snapshot {
        let state = try state(output: output)
        let directory = try colorDirectory()
        var installed: [Profile] = []
        for fileName in try profiles(key: nil, scope: WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE) {
            // Invalid or unreadable installed profiles are not offered as selectable input.
            guard let bytes = try? validatedBytes(file: directory + "\\" + fileName) else { continue }
            if !installed.contains(where: { same($0.fileName, fileName) }) {
                installed.append(Profile(fileName: fileName, description: profileDescription(bytes) ?? fileName))
            }
        }
        installed.sort { $0.fileName.lowercased() < $1.fileName.lowercased() }
        let associated = state.perUser ? state.userAssociations
            : try profiles(key: state.key, scope: WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE)
        return Snapshot(
            installed: installed, associated: associated, effective: state.effective,
            perUser: state.perUser, defaultProfile: state.perUser ? state.userDefault : state.systemDefault)
    }

    private static func setMode(_ enabled: Bool, key: String) throws {
        try withWideString(key) {
            try require(WcsSetUsePerUserProfiles($0, monitorClass, enabled), "Set per-user color profiles")
        }
    }

    private static func setUserDefault(_ fileName: String?, key: String) throws {
        try withWideString(key) { device in
            func set(_ profile: UnsafePointer<WCHAR>?) throws {
                try require(
                    WcsSetDefaultColorProfile(
                        WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER, device, CPT_ICC, CPST_NONE, 0, profile),
                    "Set per-user default color profile")
            }
            if let fileName { try withWideString(fileName) { try set($0) } }
            else { try set(nil) }
        }
    }

    private static func associate(_ fileName: String, key: String, adding: Bool) throws {
        try withWideString(key) { device in
            try withWideString(fileName) { profile in
                try require(
                    adding
                        ? WcsAssociateColorProfileWithDevice(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER, profile, device)
                        : WcsDisassociateColorProfileFromDevice(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER, profile, device),
                    adding ? "Associate display color profile" : "Restore display profile associations")
            }
        }
    }

    private static func standardRGBProfile() throws -> String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        var bytes = DWORD(buffer.count * 2)
        try require(
            GetStandardColorSpaceProfileW(nil, 0x73524742, &buffer, &bytes), // Win32 'sRGB'.
            "Read Windows standard RGB profile")
        return try name(terminated(buffer))
    }

    /// Nil selects system settings while preserving dormant user preferences and associations.
    static func setDefault(fileName: String?, output: DisplayOutput) throws {
        let before = try state(output: output)
        // ICC and DMP device defaults share storage on older WCS implementations.
        // Validate the actual active file, rather than treating a DMP query as a type test.
        guard (try? validatedBytes(file: colorDirectory() + "\\" + before.effective)) != nil else {
            throw WindowsError.unsupported("The active Windows profile is not a readable ICC monitor profile. Use Windows Color Management to change or repair it first.")
        }
        let selected = try fileName.map { value -> String in
            let clean = try name(value)
            guard clean == value else { throw WindowsError.unsupported("Select an installed profile filename.") }
            let installed = try profiles(key: nil, scope: WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE)
            guard installed.contains(where: { same($0, clean) }) else {
                throw WindowsError.unsupported("The selected color profile is not installed.")
            }
            _ = try validatedBytes(file: colorDirectory() + "\\" + clean)
            return clean
        }
        let expected = try selected ?? before.systemDefault ?? standardRGBProfile()
        var addedAssociation = false
        var changedDefault = false
        var changedMode = false
        var mutationBase = before
        do {
            if before.perUser != (selected != nil) {
                try setMode(selected != nil, key: before.key)
                changedMode = true
                // Windows can initialize the user list from the system list when enabling it.
                if selected != nil { mutationBase = try state(output: output) }
            }
            if let selected {
                if !mutationBase.userAssociations.contains(where: { same($0, selected) }) {
                    try associate(selected, key: before.key, adding: true)
                    addedAssociation = true
                }
                if !same(mutationBase.userDefault, selected) {
                    try setUserDefault(selected, key: before.key)
                    changedDefault = true
                }
            }
            let after = try state(output: output)
            guard equalWindowsNames(after.key, before.key), after.perUser == (selected != nil),
                selected == nil || (same(after.userDefault, selected)
                    && after.userAssociations.contains(where: { same($0, selected) })),
                same(after.effective, expected) else {
                throw WindowsError.unsupported("Windows did not make the selected display profile effective.")
            }
        } catch {
            let original = error
            guard let current = try? state(output: output), equalWindowsNames(current.key, before.key),
                selected == nil || same(current.userDefault, selected) || same(current.userDefault, mutationBase.userDefault) else {
                throw WindowsError.unsupported("Windows color settings changed during this operation. The current selection was preserved; review it in Windows Color Management.")
            }
            var rollbackErrors: [String] = []
            func attempt(_ action: () throws -> Void) {
                do { try action() } catch { rollbackErrors.append(String(describing: error)) }
            }
            if addedAssociation || changedDefault || changedMode {
                if changedMode && before.perUser {
                    attempt { try setMode(true, key: before.key) }
                    attempt {
                        let current = try profiles(key: before.key, scope: WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER)
                        for previous in before.userAssociations where !current.contains(where: { same($0, previous) }) {
                            try associate(previous, key: before.key, adding: true)
                        }
                    }
                }
                // Association can itself affect the default; restore it after removing our addition.
                if addedAssociation, let selected {
                    attempt { try associate(selected, key: before.key, adding: false) }
                }
                if mutationBase.userDefault != nil,
                    changedDefault || addedAssociation || (changedMode && before.perUser) {
                    attempt { try setUserDefault(mutationBase.userDefault, key: before.key) }
                }
                if changedMode && !before.perUser { attempt { try setMode(false, key: before.key) } }
                attempt {
                    let restored = try state(output: output)
                    guard restored.perUser == before.perUser,
                        same(restored.effective, before.effective),
                        !before.perUser || (same(restored.userDefault, before.userDefault)
                            && restored.userAssociations.count == before.userAssociations.count
                            && restored.userAssociations.allSatisfy({ value in
                                before.userAssociations.contains(where: { same(value, $0) })
                            })) else {
                        throw WindowsError.unsupported("Windows color profile rollback could not be verified.")
                    }
                }
            }
            if !rollbackErrors.isEmpty {
                throw WindowsError.unsupported(
                    "\(original)\n\nRestore the profile in Windows Color Management. " + rollbackErrors.joined(separator: " "))
            }
            if changedMode && !before.perUser {
                throw WindowsError.unsupported(
                    "\(original)\n\nThe previous active profile was restored. Windows may have initialized "
                        + "the dormant per-user profile list from system settings.")
            }
            throw original
        }
    }

    private static func validateStructure(_ bytes: [UInt8]) throws {
        guard bytes.count >= 132, bytes.count <= maximumProfileBytes else {
            throw WindowsError.unsupported("ICC profiles must be between 132 bytes and 16 MiB.")
        }
        func word(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard word(0) == bytes.count, word(12) == monitorClass, word(16) == rgbSpace,
            word(36) == 0x61637370 else {
            throw WindowsError.unsupported("Select a valid ICC monitor profile with RGB data.")
        }
        let count = Int(word(128))
        guard count <= 4096, count <= (bytes.count - 132) / 12 else {
            throw WindowsError.unsupported("Invalid ICC tag table size.")
        }
        let end = 132 + count * 12
        for index in 0..<count {
            let offset = Int(word(132 + index * 12 + 4))
            let length = Int(word(132 + index * 12 + 8))
            guard offset >= end, offset <= bytes.count, length <= bytes.count - offset else {
                throw WindowsError.unsupported("An ICC tag is outside the profile data.")
            }
        }
    }

    /// Reads only bounded standard display-name tags after structural and native ICC validation.
    private static func profileDescription(_ bytes: [UInt8]) -> String? {
        func word(_ offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        func displayText(_ text: String) -> String? {
            let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
                $0.value >= 32 && !((127...159).contains($0.value))
            }.prefix(256)))
            return clean.isEmpty ? nil : clean
        }
        for index in 0..<word(128) where word(132 + index * 12) == 0x64657363 {
            let start = word(136 + index * 12)
            let length = word(140 + index * 12)
            guard length >= 12 else { continue }
            if word(start) == 0x64657363 {
                let count = word(start + 8)
                guard count > 1, count <= 4096, count <= length - 12,
                    bytes[start + 12 + count - 1] == 0,
                    let text = String(validating: bytes[start + 12..<start + 12 + count - 1], as: UTF8.self)
                else { continue }
                if let result = displayText(text) { return result }
            } else if word(start) == 0x6D6C7563, length >= 16 {
                let count = word(start + 8)
                let stride = word(start + 12)
                guard count > 0, count <= 256, stride >= 12, stride <= 64,
                    count <= (length - 16) / stride else { continue }
                var fallback: String?
                for record in 0..<count {
                    let entry = start + 16 + record * stride
                    let size = word(entry + 4)
                    let offset = word(entry + 8)
                    guard size > 0, size <= 4096, size % 2 == 0,
                        offset >= 16 + count * stride, offset <= length, size <= length - offset else { continue }
                    var units: [UInt16] = []
                    for position in Swift.stride(from: start + offset, to: start + offset + size, by: 2) {
                        units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
                    }
                    guard let text = String(validating: units, as: UTF16.self), let clean = displayText(text) else {
                        continue
                    }
                    if bytes[entry] == 0x65, bytes[entry + 1] == 0x6E { return clean }
                    if fallback == nil { fallback = clean }
                }
                if let fallback { return fallback }
            }
        }
        return nil
    }

    private static func validate(_ input: [UInt8]) throws {
        try validateStructure(input)
        var bytes = input
        try bytes.withUnsafeMutableBytes { buffer in
            var profile = PROFILE()
            profile.dwType = DWORD(PROFILE_MEMBUFFER)
            profile.pProfileData = buffer.baseAddress
            profile.cbDataSize = DWORD(buffer.count)
            // Inspect ICC data only; do not instantiate embedded WCS models or any color transform.
            guard let opened = WcsOpenColorProfileW(
                &profile, nil, nil, DWORD(PROFILE_READ), DWORD(FILE_SHARE_READ), DWORD(OPEN_EXISTING),
                DWORD(DONT_USE_EMBEDDED_WCS_PROFILES)) else {
                throw WindowsError.api("Open ICC profile for validation", GetLastError())
            }
            defer { CloseColorProfile(opened) }
            var valid: WindowsBool = false
            try require(IsColorProfileValid(opened, &valid), "Validate ICC profile")
            var header = PROFILEHEADER()
            try require(GetColorProfileHeader(opened, &header), "Read ICC profile header")
            guard valid.boolValue, header.phClass == monitorClass, header.phDataColorSpace == rgbSpace,
                header.phSize == buffer.count else {
                throw WindowsError.unsupported("Windows rejected the ICC monitor RGB profile.")
            }
        }
    }

    private static func validatedBytes(file: String) throws -> [UInt8] {
        let handle = try OwnedHandle(withWideString(try NativeFiles.windowsPath(file)) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
        })
        var size = LARGE_INTEGER()
        try require(GetFileSizeEx(handle.raw, &size), "Read ICC profile size")
        guard size.QuadPart >= 132, size.QuadPart <= maximumProfileBytes else {
            throw WindowsError.unsupported("ICC profiles must be between 132 bytes and 16 MiB.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(size.QuadPart))
        var count: DWORD = 0
        try bytes.withUnsafeMutableBytes {
            try require(ReadFile(handle.raw, $0.baseAddress, DWORD($0.count), &count, nil), "Read ICC profile")
        }
        guard count == bytes.count else { throw WindowsError.unsupported("The ICC profile read was incomplete.") }
        try validate(bytes)
        return bytes
    }

    private static func installedName(bytes: [UInt8]) throws -> String {
        var remaining = bytes[...]
        let digest = try NativeDriverTrust.sha256 { buffer in
            let count = min(buffer.count, remaining.count)
            buffer.copyBytes(from: remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            return count
        }
        let hex = digest.map { value -> String in
            let text = String(value, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
        return "SwiftyToys-" + hex + ".icc"
    }

    static func installedName(forFile file: String) throws -> String {
        try installedName(bytes: validatedBytes(file: file))
    }

    /// Installation requires administrator consent; association stays in the unelevated user process.
    static func install(file: String, expectedName: String? = nil) throws -> String {
        let bytes = try validatedBytes(file: file)
        let fileName = try installedName(bytes: bytes)
        guard expectedName == nil || expectedName == fileName else {
            throw WindowsError.unsupported("The selected ICC file changed before installation. Choose it again.")
        }
        let destination = try colorDirectory() + "\\" + fileName
        if try NativeFiles.exists(destination) {
            guard try validatedBytes(file: destination) == bytes else {
                throw WindowsError.unsupported("The installed profile filename contains different data.")
            }
            return fileName
        }
        var temporary = [WCHAR](repeating: 0, count: 32768)
        let count = GetTempPathW(DWORD(temporary.count), &temporary)
        var guid = GUID()
        var identity = [WCHAR](repeating: 0, count: 40)
        guard count > 0, count < temporary.count, CoCreateGuid(&guid) >= 0,
            StringFromGUID2(&guid, &identity, Int32(identity.count)) > 0 else {
            throw WindowsError.unsupported("Create temporary ICC installation directory.")
        }
        let directory = String(decoding: temporary.prefix(Int(count)), as: UTF16.self)
            + "SwiftyToys-ICC-" + (try terminated(identity))
        try withWideString(directory) {
            try require(CreateDirectoryW($0, nil), "Create exclusive ICC staging directory")
        }
        defer { _ = withWideString(directory) { RemoveDirectoryW($0) } }
        let staged = directory + "\\" + fileName
        try NativeFiles.write(bytes, to: staged)
        defer { try? NativeFiles.remove(staged) }
        // Hold the staged bytes against writes and deletion until Windows has copied them.
        do {
            let locked = try OwnedHandle(withWideString(staged) {
                CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                    DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            })
            guard try validatedBytes(file: staged) == bytes else {
                throw WindowsError.unsupported("Staged ICC data did not match the original profile.")
            }
            try withWideString(staged) { try require(InstallColorProfileW(nil, $0), "Install Windows color profile") }
            _ = locked.raw
        }
        guard try validatedBytes(file: destination) == bytes else {
            throw WindowsError.unsupported("Installed ICC data did not match the original profile.")
        }
        return fileName
    }

    /// Read-only validation and inventory; never installs or changes a profile, mode, or LUT.
    static func selfCheck() throws {
        _ = try validatedBytes(file: colorDirectory() + "\\" + standardRGBProfile())
        guard try multiStrings([65, 0, 66, 0, 0], count: 2) == ["A", "B"],
            try multiStrings([0], count: 0).isEmpty else {
            throw WindowsError.unsupported("Color profile enumeration self-check failed.")
        }
        let malformedLists: [([WCHAR], DWORD)] = [([65, 0], 1), ([65, 0, 0], 2), ([0, 65], 0)]
        for (units, count) in malformedLists {
            var rejected = false
            do { _ = try multiStrings(units, count: count) } catch { rejected = true }
            guard rejected else { throw WindowsError.unsupported("Malformed color profile list was accepted.") }
        }
        var control = [UInt8](repeating: 0, count: 144)
        func setWord(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { control[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
        }
        setWord(144, at: 0)
        setWord(monitorClass, at: 12)
        setWord(rgbSpace, at: 16)
        setWord(0x61637370, at: 36)
        setWord(1, at: 128)
        setWord(144, at: 136)
        try validateStructure(control)
        for index in [0, 12, 16, 36, 128, 136, 140] {
            var malformed = control
            var rejected = false
            malformed[index] = 0xFF
            do { try validateStructure(malformed) } catch { rejected = true }
            guard rejected else { throw WindowsError.unsupported("Malformed ICC control was accepted.") }
        }
        var descriptionControl = control
        descriptionControl.append(contentsOf: [0x64, 0x65, 0x73, 0x63, 0, 0, 0, 0, 0, 0, 0, 7])
        descriptionControl.append(contentsOf: Array("Sample".utf8) + [0])
        descriptionControl[3] = UInt8(descriptionControl.count)
        descriptionControl.replaceSubrange(132..<136, with: [0x64, 0x65, 0x73, 0x63])
        descriptionControl[143] = 19
        try validateStructure(descriptionControl)
        guard profileDescription(descriptionControl) == "Sample" else {
            throw WindowsError.unsupported("ICC description control failed.")
        }
        descriptionControl[152] = 0xFF
        guard profileDescription(descriptionControl) == nil else {
            throw WindowsError.unsupported("Out-of-bounds ICC description was accepted.")
        }
        var displays = 0
        var profiles = 0
        for output in try discoverDisplays() where output.isPhysical && !output.isCloned && !output.isHDR {
            let inventory = try snapshot(output: output)
            _ = try validatedBytes(file: colorDirectory() + "\\" + inventory.effective)
            displays += 1
            profiles += inventory.installed.count
        }
        Console.writeLine(
            "PASS: ICC bounds / list controls; read-only inventory: \(displays) SDR displays, \(profiles) valid installed profiles; no settings changed")
    }
}
