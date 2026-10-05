// SPDX-License-Identifier: MIT

import BrightnessCore
import CRT
import WinSDK
import WindowsDisplayABI

/// ADL uses the callback's allocator; every returned allocation uses CRT free.
private let amdAllocate: BC_ADLAllocate = { size in size > 0 ? malloc(Int(size)) : nil }
func ansiString<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
struct AMDOutput: Sendable {
    let adapter: Int32
    let display: Int32
    let name: String
    let legacyID: String
    let device: String
}
/// Confined to the display executor. Resolves optional driver APIs at runtime.
final class AMDControl {
    private let library: HMODULE
    private let destroy: BC_ADLDestroy
    private let count: BC_ADLAdapterCount
    private let adapters: BC_ADLAdapterInfo
    private let displays: BC_ADLDisplays
    private let colorGet: BC_ADLColorGet
    private let colorSet: BC_ADLColorSet

    init() throws {
        guard
            let library = withWideString(
                "atiadlxx.dll", { LoadLibraryExW($0, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)) })
        else {
            throw WindowsError.unsupported("AMD display-color API is unavailable on this driver.")
        }
        var keep = false
        defer { if !keep { FreeLibrary(library) } }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = name.withCString({ GetProcAddress(library, $0) }) else {
                throw WindowsError.unsupported("AMD driver does not expose \(name).")
            }
            return unsafeBitCast(address, to: T.self)
        }
        let create = try symbol("ADL_Main_Control_Create", BC_ADLCreate.self)
        destroy = try symbol("ADL_Main_Control_Destroy", BC_ADLDestroy.self)
        count = try symbol("ADL_Adapter_NumberOfAdapters_Get", BC_ADLAdapterCount.self)
        adapters = try symbol("ADL_Adapter_AdapterInfo_Get", BC_ADLAdapterInfo.self)
        displays = try symbol("ADL_Display_DisplayInfo_Get", BC_ADLDisplays.self)
        colorGet = try symbol("ADL_Display_Color_Get", BC_ADLColorGet.self)
        colorSet = try symbol("ADL_Display_Color_Set", BC_ADLColorSet.self)
        try Self.check(create(amdAllocate, 1), "initialize AMD display controls")
        self.library = library
        keep = true
    }

    private static func check(_ status: Int32, _ operation: String) throws(WindowsError) {
        guard status == 0 else { throw .status(operation, status) }
    }

    func enumerate() throws -> [AMDOutput] {
        var number: Int32 = 0
        try Self.check(count(&number), "enumerate AMD adapters")
        guard number >= 0, number <= 256 else { throw WindowsError.unsupported("Invalid AMD adapter count.") }
        var values = Array(repeating: BC_ADLAdapter(), count: Int(number))
        for i in values.indices { values[i].size = Int32(MemoryLayout<BC_ADLAdapter>.size) }
        try values.withUnsafeMutableBufferPointer {
            try Self.check(
                adapters($0.baseAddress, Int32($0.count * MemoryLayout<BC_ADLAdapter>.stride)), "read AMD adapters")
        }
        let byIndex = Dictionary(values.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var outputs: [String: AMDOutput] = [:]
        for adapter in values where adapter.present != 0 {
            var count: Int32 = 0
            var pointer: UnsafeMutablePointer<BC_ADLDisplayInfo>?
            guard displays(adapter.index, &count, &pointer, 0) == 0 else { continue }
            defer { free(pointer) }
            guard count >= 0, count <= 256, let pointer else { continue }
            for display in UnsafeBufferPointer(start: pointer, count: Int(count)) where (display.value & 3) == 3 {
                let name = ansiString(display.name)
                guard !name.isEmpty else { continue }
                let id = "\(adapter.bus):\(adapter.device):\(adapter.function):\(display.id.physicalDisplay):\(name)"
                let logical = byIndex[display.id.logicalAdapter] ?? adapter
                if outputs[id] == nil {
                    outputs[id] = AMDOutput(
                        adapter: adapter.index, display: display.id.logicalDisplay, name: name,
                        legacyID: id, device: ansiString(logical.display))
                }
            }
        }
        return outputs.values.sorted { $0.legacyID < $1.legacyID }
    }

    func get(_ output: AMDOutput, type: Int32) throws(WindowsError) -> Int {
        var current: Int32 = 0
        var fallback: Int32 = 0
        var minimum: Int32 = 0
        var maximum: Int32 = 0
        var step: Int32 = 0
        try Self.check(
            colorGet(output.adapter, output.display, type, &current, &fallback, &minimum, &maximum, &step),
            "read AMD color control")
        return Int(current)
    }

    func set(_ output: AMDOutput, brightness: Int, contrast: Int) throws(WindowsError) {
        guard (-100...100).contains(brightness), (0...200).contains(contrast) else {
            throw .unsupported("AMD color state is outside its supported range.")
        }
        try Self.check(colorSet(output.adapter, output.display, 2, Int32(contrast)), "set AMD contrast")
        try Self.check(colorSet(output.adapter, output.display, 1, Int32(brightness)), "set AMD centering compensation")
        guard try get(output, type: 1) == brightness, try get(output, type: 2) == contrast else {
            throw .unsupported("AMD did not retain the requested RGB output gain.")
        }
    }

    deinit {
        _ = destroy()
        FreeLibrary(library)
    }
}
