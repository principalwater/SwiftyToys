// SPDX-License-Identifier: MIT
import BrightnessCore
import EmbeddingABI
import WinSDK

/// Native preprocessing for the pinned Apache-2.0 Gemma 4/EmbeddingGemma 2 processors.
/// Encoder sessions share the already verified Microsoft runtime; no additional DLL is loaded.
final class NativeEmbeddingMediaEngine {
  static let preprocessingID =
    "native-media-v3:image70-video70:rgb16-pool3-bicubic-byte-round:audio30s-htk128-hann320-hop160"
  static var fingerprint: String {
    preprocessingID + ":"
      + NativeEmbeddingAssets.mediaFiles.map(\.sha256).joined(separator: ":")
  }
  private let engine: NativeEmbeddingEngine
  private let root: String
  private var files: [NativeEmbeddingFile] = []
  private var vision: OpaquePointer?
  private var audio: OpaquePointer?

  init(engine: NativeEmbeddingEngine, assetDirectory: String? = nil) throws {
    guard engine.model.adapter == .gemmaBPE else {
      throw WindowsError.unsupported("The selected model does not support images or audio.")
    }
    self.engine = engine
    root = try assetDirectory ?? NativeEmbeddingAssets.directory(model: engine.model)
  }

  private func session(video: Bool) throws -> OpaquePointer {
    if let existing = video ? vision : audio { return existing }
    let names = video ? ["vision_encoder_quantized.onnx", "vision_encoder_quantized.onnx_data"]
      : ["audio_encoder_quantized.onnx", "audio_encoder_quantized.onnx_data"]
    var held: [NativeEmbeddingFile] = []
    for name in names {
      guard let asset = NativeEmbeddingAssets.mediaFiles.first(where: { $0.name == name }) else {
        throw WindowsError.unsupported("The media encoder manifest is incomplete.")
      }
      held.append(try NativeEmbeddingFile(root + "\\" + name, asset: asset))
    }
    var created: OpaquePointer?
    try withWideString(try NativeFiles.windowsPath(root + "\\" + names[0])) {
      try engine.check(engine.ortAPI.CreateSession(engine.ortEnvironment, $0,
        engine.ortOptions, &created))
    }
    guard let created else { throw WindowsError.unsupported("Media encoder session unavailable.") }
    files += held
    if video { vision = created } else { audio = created }
    return created
  }

  private func features(session: OpaquePointer, firstName: String, first: [Float],
    firstShape: [Int64], secondName: String, second: UnsafeMutableRawPointer,
    secondBytes: Int, secondShape: [Int64], secondType: ONNXTensorElementDataType,
    outputName: String) throws -> [Float] {
    guard !first.isEmpty, first.allSatisfy(\.isFinite) else {
      throw WindowsError.unsupported("Invalid media encoder input.")
    }
    let api = engine.ortAPI
    var firstValue: OpaquePointer?, secondValue: OpaquePointer?, output: OpaquePointer?
    let copied = UnsafeMutablePointer<Float>.allocate(capacity: first.count)
    copied.initialize(from: first, count: first.count)
    defer { copied.deinitialize(count: first.count); copied.deallocate() }
    defer {
      for value in [firstValue, secondValue, output] { if let value { api.ReleaseValue(value) } }
    }
    try firstShape.withUnsafeBufferPointer {
      try engine.check(api.CreateTensorWithDataAsOrtValue(engine.ortMemory, copied,
        first.count * 4, $0.baseAddress, $0.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &firstValue))
    }
    try secondShape.withUnsafeBufferPointer {
      try engine.check(api.CreateTensorWithDataAsOrtValue(engine.ortMemory, second, secondBytes,
        $0.baseAddress, $0.count, secondType, &secondValue))
    }
    try firstName.withCString { firstName in
      try secondName.withCString { secondName in
        try outputName.withCString { outputName in
          var outputName: UnsafePointer<CChar>? = outputName
          let names: [UnsafePointer<CChar>?] = [firstName, secondName]
          let values = [firstValue, secondValue]
          try names.withUnsafeBufferPointer { names in
            try values.withUnsafeBufferPointer { values in
              try engine.check(api.Run(session, nil, names.baseAddress, values.baseAddress,
                2, &outputName, 1, &output))
            }
          }
        }
      }
    }
    var information: OpaquePointer?
    try engine.check(api.GetTensorTypeAndShape(output, &information))
    defer { if let information { api.ReleaseTensorTypeAndShapeInfo(information) } }
    var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED, rank = 0, count = 0
    try engine.check(api.GetTensorElementType(information, &type))
    try engine.check(api.GetDimensionsCount(information, &rank))
    try engine.check(api.GetTensorShapeElementCount(information, &count))
    guard type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, rank == 2,
      count > 0, count <= 750 * 512, count % 512 == 0 else {
      throw WindowsError.unsupported("Unexpected media encoder output shape.")
    }
    var shape: [Int64] = [0, 0]
    try shape.withUnsafeMutableBufferPointer {
      try engine.check(api.GetDimensions(information, $0.baseAddress, 2))
    }
    guard shape == [Int64(count / 512), 512] else {
      throw WindowsError.unsupported("Unexpected media encoder feature dimensions.")
    }
    var pointer: UnsafeMutableRawPointer?
    try engine.check(api.GetTensorMutableData(output, &pointer))
    guard let pointer else { throw WindowsError.unsupported("Media encoder returned no features.") }
    let features = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self),
      count: count))
    guard features.allSatisfy(\.isFinite) else {
      throw WindowsError.unsupported("Invalid media encoder features.")
    }
    return features
  }

  func vector(_ fragment: SearchContentFragment) throws -> [Float] {
    if let image = fragment.image {
      let video = fragment.kind == "video"
      let input = try Self.imageInput(image, maximumSoftTokens: 70)
      let encoded = try input.positions.withUnsafeBufferPointer { positions in
        try features(session: session(video: true), firstName: "pixel_values", first: input.pixels,
          firstShape: [1, Int64(input.maximumPatches), 768], secondName: "pixel_position_ids",
          second: UnsafeMutableRawPointer(mutating: positions.baseAddress!),
          secondBytes: positions.count * 8, secondShape: [1, Int64(input.maximumPatches), 2],
          secondType: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, outputName: "image_features")
      }
      guard encoded.count == input.softTokens * 512 else {
        throw WindowsError.unsupported("Image encoder token count does not match its pixels.")
      }
      let content = "<|image>" + String(repeating: video ? "<|video|>" : "<|image|>",
        count: input.softTokens) + "<image|>"
      let text = GemmaBPETokenizer.document(title: "", content: content)
      return video ? try engine.vector(text, videoFeatures: encoded)
        : try engine.vector(text, imageFeatures: encoded)
    }
    if let samples = fragment.audio {
      let input = try Self.audioInput(samples)
      let encoded = try input.mask.withUnsafeBufferPointer { mask in
        try features(session: session(video: false), firstName: "input_features", first: input.values,
          firstShape: [1, Int64(input.mask.count), 128], secondName: "input_features_mask",
          second: UnsafeMutableRawPointer(mutating: mask.baseAddress!), secondBytes: mask.count,
          secondShape: [1, Int64(mask.count)], secondType: ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL,
          outputName: "audio_features")
      }
      let tokens = encoded.count / 512
      guard tokens == input.softTokens else {
        throw WindowsError.unsupported("Audio encoder token count does not match its sample mask.")
      }
      let content = "<|audio>" + String(repeating: "<|audio|>", count: tokens) + "<audio|>"
      return try engine.vector(GemmaBPETokenizer.document(title: "", content: content),
        audioFeatures: encoded)
    }
    throw WindowsError.unsupported("The content fragment contains no media samples.")
  }

  struct ImageInput {
    let pixels: [Float]
    let positions: [Int64]
    let maximumPatches: Int
    let softTokens: Int
  }

  static func imageInput(_ image: SearchContentImage, maximumSoftTokens: Int = 70) throws -> ImageInput {
    guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
      image.width * image.height <= 4_194_304,
      image.bgra.count == image.width * image.height * 4,
      maximumSoftTokens == 70 || maximumSoftTokens == 140 || maximumSoftTokens == 280 else {
      throw WindowsError.unsupported("Image exceeds the semantic pixel budget.")
    }
    let maximumPatches = maximumSoftTokens * 9
    let factor = (Double(maximumPatches * 256) / Double(image.width * image.height)).squareRoot()
    var width = Int((Double(image.width) * factor / 48).rounded(.down)) * 48
    var height = Int((Double(image.height) * factor / 48).rounded(.down)) * 48
    if width == 0 { width = 48; height = min((image.height / image.width) * 48, maximumSoftTokens * 48) }
    if height == 0 { height = 48; width = min((image.width / image.height) * 48, maximumSoftTokens * 48) }
    guard width > 0, height > 0, width * height <= maximumPatches * 256 else {
      throw WindowsError.unsupported("Image aspect ratio cannot fit the semantic patch budget.")
    }
    let resized = resize(image, width: width, height: height)
    let patchWidth = width / 16, patchHeight = height / 16, actual = patchWidth * patchHeight
    var pixels = [Float](repeating: 0, count: maximumPatches * 768)
    var positions = [Int64](repeating: -1, count: maximumPatches * 2)
    for py in 0..<patchHeight {
      for px in 0..<patchWidth {
        let patch = py * patchWidth + px
        positions[patch * 2] = Int64(px); positions[patch * 2 + 1] = Int64(py)
        for y in 0..<16 {
          let source = ((py * 16 + y) * width + px * 16) * 3
          let target = patch * 768 + y * 48
          pixels.replaceSubrange(target..<(target + 48), with: resized[source..<(source + 48)])
        }
      }
    }
    return ImageInput(pixels: pixels, positions: positions,
      maximumPatches: maximumPatches, softTokens: actual / 9)
  }

  private static func resize(_ image: SearchContentImage, width: Int, height: Int) -> [Float] {
    func weights(source: Int, target: Int) -> [[(Int, Double)]] {
      let scale = Double(source) / Double(target), antialias = max(1, scale)
      func cubic(_ value: Double) -> Double {
        let x = abs(value)
        if x < 1 { return (1.5 * x - 2.5) * x * x + 1 }
        if x < 2 { return ((-0.5 * x + 2.5) * x - 4) * x + 2 }
        return 0
      }
      return (0..<target).map { index in
        let center = (Double(index) + 0.5) * scale - 0.5
        let first = max(0, Int(ceil(center - 2 * antialias)))
        let last = min(source - 1, Int(floor(center + 2 * antialias)))
        var values = (first...last).map { ($0, cubic((Double($0) - center) / antialias)) }
        let sum = values.reduce(0.0) { $0 + $1.1 }
        for i in values.indices { values[i].1 /= sum }
        return values
      }
    }
    let horizontal = weights(source: image.width, target: width)
    let vertical = weights(source: image.height, target: height)
    var rows = [Float](repeating: 0, count: image.height * width * 3)
    for y in 0..<image.height {
      for x in 0..<width {
        for channel in 0..<3 {
          let value = horizontal[x].reduce(0.0) {
            $0 + Double(image.bgra[(y * image.width + $1.0) * 4 + 2 - channel]) * $1.1
          }
          rows[(y * width + x) * 3 + channel] = Float(min(255, max(0, value)).rounded(.toNearestOrAwayFromZero))
        }
      }
    }
    var result = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 {
          let value = vertical[y].reduce(0.0) {
            $0 + Double(rows[($1.0 * width + x) * 3 + channel]) * $1.1
          }
          result[(y * width + x) * 3 + channel] = Float(min(255, max(0, value)).rounded(.toNearestOrAwayFromZero) / 255)
        }
      }
    }
    return result
  }

  struct AudioInput {
    let values: [Float]
    let mask: [UInt8]
    let softTokens: Int
  }

  private static let hann: [Float] = (0..<320).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 320)) }
  private static let twiddles: [(Double, Double)] = (0..<256).map {
    (cos(-2 * Double.pi * Double($0) / 512), sin(-2 * Double.pi * Double($0) / 512))
  }
  private static let mel: [[(Int, Double)]] = {
    let top = 2595 * log10(1 + 8000.0 / 700)
    let edges = (0..<130).map { 700 * (pow(10, Double($0) * top / 129 / 2595) - 1) }
    return (0..<128).map { filter in
      (0..<257).compactMap { bin in
        let frequency = Double(bin) * 16000 / 512
        let rising = (frequency - edges[filter]) / (edges[filter + 1] - edges[filter])
        let falling = (edges[filter + 2] - frequency) / (edges[filter + 2] - edges[filter + 1])
        let weight = max(0, min(rising, falling))
        return weight > 0 ? (bin, weight) : nil
      }
    }
  }()

  static func audioInput(_ samples: [Float]) throws -> AudioInput {
    guard samples.count >= 320, samples.count <= 480000,
      samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
      throw WindowsError.unsupported("Audio exceeds the mono 16 kHz sample budget.")
    }
    let padded = ((samples.count + 127) / 128) * 128
    let frames = (padded + 160 - 321) / 160 + 1
    var mask = [UInt8](repeating: 0, count: frames)
    var values = [Float](repeating: 0, count: frames * 128)
    for frame in 0..<frames {
      let end = frame * 160 + 160
      guard end < samples.count else { continue }
      mask[frame] = 1
      var real = [Double](repeating: 0, count: 512)
      var imaginary = real
      for n in 0..<320 {
        let sample = frame * 160 + n - 160
        if sample >= 0, sample < samples.count { real[n] = Double(samples[sample] * hann[n]) }
      }
      var j = 0
      for i in 1..<512 {
        var bit = 256
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j { real.swapAt(i, j) }
      }
      var length = 2
      while length <= 512 {
        let half = length / 2, step = 512 / length
        for base in stride(from: 0, to: 512, by: length) {
          for k in 0..<half {
            let (wr, wi) = twiddles[k * step]
            let a = base + k, b = a + half
            let tr = wr * real[b] - wi * imaginary[b]
            let ti = wr * imaginary[b] + wi * real[b]
            real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti
            real[a] += tr; imaginary[a] += ti
          }
        }
        length *= 2
      }
      let magnitude = (0..<257).map { (real[$0] * real[$0] + imaginary[$0] * imaginary[$0]).squareRoot() }
      for filter in 0..<128 {
        let energy = mel[filter].reduce(0.0) { $0 + magnitude[$1.0] * $1.1 }
        values[frame * 128 + filter] = Float(log(energy + 0.001))
      }
    }
    var reduced = mask
    for _ in 0..<2 { reduced = stride(from: 0, to: reduced.count, by: 2).map { reduced[$0] } }
    return AudioInput(values: values, mask: mask, softTokens: reduced.reduce(0) { $0 + Int($1) })
  }

  // Selected Pillow 12.3 reference bytes with the upstream Gemma4 PIL processor
  // at Transformers 28034545c35acac05793695bd5c878f66e6b544e. One-byte tolerance
  // accommodates Pillow's coefficient quantization; this does not assert bit parity.
  private static func imageReferenceCheck(width: Int, height: Int, checker: Bool,
    patches: Int, lastX: Int64, lastY: Int64, expected: [(Int, Float)]) throws {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        if checker {
          let bit = ((x / 3 + y / 5) % 2) * 255
          pixels[offset] = UInt8(255 - bit)
          pixels[offset + 1] = UInt8(bit)
          pixels[offset + 2] = UInt8(bit)
        } else {
          pixels[offset] = UInt8((x * 3 + y * 7) % 256)
          pixels[offset + 1] = UInt8(y * 255 / (height - 1))
          pixels[offset + 2] = UInt8(x * 255 / (width - 1))
        }
      }
    }
    let input = try imageInput(SearchContentImage(width: width, height: height, bgra: pixels))
    guard input.maximumPatches == 630, input.softTokens == patches / 9,
      input.positions[(patches - 1) * 2] == lastX,
      input.positions[(patches - 1) * 2 + 1] == lastY,
      input.positions[patches * 2] == -1, input.pixels[patches * 768] == 0 else {
      throw WindowsError.unsupported("Native non-square vision layout reference failed.")
    }
    for (index, byte) in expected {
      guard abs(input.pixels[index] - byte / 255) <= 1 / 255 + 0.000001 else {
        throw WindowsError.unsupported("Native gradient/checkerboard resize reference failed.")
      }
    }
  }

  static func selfCheck() throws {
    let silence = try audioInput([Float](repeating: 0, count: 16000))
    guard silence.mask.count == 99, silence.softTokens == 25,
      silence.values[0..<128].allSatisfy({ abs($0 - Float(log(0.001))) < 0.00001 }),
      silence.values.allSatisfy(\.isFinite) else {
      throw WindowsError.unsupported("Native audio preprocessing bounds failed.")
    }
    let tone = (0..<16000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
    let reference = try audioInput(tone)
    // NumPy RFFT + upstream HTK filter bank, periodic Hann and magnitude (not squared power).
    for (index, expected): (Int, Float) in [(1, 0.6574764), (12, -0.51153445),
      (40, 2.3111808), (168, 0.11781376), (4136, 0.11781376)] {
      guard abs(reference.values[index] - expected) < 0.0001 else {
        throw WindowsError.unsupported("Native audio FFT/mel golden reference failed.")
      }
    }
    let solid = SearchContentImage(width: 48, height: 48,
      bgra: Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 255), count: 48 * 48).flatMap { $0 })
    let image = try imageInput(solid)
    guard image.maximumPatches == 630, image.softTokens == 64,
      image.pixels[0] == 1, image.pixels[1] == 0, image.pixels[2] == 0,
      image.positions[0] == 0, image.positions[1] == 0,
      image.positions[1152] == -1, image.pixels[576 * 768] == 0 else {
      throw WindowsError.unsupported("Native vision preprocessing and patch padding failed.")
    }
    try imageReferenceCheck(width: 97, height: 61, checker: false, patches: 540,
      lastX: 29, lastY: 17, expected: [(0, 0), (1, 0), (2, 0), (719, 26),
        (766, 11), (767, 27), (13056, 145), (13438, 4), (413952, 248),
        (414334, 249), (414717, 255), (414718, 255), (414719, 197)])
    try imageReferenceCheck(width: 127, height: 95, checker: true, patches: 567,
      lastX: 26, lastY: 20, expected: [(0, 0), (1, 0), (2, 255), (31, 155),
        (719, 0), (766, 255), (767, 0), (13056, 0), (13438, 0), (217635, 255),
        (434688, 0), (435070, 0), (435453, 0), (435454, 0), (435455, 255)])
    Console.writeLine("PASS: native Gemma audio FFT/mel/mask and solid/gradient/checkerboard RGB preprocessing")
  }

  deinit {
    if let vision { engine.ortAPI.ReleaseSession(vision) }
    if let audio { engine.ortAPI.ReleaseSession(audio) }
  }
}
