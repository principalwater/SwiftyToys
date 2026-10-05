// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

/// Owns a WDDM adapter/device pair. Native handles are destroyed exactly once.
struct NativeGammaSession: ~Copyable {
    let adapter: D3DKMT_HANDLE
    let device: D3DKMT_HANDLE
    let source: UInt32
    let original: GammaRamp

    init(output: DisplayOutput, emulateOwnership: Bool) throws {
        guard output.isPhysical, !output.isCloned, !output.isHDR else {
            throw WindowsError.unsupported("Native gamma needs an independent physical SDR output.")
        }
        let dc = withWideString(output.device) { CreateDCW(nil, $0, nil, nil) }
        guard let dc else { throw WindowsError.api("CreateDC", GetLastError()) }
        defer { DeleteDC(dc) }
        var samples = Array(repeating: UInt16(0), count: 768)
        let hasBaseline = samples.withUnsafeMutableBytes { GetDeviceGammaRamp(dc, $0.baseAddress) }
        guard hasBaseline else { throw WindowsError.api("GetDeviceGammaRamp", GetLastError()) }
        let baseline = try GammaRamp(samples: samples)
        var opened = D3DKMT_OPENADAPTERFROMHDC()
        opened.hDc = dc
        var status = D3DKMTOpenAdapterFromHdc(&opened)
        guard status >= 0 else { throw WindowsError.status("D3DKMTOpenAdapterFromHdc", status) }
        var keepAdapter = false
        defer {
            if !keepAdapter {
                var close = D3DKMT_CLOSEADAPTER()
                close.hAdapter = opened.hAdapter
                D3DKMTCloseAdapter(&close)
            }
        }
        guard opened.AdapterLuid.LowPart == output.adapterLow,
            opened.AdapterLuid.HighPart == output.adapterHigh,
            opened.VidPnSourceId == output.source
        else {
            throw WindowsError.unsupported("Display mapping changed before opening the native source.")
        }
        var created = D3DKMT_CREATEDEVICE()
        created.hAdapter = opened.hAdapter
        status = D3DKMTCreateDevice(&created)
        guard status >= 0 else { throw WindowsError.status("D3DKMTCreateDevice", status) }
        var keepDevice = false
        defer {
            if !keepDevice {
                var destroy = D3DKMT_DESTROYDEVICE()
                destroy.hDevice = created.hDevice
                D3DKMTDestroyDevice(&destroy)
            }
        }
        if emulateOwnership {
            // EMULATED allows gamma without taking exclusive primary ownership.
            // Keep output duplication explicitly permitted for Sunshine/DDA.
            var ownerType = D3DKMT_VIDPNSOURCEOWNER_EMULATED
            var sourceID = output.source
            status = withUnsafePointer(to: &ownerType) { typePointer in
                withUnsafePointer(to: &sourceID) { sourcePointer in
                    var request = D3DKMT_SETVIDPNSOURCEOWNER1()
                    request.Version0.hDevice = created.hDevice
                    request.Version0.pType = typePointer
                    request.Version0.pVidPnSourceId = sourcePointer
                    request.Version0.VidPnSourceCount = 1
                    request.Flags.AllowOutputDuplication = 1
                    return D3DKMTSetVidPnSourceOwner1(&request)
                }
            }
            guard status >= 0 else { throw WindowsError.status("D3DKMTSetVidPnSourceOwner1 (emulated)", status) }
        }
        adapter = opened.hAdapter
        device = created.hDevice
        source = opened.VidPnSourceId
        original = baseline
        keepDevice = true
        keepAdapter = true
    }

    /// Submits a scoped native ramp. Acceptance still needs hardware validation.
    func apply(_ level: BrightnessLevel) throws(WindowsError) {
        try submit(original.scaled(to: level))
    }

    /// Restores the saved baseline explicitly before session destruction.
    func restore() throws(WindowsError) { try submit(original) }

    func restoreSaved(_ ramp: GammaRamp) throws(WindowsError) { try submit(ramp) }

    private func submit(_ ramp: GammaRamp) throws(WindowsError) {
        var nativeRamp = D3DDDI_GAMMA_RAMP_RGB256x3x16()
        ramp.withUnsafeBufferPointer { samples in
            withUnsafeMutableBytes(of: &nativeRamp) { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(samples))
            }
        }
        let status = withUnsafeMutablePointer(to: &nativeRamp) { pointer in
            var request = D3DKMT_SETGAMMARAMP()
            request.hDevice = device
            request.VidPnSourceId = source
            request.Type = D3DDDI_GAMMARAMP_RGB256x3x16
            request.pGammaRampRgb256x3x16 = pointer
            request.Size = UINT(MemoryLayout<D3DDDI_GAMMA_RAMP_RGB256x3x16>.size)
            return D3DKMTSetGammaRamp(&request)
        }
        guard status >= 0 else { throw .status("D3DKMTSetGammaRamp", status) }
    }

    deinit {
        var destroy = D3DKMT_DESTROYDEVICE()
        destroy.hDevice = device
        D3DKMTDestroyDevice(&destroy)
        var close = D3DKMT_CLOSEADAPTER()
        close.hAdapter = adapter
        D3DKMTCloseAdapter(&close)
    }
}
