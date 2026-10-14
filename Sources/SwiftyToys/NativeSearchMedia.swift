// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchContentABI
import WinSDK

/// OS readers only. Returned pixels/samples are transient and are never a substitute for embeddings.
enum NativeSearchMedia {
  static func guid(_ text: String) throws -> GUID {
    var result = GUID()
    try withWideString("{" + text + "}") {
      try NativeSearchContent.check(CLSIDFromString($0, &result), "Read content interface ID")
    }
    return result
  }

  static func query<T, U>(_ source: UnsafeMutablePointer<T>, id: String,
    as: U.Type) throws -> SearchContentReference<U> {
    let unknown = UnsafeMutableRawPointer(source).assumingMemoryBound(to: IUnknown.self)
    var identifier = try guid(id), pointer: UnsafeMutableRawPointer?
    try NativeSearchContent.check(unknown.pointee.lpVtbl.pointee.QueryInterface(
      unknown, &identifier, &pointer), "Read content interface")
    guard let pointer else { throw WindowsError.unsupported("Content interface unavailable.") }
    return SearchContentReference(pointer.assumingMemoryBound(to: U.self))
  }

  static func factory<T>(_ name: String, id: String,
    as: T.Type) throws -> SearchContentReference<T> {
    var identifier = try guid(id), pointer: UnsafeMutableRawPointer?, value: HSTRING?
    try withWideString(name) {
      try NativeSearchContent.check(WindowsCreateString($0, UINT32(name.utf16.count), &value),
        "Create content reader name")
    }
    defer { _ = WindowsDeleteString(value) }
    try NativeSearchContent.check(RoGetActivationFactory(value, &identifier, &pointer),
      "Create Windows content reader")
    guard let pointer else { throw WindowsError.unsupported("Content reader unavailable.") }
    return SearchContentReference(pointer.assumingMemoryBound(to: T.self))
  }

  private static func wic() throws -> SearchContentReference<IWICImagingFactory> {
    var classID = try guid("cacaf262-9370-4615-a13b-9f5539da4c0a")
    var interfaceID = try guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70")
    var pointer: UnsafeMutableRawPointer?
    try NativeSearchContent.check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue),
      &interfaceID, &pointer), "Create Windows image decoder")
    guard let pointer else { throw WindowsError.unsupported("Windows image decoder unavailable.") }
    return SearchContentReference(pointer.assumingMemoryBound(to: IWICImagingFactory.self))
  }

  static func image(path: String) throws -> SearchContentImage {
    let factory = try wic()
    var decoderPointer: UnsafeMutablePointer<IWICBitmapDecoder>?
    try NativeSearchContent.check(withWideString(try NativeFiles.windowsPath(path)) {
      factory.raw.pointee.lpVtbl.pointee.CreateDecoderFromFilename(factory.raw, $0, nil,
        DWORD(GENERIC_READ), WICDecodeMetadataCacheOnDemand, &decoderPointer)
    }, "Decode local image")
    guard let decoderPointer else { throw WindowsError.unsupported("No installed image codec.") }
    let decoder = SearchContentReference(decoderPointer)
    return try decodedImage(decoder)
  }

  private static func decodedImage(_ decoder: SearchContentReference<IWICBitmapDecoder>) throws -> SearchContentImage {
    let factory = try wic()
    var framePointer: UnsafeMutablePointer<IWICBitmapFrameDecode>?
    try NativeSearchContent.check(decoder.raw.pointee.lpVtbl.pointee.GetFrame(decoder.raw, 0,
      &framePointer), "Read image frame")
    guard let framePointer else { throw WindowsError.unsupported("Image has no frame.") }
    let frame = SearchContentReference(framePointer)
    var width: UINT = 0, height: UINT = 0
    try NativeSearchContent.check(frame.raw.pointee.lpVtbl.pointee.GetSize(frame.raw, &width, &height),
      "Read image dimensions")
    guard width > 0, height > 0, width <= 32768, height <= 32768,
      UInt64(width) * UInt64(height) <= 100_000_000 else {
      throw WindowsError.unsupported("Image dimensions exceed the decoder budget.")
    }
    var source = UnsafeMutableRawPointer(frame.raw).assumingMemoryBound(to: IWICBitmapSource.self)
    var rotation: SearchContentReference<IWICBitmapFlipRotator>?
    let orientation = imageOrientation(frame.raw)
    if orientation != 1 {
      var pointer: UnsafeMutablePointer<IWICBitmapFlipRotator>?
      try NativeSearchContent.check(factory.raw.pointee.lpVtbl.pointee.CreateBitmapFlipRotator(
        factory.raw, &pointer), "Create image orientation reader")
      guard let pointer else { throw WindowsError.unsupported("Image orientation reader unavailable.") }
      rotation = SearchContentReference(pointer)
      try NativeSearchContent.check(pointer.pointee.lpVtbl.pointee.Initialize(pointer,
        source, orientationTransform(orientation)), "Apply image orientation")
      try NativeSearchContent.check(pointer.pointee.lpVtbl.pointee.GetSize(pointer, &width,
        &height), "Read oriented image dimensions")
      source = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: IWICBitmapSource.self)
    }
    defer { withExtendedLifetime(rotation) {} }
    let factor = min(1, 2048 / Double(max(width, height)))
    let targetWidth = max(1, UINT(Double(width) * factor))
    let targetHeight = max(1, UINT(Double(height) * factor))
    var scalerPointer: UnsafeMutablePointer<IWICBitmapScaler>?
    try NativeSearchContent.check(factory.raw.pointee.lpVtbl.pointee.CreateBitmapScaler(factory.raw,
      &scalerPointer), "Create bounded image scaler")
    guard let scalerPointer else { throw WindowsError.unsupported("Image scaler unavailable.") }
    let scaler = SearchContentReference(scalerPointer)
    try NativeSearchContent.check(scaler.raw.pointee.lpVtbl.pointee.Initialize(scaler.raw, source,
      targetWidth, targetHeight, WICBitmapInterpolationModeFant), "Scale image")
    var converterPointer: UnsafeMutablePointer<IWICFormatConverter>?
    try NativeSearchContent.check(factory.raw.pointee.lpVtbl.pointee.CreateFormatConverter(factory.raw,
      &converterPointer), "Create image converter")
    guard let converterPointer else { throw WindowsError.unsupported("Image converter unavailable.") }
    let converter = SearchContentReference(converterPointer)
    var format = GUID_WICPixelFormat32bppBGRA
    let scaled = UnsafeMutableRawPointer(scaler.raw).assumingMemoryBound(to: IWICBitmapSource.self)
    try NativeSearchContent.check(converter.raw.pointee.lpVtbl.pointee.Initialize(converter.raw,
      scaled, &format, WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom), "Convert image")
    var pixels = [UInt8](repeating: 0, count: Int(targetWidth) * Int(targetHeight) * 4)
    try NativeSearchContent.check(converter.raw.pointee.lpVtbl.pointee.CopyPixels(converter.raw, nil,
      targetWidth * 4, UINT(pixels.count), &pixels), "Read bounded image pixels")
    return SearchContentImage(width: Int(targetWidth), height: Int(targetHeight), bgra: pixels)
  }

  static func orientationTransform(_ orientation: UInt16) -> WICBitmapTransformOptions {
    switch orientation {
    case 2: return WICBitmapTransformFlipHorizontal
    case 3: return WICBitmapTransformRotate180
    case 4: return WICBitmapTransformFlipVertical
    case 5: return WICBitmapTransformOptions(rawValue:
      WICBitmapTransformRotate90.rawValue | WICBitmapTransformFlipHorizontal.rawValue)
    case 6: return WICBitmapTransformRotate90
    case 7: return WICBitmapTransformOptions(rawValue:
      WICBitmapTransformRotate270.rawValue | WICBitmapTransformFlipHorizontal.rawValue)
    case 8: return WICBitmapTransformRotate270
    default: return WICBitmapTransformRotate0
    }
  }

  private static func imageOrientation(_ frame: UnsafeMutablePointer<IWICBitmapFrameDecode>) -> UInt16 {
    var pointer: UnsafeMutablePointer<IWICMetadataQueryReader>?
    guard frame.pointee.lpVtbl.pointee.GetMetadataQueryReader(frame, &pointer) >= 0,
      let pointer else { return 1 }
    let reader = SearchContentReference(pointer)
    for path in ["/app1/ifd/{ushort=274}", "/ifd/{ushort=274}"] {
      var value = PROPVARIANT()
      defer { _ = PropVariantClear(&value) }
      if withWideString(path, { reader.raw.pointee.lpVtbl.pointee.GetMetadataByName(
        reader.raw, $0, &value) }) >= 0, value.vt == VARTYPE(VT_UI2.rawValue),
        (1...8).contains(value.uiVal) { return value.uiVal }
    }
    return 1
  }

  static func ocr(_ image: SearchContentImage, deadline: UInt64,
    cancelled: () -> Bool) throws -> String {
    try NativeSearchContent.checkDeadline(deadline, cancelled)
    guard image.width > 0, image.height > 0, image.width <= 2048, image.height <= 2048,
      image.bgra.count == image.width * image.height * 4 else {
      throw WindowsError.unsupported("OCR image exceeds its pixel budget.")
    }
    let wicFactory = try wic()
    var bitmapPointer: UnsafeMutablePointer<IWICBitmap>?, format = GUID_WICPixelFormat32bppBGRA
    try image.bgra.withUnsafeBufferPointer {
      try NativeSearchContent.check(wicFactory.raw.pointee.lpVtbl.pointee.CreateBitmapFromMemory(
        wicFactory.raw, UINT(image.width), UINT(image.height), &format, UINT(image.width * 4),
        UINT($0.count), UnsafeMutablePointer(mutating: $0.baseAddress), &bitmapPointer), "Prepare OCR bitmap")
    }
    guard let bitmapPointer else { throw WindowsError.unsupported("OCR bitmap unavailable.") }
    let bitmap = SearchContentReference(bitmapPointer)
    let nativeFactory = try factory("Windows.Graphics.Imaging.SoftwareBitmap",
      id: "c3c181ec-2914-4791-af02-02d224a10b43", as: ISoftwareBitmapNativeFactory.self)
    var softwareID = try guid("689e0708-7eef-483f-963f-da938818e073")
    var softwarePointer: UnsafeMutableRawPointer?
    try NativeSearchContent.check(nativeFactory.raw.pointee.lpVtbl.pointee.CreateFromWICBitmap(
      nativeFactory.raw, bitmap.raw, true, &softwareID, &softwarePointer), "Prepare Windows OCR image")
    guard let softwarePointer else { throw WindowsError.unsupported("Windows OCR image unavailable.") }
    let software = SearchContentReference(softwarePointer.assumingMemoryBound(
      to: __x_ABI_CWindows_CGraphics_CImaging_CISoftwareBitmap.self))
    defer {
      if let close = try? query(software.raw, id: "30d5a829-7fa4-4026-83bb-d75bae4ea99e",
        as: __x_ABI_CWindows_CFoundation_CIClosable.self) {
        _ = close.raw.pointee.lpVtbl.pointee.Close(close.raw)
      }
    }
    let statics = try factory("Windows.Media.Ocr.OcrEngine",
      id: "5bffa85a-3384-3540-9940-699120d428a8", as: __x_ABI_CWindows_CMedia_COcr_CIOcrEngineStatics.self)
    var enginePointer: UnsafeMutablePointer<__x_ABI_CWindows_CMedia_COcr_CIOcrEngine>?
    try NativeSearchContent.check(statics.raw.pointee.lpVtbl.pointee.TryCreateFromUserProfileLanguages(
      statics.raw, &enginePointer), "Select installed OCR language")
    guard let enginePointer else { throw WindowsError.unsupported("No installed OCR language.") }
    let engine = SearchContentReference(enginePointer)
    var operationPointer: UnsafeMutablePointer<__FIAsyncOperation_1_Windows__CMedia__COcr__COcrResult>?
    try NativeSearchContent.check(engine.raw.pointee.lpVtbl.pointee.RecognizeAsync(engine.raw,
      software.raw, &operationPointer), "Recognize image text")
    guard let operationPointer else { throw WindowsError.unsupported("OCR operation unavailable.") }
    let operation = SearchContentReference(operationPointer)
    let info = try query(operation.raw, id: "00000036-0000-0000-c000-000000000046", as: IAsyncInfo.self)
    defer { _ = info.raw.pointee.lpVtbl.pointee.Close(info.raw) }
    while true {
      var status = AsyncStatus(rawValue: 0)
      try NativeSearchContent.check(info.raw.pointee.lpVtbl.pointee.get_Status(info.raw, &status),
        "Read OCR status")
      if status.rawValue == 1 { break }
      guard status.rawValue == 0, !cancelled(), GetTickCount64() < deadline else {
        _ = info.raw.pointee.lpVtbl.pointee.Cancel(info.raw)
        throw WindowsError.unsupported("OCR unavailable, cancelled or timed out.")
      }
      Sleep(10)
    }
    var resultPointer: UnsafeMutablePointer<__x_ABI_CWindows_CMedia_COcr_CIOcrResult>?
    try NativeSearchContent.check(operation.raw.pointee.lpVtbl.pointee.GetResults(operation.raw,
      &resultPointer), "Read recognized text")
    guard let resultPointer else { throw WindowsError.unsupported("OCR returned no result.") }
    let result = SearchContentReference(resultPointer)
    var value: HSTRING?
    try NativeSearchContent.check(result.raw.pointee.lpVtbl.pointee.get_Text(result.raw, &value),
      "Read image text")
    defer { _ = WindowsDeleteString(value) }
    var length: UINT32 = 0
    guard let buffer = WindowsGetStringRawBuffer(value, &length), length <= 65536 else {
      throw WindowsError.unsupported("OCR text exceeds its budget.")
    }
    return String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF16.self)
  }

  private static func reader(path: String, video: Bool, media: SearchMediaFoundation) throws -> SearchContentReference<IMFSourceReader> {
    var attributePointer: UnsafeMutablePointer<IMFAttributes>?
    try NativeSearchContent.check(media.createAttributes(&attributePointer, 2), "Create media decoder options")
    guard let attributePointer else { throw WindowsError.unsupported("Media options unavailable.") }
    let attributes = SearchContentReference(attributePointer)
    var processing = MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING
    try NativeSearchContent.check(attributes.raw.pointee.lpVtbl.pointee.SetUINT32(attributes.raw,
      &processing, video ? 1 : 0), "Set native media conversion")
    var pointer: UnsafeMutablePointer<IMFSourceReader>?
    try NativeSearchContent.check(withWideString(try NativeFiles.windowsPath(path)) {
      media.createReader($0, attributes.raw, &pointer)
    }, "Open local media with installed codecs")
    guard let pointer else { throw WindowsError.unsupported("No installed media codec.") }
    let reader = SearchContentReference(pointer)
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.SetStreamSelection(reader.raw,
      DWORD(truncatingIfNeeded: MF_SOURCE_READER_ALL_STREAMS.rawValue), false), "Deselect unused media streams")
    return reader
  }

  private static func mediaType(_ reader: SearchContentReference<IMFSourceReader>, video: Bool, media: SearchMediaFoundation)
    throws -> SearchContentReference<IMFMediaType> {
    let stream = DWORD(truncatingIfNeeded: (video ? MF_SOURCE_READER_FIRST_VIDEO_STREAM : MF_SOURCE_READER_FIRST_AUDIO_STREAM).rawValue)
    var pointer: UnsafeMutablePointer<IMFMediaType>?
    try NativeSearchContent.check(media.createType(&pointer), "Create bounded media format")
    guard let pointer else { throw WindowsError.unsupported("Media format unavailable.") }
    let type = SearchContentReference(pointer)
    var majorKey = MF_MT_MAJOR_TYPE, major = video ? MFMediaType_Video : MFMediaType_Audio
    var subtypeKey = MF_MT_SUBTYPE, subtype = video ? MFVideoFormat_RGB32 : MFAudioFormat_PCM
    try NativeSearchContent.check(type.raw.pointee.lpVtbl.pointee.SetGUID(type.raw, &majorKey,
      &major), "Select media kind")
    try NativeSearchContent.check(type.raw.pointee.lpVtbl.pointee.SetGUID(type.raw, &subtypeKey,
      &subtype), "Select uncompressed media")
    if !video {
      for (key, value): (GUID, UINT32) in [(MF_MT_AUDIO_NUM_CHANNELS, 1),
        (MF_MT_AUDIO_SAMPLES_PER_SECOND, 16000), (MF_MT_AUDIO_BITS_PER_SAMPLE, 16),
        (MF_MT_AUDIO_BLOCK_ALIGNMENT, 2), (MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 32000)] {
        var key = key
        try NativeSearchContent.check(type.raw.pointee.lpVtbl.pointee.SetUINT32(type.raw, &key,
          value), "Select mono 16 kHz audio")
      }
    }
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.SetCurrentMediaType(reader.raw,
      stream, nil, type.raw), "Decode media using installed Windows codecs")
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.SetStreamSelection(reader.raw,
      stream, true), "Select media stream")
    var current: UnsafeMutablePointer<IMFMediaType>?
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.GetCurrentMediaType(reader.raw,
      stream, &current), "Validate decoded media format")
    guard let current else { throw WindowsError.unsupported("Decoded media format unavailable.") }
    let decoded = SearchContentReference(current)
    if !video {
      for (key, expected): (GUID, UINT32) in [(MF_MT_AUDIO_NUM_CHANNELS, 1),
        (MF_MT_AUDIO_SAMPLES_PER_SECOND, 16000), (MF_MT_AUDIO_BITS_PER_SAMPLE, 16),
        (MF_MT_AUDIO_BLOCK_ALIGNMENT, 2)] {
        var key = key, actual: UINT32 = 0
        try NativeSearchContent.check(decoded.raw.pointee.lpVtbl.pointee.GetUINT32(decoded.raw,
          &key, &actual), "Validate decoded audio format")
        guard actual == expected else { throw WindowsError.unsupported("The codec did not produce mono 16 kHz PCM.") }
      }
    }
    return decoded
  }

  private static func seek(_ reader: SearchContentReference<IMFSourceReader>, milliseconds: Int64) throws {
    guard milliseconds >= 0, milliseconds < Int64.max / 10000 else {
      throw WindowsError.unsupported("Invalid media position.")
    }
    if milliseconds == 0 { return }
    var format = GUID(), value = PROPVARIANT()
    value.vt = VARTYPE(VT_I8.rawValue); value.hVal.QuadPart = milliseconds * 10000
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.SetCurrentPosition(reader.raw,
      &format, &value), "Seek local media")
  }

  static func extract(path: String, video: Bool, startMilliseconds: Int64, deadline: UInt64,
    cancelled: () -> Bool, emit: (SearchContentFragment) throws -> Void) throws -> SearchContentReport {
    let media = try SearchMediaFoundation()
    try NativeSearchContent.check(media.startup(0x00020070, DWORD(MFSTARTUP_FULL)), "Start native media reader")
    defer { _ = media.shutdown() }
    var statuses: [String] = []
    var continuation: Int64?
    if video {
      var fragments: [SearchContentFragment] = []
      do {
        let source = try reader(path: path, video: true, media: media)
        let type = try mediaType(source, video: true, media: media)
        var key = MF_MT_FRAME_SIZE, size: UINT64 = 0
        try NativeSearchContent.check(type.raw.pointee.lpVtbl.pointee.GetUINT64(type.raw, &key,
          &size), "Read video dimensions")
        let width = Int(size >> 32), height = Int(size & 0xffffffff)
        guard width > 0, height > 0, width * height <= 4_194_304 else {
          throw WindowsError.unsupported("Video frames exceed the 4 megapixel decoder budget.")
        }
        var strideKey = MF_MT_DEFAULT_STRIDE, stride: UINT32 = 0
        guard type.raw.pointee.lpVtbl.pointee.GetUINT32(type.raw, &strideKey, &stride) >= 0 else {
          throw WindowsError.unsupported("Video frame layout unavailable.")
        }
        var frames = 0
        for step in 0..<3 {
          try NativeSearchContent.checkDeadline(deadline, cancelled)
          let position = startMilliseconds + Int64(step) * 5000
          try seek(source, milliseconds: position)
          if let fragment = try readFrame(source, width: width, height: height,
            stride: Int(Int32(bitPattern: stride)), position: position, deadline: deadline,
            cancelled: cancelled) {
            fragments.append(fragment); frames += 1
          } else { break }
        }
        statuses.append("\(frames) sampled video frames from \(startMilliseconds) ms")
        if frames == 3 { continuation = startMilliseconds + 15000 }
      } catch { statuses.append("Video codec or bounded frame layout unavailable") }
      try NativeSearchContent.checkDeadline(deadline, cancelled)
      for fragment in fragments { try emit(fragment) }
    }
    var audioFragment: SearchContentFragment?
    do {
      let source = try reader(path: path, video: false, media: media)
      _ = try mediaType(source, video: false, media: media)
      try seek(source, milliseconds: startMilliseconds)
      let decoded = try readAudio(source, position: startMilliseconds, deadline: deadline,
        cancelled: cancelled)
      let audio = decoded.samples
      if !audio.isEmpty {
        audioFragment = SearchContentFragment(kind: "audio", milliseconds: startMilliseconds,
          durationMilliseconds: Int64(audio.count) / 16, audio: audio)
      }
      statuses.append("\(audio.count / 16) ms audio from \(startMilliseconds) ms")
      if !decoded.ended, continuation == nil {
        guard !audio.isEmpty else { throw WindowsError.unsupported("Audio decoder made no progress.") }
        continuation = startMilliseconds + max(1, Int64(audio.count) / 16)
      }
    } catch { statuses.append("Audio codec or 16 kHz conversion unavailable") }
    try NativeSearchContent.checkDeadline(deadline, cancelled)
    if let audioFragment { try emit(audioFragment) }
    return SearchContentReport(status: statuses.joined(separator: "; ") + "; partial coverage",
      truncated: continuation != nil, continuationMilliseconds: continuation)
  }

  private static func sample(_ reader: SearchContentReference<IMFSourceReader>, stream: DWORD)
    throws -> (SearchContentReference<IMFSample>?, Int64, Bool) {
    var samplePointer: UnsafeMutablePointer<IMFSample>?, actual: DWORD = 0, flags: DWORD = 0
    var timestamp: LONGLONG = 0
    try NativeSearchContent.check(reader.raw.pointee.lpVtbl.pointee.ReadSample(reader.raw, stream,
      0, &actual, &flags, &timestamp, &samplePointer), "Read decoded media sample")
    if flags & DWORD(MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED.rawValue) != 0 {
      if let samplePointer { _ = samplePointer.pointee.lpVtbl.pointee.Release(samplePointer) }
      throw WindowsError.unsupported("Media format changed during extraction.")
    }
    return (samplePointer.map(SearchContentReference.init), timestamp,
      flags & DWORD(MF_SOURCE_READERF_ENDOFSTREAM.rawValue) != 0)
  }

  private static func bytes(_ sample: SearchContentReference<IMFSample>, maximum: Int) throws -> [UInt8] {
    var pointer: UnsafeMutablePointer<IMFMediaBuffer>?
    try NativeSearchContent.check(sample.raw.pointee.lpVtbl.pointee.ConvertToContiguousBuffer(
      sample.raw, &pointer), "Read contiguous decoded sample")
    guard let pointer else { throw WindowsError.unsupported("Media sample has no buffer.") }
    let buffer = SearchContentReference(pointer)
    var data: UnsafeMutablePointer<BYTE>?, capacity: DWORD = 0, length: DWORD = 0
    try NativeSearchContent.check(buffer.raw.pointee.lpVtbl.pointee.Lock(buffer.raw, &data,
      &capacity, &length), "Lock decoded media sample")
    defer { _ = buffer.raw.pointee.lpVtbl.pointee.Unlock(buffer.raw) }
    guard let data, length <= maximum, length <= capacity else {
      throw WindowsError.unsupported("Decoded sample exceeds its memory budget.")
    }
    return Array(UnsafeBufferPointer(start: data, count: Int(length)))
  }

  private static func readAudio(_ reader: SearchContentReference<IMFSourceReader>, position: Int64,
    deadline: UInt64, cancelled: () -> Bool) throws -> (samples: [Float], ended: Bool) {
    var result: [Float] = []
    result.reserveCapacity(480000)
    for _ in 0..<4096 {
      try NativeSearchContent.checkDeadline(deadline, cancelled)
      let (sample, timestamp, ended) = try sample(reader,
        stream: DWORD(truncatingIfNeeded: MF_SOURCE_READER_FIRST_AUDIO_STREAM.rawValue))
      if let sample {
        let raw = try bytes(sample, maximum: 1_048_576)
        guard raw.count % 2 == 0 else { throw WindowsError.unsupported("Invalid PCM audio buffer.") }
        let delta = Double(position) * 16 - Double(timestamp) * 16000 / 10000000
        let skip = Int(max(0, min(Double(raw.count / 2), delta)))
        for index in stride(from: skip * 2, to: raw.count, by: 2) {
          let value = Int16(bitPattern: UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
          result.append(Float(value) / 32768)
          if result.count == 480000 { return (result, false) }
        }
      }
      if ended { return (result, true) }
    }
    return (result, false)
  }

  private static func readFrame(_ reader: SearchContentReference<IMFSourceReader>, width: Int,
    height: Int, stride: Int, position: Int64, deadline: UInt64, cancelled: () -> Bool)
    throws -> SearchContentFragment? {
    guard abs(stride) >= width * 4, abs(stride) <= width * 4 + 4096 else {
      throw WindowsError.unsupported("Unsupported video stride.")
    }
    for _ in 0..<256 {
      try NativeSearchContent.checkDeadline(deadline, cancelled)
      let (sample, timestamp, ended) = try sample(reader,
        stream: DWORD(truncatingIfNeeded: MF_SOURCE_READER_FIRST_VIDEO_STREAM.rawValue))
      if let sample, timestamp >= position * 10000 {
        let data = try bytes(sample, maximum: abs(stride) * height)
        guard data.count >= abs(stride) * height else {
          throw WindowsError.unsupported("Incomplete decoded video frame.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
          let source = (stride > 0 ? row : height - row - 1) * abs(stride)
          pixels.replaceSubrange((row * width * 4)..<((row + 1) * width * 4),
            with: data[source..<(source + width * 4)])
        }
        return SearchContentFragment(kind: "video", milliseconds: timestamp / 10000,
          image: SearchContentImage(width: width, height: height, bgra: pixels))
      }
      if ended { return nil }
    }
    throw WindowsError.unsupported("Video seek exceeded its sample budget.")
  }
}
