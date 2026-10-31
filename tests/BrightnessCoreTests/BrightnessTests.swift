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

    @Test func manualModeConfirmsOnlyTheExactBrightness() {
        let range: ClosedRange<UInt32> = 0...65535
        #expect(brightnessWriteConfirmed(reading: 39321, written: 39321, in: range, sensorActive: false))
        #expect(!brightnessWriteConfirmed(reading: 39320, written: 39321, in: range, sensorActive: false))
    }

    @Test func sensorDriftWithinOnePercentConfirmsTheWrite() {
        let range: ClosedRange<UInt32> = 0...65535
        for reading: UInt32 in [39321, 39320, 39311, 39321 - 655, 39321 + 655] {
            #expect(brightnessWriteConfirmed(reading: reading, written: 39321, in: range, sensorActive: true))
        }
        // A monitor that kept its previous level did not take the write.
        #expect(!brightnessWriteConfirmed(reading: 38235, written: 39321, in: range, sensorActive: true))
        #expect(!brightnessWriteConfirmed(reading: 39321 + 656, written: 39321, in: range, sensorActive: true))
    }

    @Test func sensorReadingOutsideTheRangeIsRejectedWithoutOverflow() {
        #expect(!brightnessWriteConfirmed(reading: 99, written: 100, in: 100...200, sensorActive: true))
        #expect(brightnessWriteConfirmed(reading: 200, written: 199, in: 100...200, sensorActive: true))
        #expect(brightnessWriteConfirmed(reading: .max, written: .max - 1, in: 0...UInt32.max, sensorActive: true))
    }

    /// An anonymized base EDID block that differs only in its unit-identifying bytes.
    private func edid(serial: [UInt8] = [0, 0, 0, 0], textSerialDescriptor: Int? = nil) -> [UInt8] {
        var block = Array(repeating: UInt8(0x20), count: 128)
        block.replaceSubrange(12..<16, with: serial)
        if let start = textSerialDescriptor { block.replaceSubrange(start..<start + 4, with: [0, 0, 0, 0xFF]) }
        return block
    }

    @Test func followsTheSameMonitorToAnotherPort() throws {
        let moved = DisplayCandidate(id: "new-port", isPhysical: true)
        let other = DisplayCandidate(id: "other-monitor", isPhysical: true)
        for unit in [edid(serial: [0, 0, 0, 7]), edid(textSerialDescriptor: 54), edid(textSerialDescriptor: 108)] {
            let stored = ["saved": unit, "new-port": unit, "other-monitor": edid(serial: [0, 0, 0, 9])]
            #expect(try selectDisplay(from: [other, moved], savedID: "saved", storedEDID: { stored[$0] }) == moved)
        }
    }

    @Test func neverSubstitutesAnotherUnitOfTheSameModel() {
        let twin = DisplayCandidate(id: "twin", isPhysical: true)
        let stored = ["saved": edid(serial: [0, 0, 0, 7]), "twin": edid(serial: [0, 0, 0, 8])]
        #expect(throws: BrightnessError.displayDisconnected("saved")) {
            try selectDisplay(from: [twin], savedID: "saved", storedEDID: { stored[$0] })
        }
    }

    @Test func staysDisconnectedWithoutProofOfTheSameUnit() {
        let candidate = DisplayCandidate(id: "candidate", isPhysical: true)
        let short = Array(edid(serial: [0, 0, 0, 7]).prefix(127))
        let unproven: [[UInt8]?] = [nil, [], edid(), edid(serial: [1, 1, 1, 1]), short]
        for unit in unproven {
            #expect(throws: BrightnessError.displayDisconnected("saved")) {
                try selectDisplay(from: [candidate], savedID: "saved", storedEDID: { _ in unit })
            }
        }
        // No stored EDID for the candidate itself: the saved unit alone proves nothing.
        let serial = edid(serial: [0, 0, 0, 7])
        #expect(throws: BrightnessError.displayDisconnected("saved")) {
            try selectDisplay(from: [candidate], savedID: "saved", storedEDID: { $0 == "saved" ? serial : nil })
        }
    }

    @Test func staysDisconnectedWhenSeveralCandidatesMatch() {
        let first = DisplayCandidate(id: "first", isPhysical: true)
        let second = DisplayCandidate(id: "second", isPhysical: true)
        let unit = edid(serial: [0, 0, 0, 7])
        #expect(throws: BrightnessError.displayDisconnected("saved")) {
            try selectDisplay(from: [first, second], savedID: "saved", storedEDID: { _ in unit })
        }
    }

    @Test func keepsASavedMonitorThatBecameClonedOrHDR() {
        let twin = DisplayCandidate(id: "twin", isPhysical: true)
        let unit = edid(serial: [0, 0, 0, 7])
        let cloned = DisplayCandidate(id: "saved", isPhysical: true, isCloned: true)
        let hdr = DisplayCandidate(id: "saved", isPhysical: true, isHDR: true)
        for saved in [cloned, hdr] {
            #expect(throws: BrightnessError.displayDisconnected("saved")) {
                try selectDisplay(from: [saved, twin], savedID: "saved", storedEDID: { _ in unit })
            }
        }
    }

    @Test func connectedTargetNeedsNoEDIDLookup() throws {
        let saved = DisplayCandidate(id: "saved", isPhysical: true)
        #expect(try selectDisplay(from: [saved], savedID: "saved", storedEDID: { _ in
            Issue.record("A connected target must not read stored EDID data.")
            return nil
        }) == saved)
    }

    @Test func findsTheMonitorInstanceInADisplayID() {
        let id = "\\\\?\\DISPLAY#AAA0000#1&2&0&UID3#{class}|4"
        #expect(monitorInstanceID(displayID: id) == "DISPLAY\\AAA0000\\1&2&0&UID3")
        let invalid = [
            "", "saved", "\\\\?\\USB#AAA0000#1&2&0&UID3#{class}|4", "\\\\?\\DISPLAY#AAA0000#{class}|4",
            "\\\\?\\DISPLAY##1&2#{class}|4",
        ]
        for id in invalid { #expect(monitorInstanceID(displayID: id) == nil) }
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
