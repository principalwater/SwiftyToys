// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchContentABI
import WinSDK

enum NativeSearchContentSelfTest {
  static func run() throws {
    try NativeSearchContent.selfCheck()
    try NativeEmbeddingMediaEngine.selfCheck()
    guard DWORD(truncatingIfNeeded: MF_SOURCE_READER_ALL_STREAMS.rawValue) == 0xfffffffe,
      DWORD(truncatingIfNeeded: MF_SOURCE_READER_FIRST_AUDIO_STREAM.rawValue) == 0xfffffffd,
      DWORD(truncatingIfNeeded: MF_SOURCE_READER_FIRST_VIDEO_STREAM.rawValue) == 0xfffffffc else {
      throw WindowsError.unsupported("Native media stream index ABI failed.")
    }
    Console.writeLine("Content fixtures: create temporary directory")
    var temporary = [WCHAR](repeating: 0, count: 32768), guid = GUID()
    let count = GetTempPathW(DWORD(temporary.count), &temporary)
    guard count > 0, count < temporary.count, CoCreateGuid(&guid) >= 0 else {
      throw WindowsError.unsupported("Cannot create native content fixtures.")
    }
    var identity = [WCHAR](repeating: 0, count: 40)
    guard StringFromGUID2(&guid, &identity, Int32(identity.count)) > 0 else {
      throw WindowsError.unsupported("Cannot name native content fixtures.")
    }
    let name = String(decoding: identity.prefix(while: { $0 != 0 }), as: UTF16.self)
      .filter { $0.isHexDigit || $0 == "-" }
    let folder = String(decoding: temporary.prefix(Int(count)), as: UTF16.self)
      + "SwiftyToys-content-" + name
    try NativeFiles.createDirectory(folder)
    let textPath = folder + "\\fixture.txt", audioPath = folder + "\\fixture.wav"
    let imagePath = folder + "\\fixture.bmp", pdfPath = folder + "\\fixture.pdf"
    let videoPath = folder + "\\fixture.avi"
    defer {
      for path in [textPath, audioPath, imagePath, pdfPath, videoPath] { try? NativeFiles.remove(path) }
      _ = withWideString(folder) { RemoveDirectoryW($0) }
    }
    Console.writeLine("Content fixtures: write UTF-16")
    try NativeFiles.write([255, 254] + "fixture lunar orchard\nnext line".utf16.flatMap {
      [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
    }, to: textPath)
    Console.writeLine("Content fixtures: write PCM")
    try NativeFiles.write(wave(), to: audioPath)
    Console.writeLine("Content fixtures: write bitmap")
    try NativeFiles.write(bitmap(), to: imagePath)
    Console.writeLine("Content fixtures: write PDF")
    try NativeFiles.write(pdf(), to: pdfPath)
    try NativeFiles.write(video(), to: videoPath)
    var text: [SearchContentFragment] = []
    Console.writeLine("Content fixtures: extract UTF-16")
    let textReport = try NativeSearchContent.extract(path: textPath, deadline: GetTickCount64() + 5000,
      cancelled: { false }, emit: { text.append($0) })
    guard !textReport.truncated, text.count == 1,
      text[0].text.containsText("fixture lunar orchard"), text[0].line == 1 else {
      throw WindowsError.unsupported("Native UTF-16 content fixture failed.")
    }
    guard NativeSearchMedia.orientationTransform(6) == WICBitmapTransformRotate90,
      NativeSearchMedia.orientationTransform(8) == WICBitmapTransformRotate270,
      NativeSearchMedia.orientationTransform(2) == WICBitmapTransformFlipHorizontal else {
      throw WindowsError.unsupported("Native EXIF orientation mapping failed.")
    }
    var images: [SearchContentFragment] = []
    Console.writeLine("Content fixtures: extract bitmap/OCR")
    _ = try NativeSearchContent.extract(path: imagePath, deadline: GetTickCount64() + 15000,
      cancelled: { false }, emit: { images.append($0) })
    guard images.count == 1, let image = images[0].image,
      image.width == 64, image.height == 64, image.bgra.count == 16384,
      image.bgra[0] == 0, image.bgra[2] == 255 else {
      throw WindowsError.unsupported("Native WIC image fixture failed.")
    }
    var audio: [SearchContentFragment] = []
    Console.writeLine("Content fixtures: decode PCM")
    let audioReport = try NativeSearchContent.extract(path: audioPath,
      deadline: GetTickCount64() + 15000, cancelled: { false }, emit: { audio.append($0) })
    guard audio.count == 1, let samples = audio[0].audio, samples.count == 16000,
      abs(samples[4] - 0.9155) < 0.002, !audioReport.truncated,
      audio[0].durationMilliseconds == 1000, audioReport.continuationMilliseconds == nil else {
      throw WindowsError.unsupported("Native Media Foundation PCM fixture failed.")
    }
    Console.writeLine("Content fixtures: decode synthetic video")
    var frames: [SearchContentFragment] = []
    _ = try NativeSearchContent.extract(path: videoPath, deadline: GetTickCount64() + 15000,
      cancelled: { false }, emit: { if $0.kind == "video" { frames.append($0) } })
    guard frames.count == 1, frames[0].milliseconds == 0, let frame = frames[0].image,
      frame.width == 64, frame.height == 64, frame.bgra[2] == 255,
      frame.bgra[(63 * 64) * 4] == 255 else {
      throw WindowsError.unsupported("Native Media Foundation timestamped video fixture failed.")
    }
    var pages: [SearchContentFragment] = []
    Console.writeLine("Content fixtures: render PDF/OCR")
    let pdfReport = try NativeSearchContent.extract(path: pdfPath, deadline: GetTickCount64() + 15000,
      cancelled: { false }, emit: { pages.append($0) })
    guard pages.count == 1, pages[0].page == 1, pages[0].image != nil, !pdfReport.truncated else {
      throw WindowsError.unsupported("Native PDF page/render fixture failed.")
    }
    if !pdfReport.status.containsText("OCR unavailable") {
      guard pages[0].text.lowercased().containsText("lunar orchard") else {
        throw WindowsError.unsupported("Native PDF OCR fixture failed.")
      }
    }
    Console.writeLine("PASS: synthetic UTF-16, oriented WIC bitmap, Media Foundation PCM/video, PDF page and OCR fixtures")
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for offset in stride(from: 0, to: T.bitWidth, by: 8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> offset))
    }
  }

  private static func wave() -> [UInt8] {
    var bytes = Array("RIFF".utf8)
    append(UInt32(32036), to: &bytes); bytes += Array("WAVEfmt ".utf8)
    append(UInt32(16), to: &bytes); append(UInt16(1), to: &bytes)
    append(UInt16(1), to: &bytes); append(UInt32(16000), to: &bytes)
    append(UInt32(32000), to: &bytes); append(UInt16(2), to: &bytes)
    append(UInt16(16), to: &bytes); bytes += Array("data".utf8)
    append(UInt32(32000), to: &bytes)
    for index in 0..<16000 {
      let sample = Int16(sin(2 * Double.pi * 1000 * Double(index) / 16000) * 30000)
      append(UInt16(bitPattern: sample), to: &bytes)
    }
    return bytes
  }

  private static func bitmap() -> [UInt8] {
    var bytes: [UInt8] = [66, 77]
    append(UInt32(54 + 64 * 64 * 4), to: &bytes); append(UInt32(0), to: &bytes)
    append(UInt32(54), to: &bytes); append(UInt32(40), to: &bytes)
    append(Int32(64), to: &bytes); append(Int32(-64), to: &bytes)
    append(UInt16(1), to: &bytes); append(UInt16(32), to: &bytes)
    append(UInt32(0), to: &bytes); append(UInt32(64 * 64 * 4), to: &bytes)
    for _ in 0..<4 { append(UInt32(0), to: &bytes) }
    for _ in 0..<(64 * 64) { bytes += [0, 0, 255, 255] }
    return bytes
  }

  private static func video() -> [UInt8] {
    func chunk(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
      var result = Array(name.utf8)
      append(UInt32(bytes.count), to: &result)
      result += bytes
      if bytes.count % 2 != 0 { result.append(0) }
      return result
    }
    var header: [UInt8] = []
    for value: UInt32 in [1_000_000, 16384, 0, 16, 1, 0, 1, 16384, 64, 64, 0, 0, 0, 0] {
      append(value, to: &header)
    }
    var stream = Array("vidsDIB ".utf8)
    append(UInt32(0), to: &stream); append(UInt16(0), to: &stream)
    append(UInt16(0), to: &stream)
    for value: UInt32 in [0, 1, 1, 0, 1, 16384, 0xffffffff, 0] { append(value, to: &stream) }
    for value: Int16 in [0, 0, 64, 64] { append(value, to: &stream) }
    var format: [UInt8] = []
    append(UInt32(40), to: &format); append(Int32(64), to: &format)
    append(Int32(64), to: &format); append(UInt16(1), to: &format)
    append(UInt16(32), to: &format)
    for value: UInt32 in [0, 16384, 0, 0, 0, 0] { append(value, to: &format) }
    let streams = chunk("LIST", Array("strl".utf8) + chunk("strh", stream) + chunk("strf", format))
    let headers = chunk("LIST", Array("hdrl".utf8) + chunk("avih", header) + streams)
    var pixels: [UInt8] = []
    // DIB rows are bottom-up: blue below red makes the native stride/orientation check meaningful.
    for row in 0..<64 {
      for _ in 0..<64 { pixels += row < 32 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
    }
    let movie = chunk("LIST", Array("movi".utf8) + chunk("00db", pixels))
    var index = Array("00db".utf8)
    for value: UInt32 in [16, 4, 16384] { append(value, to: &index) }
    return chunk("RIFF", Array("AVI ".utf8) + headers + movie + chunk("idx1", index))
  }

  private static func pdf() -> [UInt8] {
    let content = "BT /F1 24 Tf 24 80 Td (fixture lunar orchard) Tj ET\n"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 150] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length \(content.utf8.count) >>\nstream\n" + content + "endstream",
    ]
    var bytes = Array("%PDF-1.4\n".utf8), offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(bytes.count)
      bytes += Array("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
    }
    let xref = bytes.count
    bytes += Array("xref\n0 6\n0000000000 65535 f \n".utf8)
    for offset in offsets {
      let number = String(offset)
      bytes += Array((String(repeating: "0", count: 10 - number.count) + number + " 00000 n \n").utf8)
    }
    bytes += Array("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
    return bytes
  }
}
