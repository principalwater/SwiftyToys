// SPDX-License-Identifier: MIT

// Copyright (c) 2026 principalwater

/// A validated brightness percentage, independent of the selected display backend.
public struct BrightnessLevel: Sendable, Equatable, Codable {
    public let percent: Int

    /// Validates an absolute percentage supplied by a user or saved configuration.
    public init(_ percent: Int) throws(BrightnessError) {
        guard (0...100).contains(percent) else { throw .invalidPercentage(percent) }
        self.percent = percent
    }
    /// Maps a percentage to the native hardware range without overflowing UInt32.
    public func hardwareValue(in range: ClosedRange<UInt32>) -> UInt32 {
        range.lowerBound + UInt32((UInt64(range.upperBound - range.lowerBound) * UInt64(percent) + 50) / 100)
    }

    /// Clamps a relative change at the endpoints of the supported range.
    public func adjusted(by delta: Int) -> Self {
        // Avoid integer overflow even for an untrusted CLI delta.
        let bounded = max(-100, min(100, delta))
        return Self(unchecked: max(0, min(100, percent + bounded)))
    }

    private init(unchecked percent: Int) { self.percent = percent }

    /// Rejects invalid saved values rather than bypassing the validated initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard (0...100).contains(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Brightness must be 0...100.")
        }
        percent = value
    }

    /// Encodes the percentage as an integer for portable recovery state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percent)
    }
}
/// Validation and display-selection failures that do not depend on an OS API.
public enum BrightnessError: Error, Sendable, Equatable {
    case invalidPercentage(Int)
    case invalidGammaCount(Int)
    case ambiguousDisplay
    case displayDisconnected(String)
}
/// Original per-channel calibration stored in fixed, contiguous Swift memory.
public struct GammaRamp: Sendable {
    private var samples: InlineArray<768, UInt16>

    /// Creates the identity ramp for a 256-entry red, green and blue lookup table.
    public init() { samples = InlineArray { UInt16(($0 % 256) * 257) } }

    /// Copies an existing native ramp without replacing its color calibration.
    public init(samples: [UInt16]) throws(BrightnessError) {
        guard samples.count == 768 else { throw .invalidGammaCount(samples.count) }
        self.samples = InlineArray { samples[$0] }
    }

    /// Applies gain to the original ramp rather than an already dimmed ramp.
    public func scaled(to level: BrightnessLevel) -> Self {
        var result = self
        for index in samples.indices {
            let value = UInt32(samples[index]) * UInt32(level.percent)
            result.samples[index] = UInt16((value + 50) / 100)
        }
        return result
    }

    /// Reads one channel sample with the fixed array's bounds checks.
    public subscript(index: Int) -> UInt16 { samples[index] }

    /// Copies the samples for durable recovery state or diagnostics.
    public var array: [UInt16] { samples.indices.map { samples[$0] } }

    /// Provides a native API with a pointer valid only for the closure's duration.
    public func withUnsafeBufferPointer<Result, Failure: Error>(
        _ body: (UnsafeBufferPointer<UInt16>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try samples.span.withUnsafeBufferPointer(body)
    }
}
/// AMD output control values that preserve the original RGB calibration at 100%.
public struct AMDColorGain: Sendable, Equatable, Codable {
    public let brightness: Int32
    public let contrast: Int32

    /// Records original native controls or values read back from the driver.
    public init(brightness: Int32, contrast: Int32) {
        self.brightness = brightness
        self.contrast = contrast
    }

    /// Converts gain into compensated brightness/contrast without an added offset.
    public func scaled(to level: BrightnessLevel) -> Self {
        let gain = Double(level.percent) / 100
        return Self(
            brightness: Int32(((50 + Double(brightness)) * gain - 50).rounded(.toNearestOrEven)),
            contrast: Int32((Double(contrast) * gain).rounded(.toNearestOrEven)))
    }
}
