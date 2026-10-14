// SPDX-License-Identifier: MIT
import SearchContentABI
import WinSDK

/// Software WARP avoids loading legacy GPU drivers in a disposable document worker.
final class NativeSearchPDFRenderer {
  private let device: SearchContentReference<ID3D11Device>
  private let context: SearchContentReference<ID3D11DeviceContext>
  private let renderer: SearchContentReference<IPdfRendererNative>

  init() throws {
    var devicePointer: UnsafeMutablePointer<ID3D11Device>?
    var contextPointer: UnsafeMutablePointer<ID3D11DeviceContext>?
    var feature = D3D_FEATURE_LEVEL_9_1
    try NativeSearchContent.check(D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, nil,
      UINT(D3D11_CREATE_DEVICE_BGRA_SUPPORT.rawValue), nil, 0, UINT(D3D11_SDK_VERSION),
      &devicePointer, &feature, &contextPointer), "Create software PDF rasterizer")
    guard let devicePointer, let contextPointer else {
      if let devicePointer { _ = devicePointer.pointee.lpVtbl.pointee.Release(devicePointer) }
      if let contextPointer { _ = contextPointer.pointee.lpVtbl.pointee.Release(contextPointer) }
      throw WindowsError.unsupported("Software PDF rasterizer unavailable.")
    }
    device = SearchContentReference(devicePointer)
    context = SearchContentReference(contextPointer)
    let dxgi = try NativeSearchMedia.query(device.raw,
      id: "54ec77fa-1377-44e6-8c32-88fd5f44c84c", as: IDXGIDevice.self)
    var rendererPointer: UnsafeMutablePointer<IPdfRendererNative>?
    try NativeSearchContent.check(PdfCreateRenderer(dxgi.raw, &rendererPointer),
      "Create software PDF renderer")
    guard let rendererPointer else { throw WindowsError.unsupported("PDF renderer unavailable.") }
    renderer = SearchContentReference(rendererPointer)
  }

  func image(page: UnsafeMutablePointer<__x_ABI_CWindows_CData_CPdf_CIPdfPage>,
    size: __x_ABI_CWindows_CFoundation_CSize) throws -> SearchContentImage {
    let factor = 2048 / max(size.Width, size.Height)
    let width = max(1, UINT(size.Width * factor)), height = max(1, UINT(size.Height * factor))
    var description = D3D11_TEXTURE2D_DESC()
    description.Width = width; description.Height = height
    description.MipLevels = 1; description.ArraySize = 1
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM
    description.SampleDesc.Count = 1
    description.Usage = D3D11_USAGE_DEFAULT
    description.BindFlags = UINT(D3D11_BIND_RENDER_TARGET.rawValue | D3D11_BIND_SHADER_RESOURCE.rawValue)
    var texturePointer: UnsafeMutablePointer<ID3D11Texture2D>?
    try NativeSearchContent.check(device.raw.pointee.lpVtbl.pointee.CreateTexture2D(device.raw,
      &description, nil, &texturePointer), "Create bounded PDF surface")
    guard let texturePointer else { throw WindowsError.unsupported("PDF surface unavailable.") }
    let texture = SearchContentReference(texturePointer)
    let surface = try NativeSearchMedia.query(texture.raw,
      id: "cafcb56c-6ac3-4889-bf47-9e23bbd260ec", as: IDXGISurface.self)
    var parameters = PDF_RENDER_PARAMS()
    parameters.SourceRect = D2D1_RECT_F(left: 0, top: 0, right: size.Width, bottom: size.Height)
    parameters.DestinationWidth = width; parameters.DestinationHeight = height
    parameters.BackgroundColor = D2D1_COLOR_F(r: 1, g: 1, b: 1, a: 1)
    parameters.IgnoreHighContrast = 1
    let unknown = UnsafeMutableRawPointer(page).assumingMemoryBound(to: IUnknown.self)
    try NativeSearchContent.check(renderer.raw.pointee.lpVtbl.pointee.RenderPageToSurface(
      renderer.raw, unknown, surface.raw, POINT(x: 0, y: 0), &parameters), "Rasterize PDF page in software")
    description.Usage = D3D11_USAGE_STAGING
    description.BindFlags = 0
    description.CPUAccessFlags = UINT(D3D11_CPU_ACCESS_READ.rawValue)
    var stagingPointer: UnsafeMutablePointer<ID3D11Texture2D>?
    try NativeSearchContent.check(device.raw.pointee.lpVtbl.pointee.CreateTexture2D(device.raw,
      &description, nil, &stagingPointer), "Create PDF readback buffer")
    guard let stagingPointer else { throw WindowsError.unsupported("PDF readback unavailable.") }
    let staging = SearchContentReference(stagingPointer)
    let source = UnsafeMutableRawPointer(texture.raw).assumingMemoryBound(to: ID3D11Resource.self)
    let target = UnsafeMutableRawPointer(staging.raw).assumingMemoryBound(to: ID3D11Resource.self)
    context.raw.pointee.lpVtbl.pointee.CopyResource(context.raw, target, source)
    var mapped = D3D11_MAPPED_SUBRESOURCE()
    try NativeSearchContent.check(context.raw.pointee.lpVtbl.pointee.Map(context.raw, target,
      0, D3D11_MAP_READ, 0, &mapped), "Read software PDF pixels")
    defer { context.raw.pointee.lpVtbl.pointee.Unmap(context.raw, target, 0) }
    guard let data = mapped.pData, mapped.RowPitch >= width * 4,
      mapped.RowPitch <= width * 4 + 4096 else {
      throw WindowsError.unsupported("Unsupported PDF surface stride.")
    }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var pixels = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
    for row in 0..<Int(height) {
      let source = UnsafeBufferPointer(start: bytes.advanced(by: row * Int(mapped.RowPitch)),
        count: Int(width) * 4)
      pixels.replaceSubrange((row * Int(width) * 4)..<((row + 1) * Int(width) * 4), with: source)
    }
    return SearchContentImage(width: Int(width), height: Int(height), bgra: pixels)
  }
}
