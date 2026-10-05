// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

/// A display path discovered through Windows, independently of GPU manufacturer.
struct DisplayOutput: Sendable {
    let id: String
    let name: String
    let device: String
    let adapterLow: UInt32
    let adapterHigh: Int32
    let source: UInt32
    let target: UInt32
    let isPhysical: Bool
    let isCloned: Bool
    let isHDR: Bool

    var candidate: DisplayCandidate {
        DisplayCandidate(id: id, isPhysical: isPhysical, isCloned: isCloned, isHDR: isHDR)
    }
}
/// Calls a variable-size device-info API through a pointer to the whole struct.
private func getDisplayInfo<Value>(_ value: inout Value) -> LONG {
    withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: DISPLAYCONFIG_DEVICE_INFO_HEADER.self, capacity: 1) {
            DisplayConfigGetDeviceInfo($0)
        }
    }
}
/// Excludes WDDM software/indirect adapters even when their EDID looks physical.
private func isPhysicalAdapter(_ luid: LUID) -> Bool {
    var opened = D3DKMT_OPENADAPTERFROMLUID()
    opened.AdapterLuid = luid
    guard D3DKMTOpenAdapterFromLuid(&opened) >= 0 else { return false }
    defer {
        var close = D3DKMT_CLOSEADAPTER()
        close.hAdapter = opened.hAdapter
        D3DKMTCloseAdapter(&close)
    }
    var type = D3DKMT_ADAPTERTYPE()
    let result = withUnsafeMutablePointer(to: &type) { pointer in
        var query = D3DKMT_QUERYADAPTERINFO()
        query.hAdapter = opened.hAdapter
        query.Type = KMTQAITYPE_ADAPTERTYPE
        query.pPrivateDriverData = UnsafeMutableRawPointer(pointer)
        query.PrivateDriverDataSize = UINT(MemoryLayout<D3DKMT_ADAPTERTYPE>.size)
        return D3DKMTQueryAdapterInfo(&query)
    }
    return result >= 0 && type.SoftwareDevice == 0 && type.IndirectDisplayDevice == 0
}
/// Enumerates active Windows display paths and excludes shared/virtual scanout.
func discoverDisplays() throws(WindowsError) -> [DisplayOutput] {
    for _ in 0..<4 {
        var pathCount: UINT32 = 0
        var modeCount: UINT32 = 0
        var result = GetDisplayConfigBufferSizes(UINT32(QDC_ONLY_ACTIVE_PATHS), &pathCount, &modeCount)
        guard result == ERROR_SUCCESS else { throw .api("GetDisplayConfigBufferSizes", UInt32(result)) }
        guard pathCount <= 256, modeCount <= 1024 else { throw .unsupported("Unexpected display-path count.") }
        var paths = Array(repeating: DISPLAYCONFIG_PATH_INFO(), count: Int(pathCount))
        var modes = Array(repeating: DISPLAYCONFIG_MODE_INFO(), count: Int(modeCount))
        result = paths.withUnsafeMutableBufferPointer { pathBuffer in
            modes.withUnsafeMutableBufferPointer { modeBuffer in
                QueryDisplayConfig(
                    UINT32(QDC_ONLY_ACTIVE_PATHS), &pathCount, pathBuffer.baseAddress,
                    &modeCount, modeBuffer.baseAddress, nil)
            }
        }
        if result == ERROR_INSUFFICIENT_BUFFER { continue }
        guard result == ERROR_SUCCESS else { throw .api("QueryDisplayConfig", UInt32(result)) }
        let active = Array(paths.prefix(Int(pathCount)))
        var outputs: [DisplayOutput] = []
        for path in active {
            var sourceName = DISPLAYCONFIG_SOURCE_DEVICE_NAME()
            sourceName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
            sourceName.header.size = UINT32(MemoryLayout.size(ofValue: sourceName))
            sourceName.header.adapterId = path.sourceInfo.adapterId
            sourceName.header.id = path.sourceInfo.id
            var targetName = DISPLAYCONFIG_TARGET_DEVICE_NAME()
            targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            targetName.header.size = UINT32(MemoryLayout.size(ofValue: targetName))
            targetName.header.adapterId = path.targetInfo.adapterId
            targetName.header.id = path.targetInfo.id
            guard getDisplayInfo(&sourceName) == 0, getDisplayInfo(&targetName) == 0 else { continue }
            var color = DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO()
            color.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO
            color.header.size = UINT32(MemoryLayout.size(ofValue: color))
            color.header.adapterId = path.targetInfo.adapterId
            color.header.id = path.targetInfo.id
            let knowsHDR = getDisplayInfo(&color) == 0
            let technology = path.targetInfo.outputTechnology
            let indirect =
                technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED
                || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_VIRTUAL
                || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_MIRACAST
                || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_OTHER
            let clone =
                active.filter {
                    $0.sourceInfo.adapterId.LowPart == path.sourceInfo.adapterId.LowPart
                        && $0.sourceInfo.adapterId.HighPart == path.sourceInfo.adapterId.HighPart
                        && $0.sourceInfo.id == path.sourceInfo.id
                }.count > 1
            let monitorPath = wideString(targetName.monitorDevicePath)
            outputs.append(
                DisplayOutput(
                    id: "\(monitorPath)|\(targetName.connectorInstance)",
                    name: wideString(targetName.monitorFriendlyDeviceName),
                    device: wideString(sourceName.viewGdiDeviceName),
                    adapterLow: path.sourceInfo.adapterId.LowPart, adapterHigh: path.sourceInfo.adapterId.HighPart,
                    source: path.sourceInfo.id, target: path.targetInfo.id,
                    isPhysical: !indirect && !monitorPath.isEmpty && isPhysicalAdapter(path.sourceInfo.adapterId),
                    isCloned: clone,
                    isHDR: !knowsHDR || color.advancedColorEnabled != 0))
        }
        return outputs
    }
    throw .api("Display topology changed repeatedly", UInt32(ERROR_INSUFFICIENT_BUFFER))
}
