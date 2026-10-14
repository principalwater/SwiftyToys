// SPDX-License-Identifier: MIT
import SearchContentABI
import WinSDK

/// Media Foundation is optional on Windows N. Resolve its OS exports only in the owned media worker.
final class SearchMediaFoundation {
  typealias Startup = @convention(c) (ULONG, DWORD) -> HRESULT
  typealias Shutdown = @convention(c) () -> HRESULT
  typealias CreateAttributes = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<IMFAttributes>?>?, UINT32) -> HRESULT
  typealias CreateType = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<IMFMediaType>?>?) -> HRESULT
  typealias CreateReader = @convention(c) (UnsafePointer<WCHAR>?, UnsafeMutablePointer<IMFAttributes>?, UnsafeMutablePointer<UnsafeMutablePointer<IMFSourceReader>?>?) -> HRESULT

  private let platform: HMODULE
  private let readwrite: HMODULE
  let startup: Startup
  let shutdown: Shutdown
  let createAttributes: CreateAttributes
  let createType: CreateType
  let createReader: CreateReader

  init() throws {
    func load(_ name: String) throws -> HMODULE {
      guard let module = withWideString(name, { LoadLibraryExW($0, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)) }) else {
        throw WindowsError.unsupported("Windows Media Foundation is unavailable. Audio/video decoding requires the Windows Media Feature Pack.")
      }
      return module
    }
    func resolve<T>(_ module: HMODULE, _ name: String, as: T.Type) throws -> T {
      guard let address = name.withCString({ GetProcAddress(module, $0) }) else {
        throw WindowsError.unsupported("The installed Windows Media Foundation is incompatible.")
      }
      return unsafeBitCast(address, to: T.self)
    }
    let platform = try load("mfplat.dll")
    var readwrite: HMODULE?
    var complete = false
    defer {
      if !complete {
        if let readwrite { _ = FreeLibrary(readwrite) }
        _ = FreeLibrary(platform)
      }
    }
    let loaded = try load("mfreadwrite.dll")
    readwrite = loaded
    startup = try resolve(platform, "MFStartup", as: Startup.self)
    shutdown = try resolve(platform, "MFShutdown", as: Shutdown.self)
    createAttributes = try resolve(platform, "MFCreateAttributes", as: CreateAttributes.self)
    createType = try resolve(platform, "MFCreateMediaType", as: CreateType.self)
    createReader = try resolve(loaded, "MFCreateSourceReaderFromURL", as: CreateReader.self)
    self.platform = platform
    self.readwrite = loaded
    complete = true
  }

  deinit {
    _ = FreeLibrary(readwrite)
    _ = FreeLibrary(platform)
  }
}
