// SPDX-License-Identifier: MIT
/// Reverses a signed wheel delta without discarding high-resolution increments.
public func reversedWheelDeltas(_ raw: UInt16) -> [Int32] {
    let delta = -Int32(Int16(bitPattern: raw))
    // A positive 32768 cannot fit a native hook's signed high word; preserve it as two events.
    return delta == 32768 ? [16384, 16384] : [delta]
}
