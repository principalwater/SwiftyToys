// SPDX-License-Identifier: MIT

import Testing

@testable import BrightnessCore

struct BrightnessTests {
    @Test func mapsHardwareRangeWithoutOverflow() throws {
        for range: ClosedRange<UInt32> in [0...100, 30...150, 0...UInt32.max, 7...7] {
            #expect(try BrightnessLevel(0).hardwareValue(in: range) == range.lowerBound)
            #expect(try BrightnessLevel(100).hardwareValue(in: range) == range.upperBound)
            let middle = try BrightnessLevel(50).hardwareValue(in: range)
            #expect(range.contains(middle))
        }
        #expect(try BrightnessLevel(55).hardwareValue(in: 0...100) == 55)
        #expect(try BrightnessLevel(50).hardwareValue(in: 0...UInt32.max) == 2_147_483_648)
    }
    @Test(arguments: [0, 5, 25, 45, 60, 75, 100])
    func scalesEveryGammaChannelFromItsOriginalCalibration(_ percent: Int) throws {
        let level = try BrightnessLevel(percent)
        let original = try GammaRamp(samples: (0..<768).map { UInt16($0 * 73) })
        let scaled = original.scaled(to: level)
        for index in 0..<768 {
            let expected = (UInt32(index * 73) * UInt32(percent) + 50) / 100
            #expect(scaled[index] == UInt16(expected))
        }
        #expect(original[767] == UInt16(767 * 73))
    }

    @Test func clampsRelativeCommandsWithoutIntegerOverflow() throws {
        let level = try BrightnessLevel(45)
        #expect(level.adjusted(by: Int.max).percent == 100)
        #expect(level.adjusted(by: Int.min).percent == 0)
        #expect(level.adjusted(by: -5).percent == 40)
        #expect(level.adjusted(by: 5).percent == 50)
    }

    @Test func rejectsInvalidNativeBufferCounts() {
        #expect(throws: BrightnessError.invalidGammaCount(1)) { try GammaRamp(samples: [0]) }
        #expect(throws: BrightnessError.invalidPercentage(101)) { try BrightnessLevel(101) }
    }

    @Test func preservesCalibrationAndAMDQuantization() throws {
        let original = AMDColorGain(brightness: 17, contrast: 83)
        #expect(original.scaled(to: try BrightnessLevel(100)) == original)
        #expect(original.scaled(to: try BrightnessLevel(0)) == AMDColorGain(brightness: -50, contrast: 0))
        let neutral = AMDColorGain(brightness: 0, contrast: 100)
        #expect(neutral.scaled(to: try BrightnessLevel(45)) == AMDColorGain(brightness: -28, contrast: 45))
    }

    @Test func neverSubstitutesAnotherMonitorAfterDisconnection() {
        let physical = DisplayCandidate(id: "physical", isPhysical: true)
        #expect(throws: BrightnessError.displayDisconnected("saved")) {
            try selectDisplay(from: [physical], savedID: "saved")
        }
    }

    @Test func skipsVirtualHDRAndClonedTargets() throws {
        let physical = DisplayCandidate(id: "physical", isPhysical: true)
        let virtual = DisplayCandidate(id: "virtual", isPhysical: false)
        let hdr = DisplayCandidate(id: "hdr", isPhysical: true, isHDR: true)
        let clone = DisplayCandidate(id: "clone", isPhysical: true, isCloned: true)
        #expect(try selectDisplay(from: [physical, virtual, hdr, clone], savedID: nil) == physical)
        #expect(throws: BrightnessError.ambiguousDisplay) {
            try selectDisplay(from: [physical, DisplayCandidate(id: "another", isPhysical: true)], savedID: nil)
        }
    }
}
