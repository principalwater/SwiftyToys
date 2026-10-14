// SPDX-License-Identifier: MIT
import WinSDK

enum NativeEmbeddingMediaSelfTest {
  /// Explicit developer fixture: all files remain in a private caller-provided asset directory.
  static func run(assetDirectory: String) throws {
    var observed = GetTickCount64()
    func snapshot(_ stage: String) throws {
      var counters = PROCESS_MEMORY_COUNTERS_EX()
      counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
      let success = withUnsafeMutablePointer(to: &counters) {
        $0.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) {
          K32GetProcessMemoryInfo(GetCurrentProcess(), $0,
            DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size))
        }
      }
      guard success else { throw WindowsError.api("Read media fixture memory counters", GetLastError()) }
      let now = GetTickCount64()
      Console.writeLine("Media fixture \(stage): \(now - observed) ms; private=\(counters.PrivateUsage) B, peak commit=\(counters.PeakPagefileUsage) B, resident=\(counters.WorkingSetSize) B")
      observed = now
    }
    try snapshot("start")
    try NativeEmbeddingMediaEngine.selfCheck()
    try snapshot("preprocessing")
    let engine = try NativeEmbeddingEngine(assetDirectory: assetDirectory)
    try engine.validateInference()
    try snapshot("text model validation")
    let media = try NativeEmbeddingMediaEngine(engine: engine, assetDirectory: assetDirectory)
    func solid(red: UInt8, green: UInt8, blue: UInt8) -> SearchContentImage {
      SearchContentImage(width: 48, height: 48,
        bgra: Array(repeating: [blue, green, red, 255], count: 48 * 48).flatMap { $0 })
    }
    func check(_ value: [Float]) throws {
      let norm = value.reduce(0.0) { $0 + Double($1) * Double($1) }
      guard value.count == 128, value.allSatisfy(\.isFinite), abs(norm - 1) < 0.0001 else {
        throw WindowsError.unsupported("Real media inference returned an invalid normalized vector.")
      }
    }
    func score(_ left: [Float], _ right: [Float]) -> Double {
      zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }
    Console.writeLine("Media inference fixtures: encode synthetic red image")
    let red = try media.vector(SearchContentFragment(kind: "image", image: solid(red: 255, green: 0, blue: 0)))
    try check(red)
    try snapshot("first image")
    Console.writeLine("Media inference fixtures: encode synthetic blue image")
    let blue = try media.vector(SearchContentFragment(kind: "image", image: solid(red: 0, green: 0, blue: 255)))
    try check(blue)
    try snapshot("second image")
    let green = try media.vector(SearchContentFragment(kind: "image", image: solid(red: 0, green: 255, blue: 0)))
    try check(green)
    try snapshot("third image")
    let video = try media.vector(SearchContentFragment(kind: "video", milliseconds: 0,
      image: solid(red: 255, green: 0, blue: 0)))
    try check(video)
    try snapshot("video features")
    let redQuery = try engine.vector(GemmaBPETokenizer.query("a red image"))
    let blueQuery = try engine.vector(GemmaBPETokenizer.query("a blue image"))
    let redMargin = score(redQuery, red) - score(redQuery, blue)
    let blueMargin = score(blueQuery, blue) - score(blueQuery, red)
    guard redMargin > 0.01, blueMargin > 0.01, score(red, blue) < 0.99,
      score(redQuery, video) > score(redQuery, blue) + 0.01 else {
      throw WindowsError.unsupported("Real image/text color retrieval fixture failed.")
    }
    try snapshot("color queries")
    Console.writeLine("Media inference fixtures: encode native synthetic 30-second 1 kHz audio")
    let tone = (0..<480000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
    let audio = try media.vector(SearchContentFragment(kind: "audio", milliseconds: 0,
      durationMilliseconds: 30000, audio: tone))
    try check(audio)
    try snapshot("full audio window")
    let toneQuery = try engine.vector(GemmaBPETokenizer.query("an electronic tone or beep sound"))
    let speechQuery = try engine.vector(GemmaBPETokenizer.query("people speaking about their taxes"))
    let toneMargin = score(toneQuery, audio) - score(speechQuery, audio)
    guard toneMargin > 0.01 else {
      throw WindowsError.unsupported("Real audio/text tone retrieval fixture failed.")
    }
    try snapshot("tone queries")
    Console.writeLine("PASS: pinned image/audio encoders, 128-dimensional vectors, image/text color and audio/text tone retrieval")
    Console.writeLine("Media fixture margins: red=\(redMargin), blue=\(blueMargin), tone=\(toneMargin)")
  }
}
