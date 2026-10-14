// SPDX-License-Identifier: MIT
import SearchContentABI
import WinSDK

/// The inbox PDF renderer covers scans even when no vendor IFilter is installed.
enum NativeSearchPDF {
  private static func wait<T>(_ pointer: UnsafeMutablePointer<T>, deadline: UInt64,
    cancelled: () -> Bool) throws {
    let info = try NativeSearchMedia.query(pointer,
      id: "00000036-0000-0000-c000-000000000046", as: IAsyncInfo.self)
    while true {
      var status = AsyncStatus(rawValue: 0)
      try NativeSearchContent.check(info.raw.pointee.lpVtbl.pointee.get_Status(info.raw, &status),
        "Read PDF operation status")
      if status.rawValue == 1 { return }
      guard status.rawValue == 0, !cancelled(), GetTickCount64() < deadline else {
        _ = info.raw.pointee.lpVtbl.pointee.Cancel(info.raw)
        throw WindowsError.unsupported("PDF processing unavailable, cancelled or timed out.")
      }
      Sleep(10)
    }
  }

  private static func close<T>(_ pointer: UnsafeMutablePointer<T>) {
    if let reference = try? NativeSearchMedia.query(pointer,
      id: "30d5a829-7fa4-4026-83bb-d75bae4ea99e", as: __x_ABI_CWindows_CFoundation_CIClosable.self) {
      _ = reference.raw.pointee.lpVtbl.pointee.Close(reference.raw)
    }
  }

  static func extract(path: String, startPage: Int, deadline: UInt64, cancelled: () -> Bool,
    emit: (SearchContentFragment) throws -> Void) throws -> SearchContentReport {
    guard startPage > 0, startPage <= 5000 else { throw WindowsError.unsupported("Invalid PDF page cursor.") }
    var streamPointer: UnsafeMutablePointer<IStream>?
    try NativeSearchContent.check(withWideString(try NativeFiles.windowsPath(path)) {
      SHCreateStreamOnFileEx($0, DWORD(STGM_READ | STGM_SHARE_DENY_WRITE),
        DWORD(FILE_ATTRIBUTE_NORMAL), false, nil, &streamPointer)
    }, "Read local PDF stream")
    guard let streamPointer else { throw WindowsError.unsupported("PDF stream unavailable.") }
    let stream = SearchContentReference(streamPointer)
    var streamID = try NativeSearchMedia.guid("905a0fe1-bc53-11df-8c49-001e4fc686da")
    var randomPointer: UnsafeMutableRawPointer?
    try NativeSearchContent.check(CreateRandomAccessStreamOverStream(stream.raw, BSOS_DEFAULT,
      &streamID, &randomPointer), "Wrap PDF stream")
    guard let randomPointer else { throw WindowsError.unsupported("PDF stream wrapper unavailable.") }
    let random = SearchContentReference(randomPointer.assumingMemoryBound(
      to: __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStream.self))
    defer { close(random.raw) }
    let statics = try NativeSearchMedia.factory("Windows.Data.Pdf.PdfDocument",
      id: "433a0b5f-c007-4788-90f2-08143d922599", as: __x_ABI_CWindows_CData_CPdf_CIPdfDocumentStatics.self)
    var loadPointer: UnsafeMutablePointer<__FIAsyncOperation_1_Windows__CData__CPdf__CPdfDocument>?
    try NativeSearchContent.check(statics.raw.pointee.lpVtbl.pointee.LoadFromStreamAsync(statics.raw,
      random.raw, &loadPointer), "Load PDF with the Windows renderer")
    guard let loadPointer else { throw WindowsError.unsupported("PDF loader unavailable.") }
    let load = SearchContentReference(loadPointer)
    try wait(load.raw, deadline: deadline, cancelled: cancelled)
    var documentPointer: UnsafeMutablePointer<__x_ABI_CWindows_CData_CPdf_CIPdfDocument>?
    try NativeSearchContent.check(load.raw.pointee.lpVtbl.pointee.GetResults(load.raw,
      &documentPointer), "Read PDF document")
    guard let documentPointer else { throw WindowsError.unsupported("PDF document unavailable.") }
    let document = SearchContentReference(documentPointer)
    var count: UINT32 = 0
    try NativeSearchContent.check(document.raw.pointee.lpVtbl.pointee.get_PageCount(document.raw,
      &count), "Read PDF page count")
    let end = min(Int(count), min(5000, startPage + 3))
    guard startPage <= end else { return SearchContentReport(status: "No remaining PDF pages", truncated: false) }
    let renderer = try NativeSearchPDFRenderer()
    var ocrAvailable = true
    for number in startPage...end {
      try NativeSearchContent.checkDeadline(deadline, cancelled)
      var pagePointer: UnsafeMutablePointer<__x_ABI_CWindows_CData_CPdf_CIPdfPage>?
      try NativeSearchContent.check(document.raw.pointee.lpVtbl.pointee.GetPage(document.raw,
        UINT32(number - 1), &pagePointer), "Read PDF page")
      guard let pagePointer else { throw WindowsError.unsupported("PDF page unavailable.") }
      let page = SearchContentReference(pagePointer)
      defer { close(page.raw) }
      var size = __x_ABI_CWindows_CFoundation_CSize()
      try NativeSearchContent.check(page.raw.pointee.lpVtbl.pointee.get_Size(page.raw, &size),
        "Read PDF page dimensions")
      guard size.Width.isFinite, size.Height.isFinite, size.Width > 0, size.Height > 0,
        size.Width <= 100000, size.Height <= 100000 else {
        throw WindowsError.unsupported("Invalid PDF page dimensions.")
      }
      let image = try renderer.image(page: page.raw, size: size)
      var fragment = SearchContentFragment(kind: "document", page: number, image: image)
      do { fragment.text = try NativeSearchMedia.ocr(image, deadline: deadline, cancelled: cancelled) }
      catch { ocrAvailable = false }
      try NativeSearchContent.checkDeadline(deadline, cancelled)
      try emit(fragment)
    }
    return SearchContentReport(status: "PDF pages \(startPage)–\(end) of \(count)"
      + (ocrAvailable ? "; OCR" : "; OCR unavailable") + (end < count ? "; partial coverage" : ""),
      truncated: end < count, continuationPage: end < count && end < 5000 ? end + 1 : nil)
  }
}
