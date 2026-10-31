// SPDX-License-Identifier: MIT

/// A native display identity and the capabilities needed for safe selection.
public struct DisplayCandidate: Sendable, Equatable {
    public let id: String
    public let isPhysical: Bool
    public let isCloned: Bool
    public let isHDR: Bool

    /// Describes an enumerated target without carrying thread-affine native handles.
    public init(id: String, isPhysical: Bool, isCloned: Bool = false, isHDR: Bool = false) {
        self.id = id
        self.isPhysical = isPhysical
        self.isCloned = isCloned
        self.isHDR = isHDR
    }
}
/// Chooses only the saved target, or a unique physical SDR display on first start.
///
/// Windows renames a monitor's path when its cable moves to another port. A saved target that is
/// gone follows that move only when `storedEDID` shows that exactly one supported candidate is the
/// same physical unit, so another monitor, even of the same model, is never substituted.
///
/// - Parameter storedEDID: Returns the EDID Windows stored for a display id, if any.
/// - Throws: `displayDisconnected` when the saved target cannot be found or proven to have moved,
///   and `ambiguousDisplay` when no target is saved and the choice is not unique.
public func selectDisplay(
    from candidates: [DisplayCandidate], savedID: String?, storedEDID: (String) -> [UInt8]? = { _ in nil }
) throws(BrightnessError) -> DisplayCandidate {
    let supported = candidates.filter { $0.isPhysical && !$0.isCloned && !$0.isHDR }
    if let savedID, !savedID.isEmpty {
        if let target = supported.first(where: { $0.id == savedID }) { return target }
        // A saved monitor that is now cloned or HDR has not moved anywhere.
        guard !candidates.contains(where: { $0.id == savedID }),
            let unit = storedEDID(savedID).flatMap(monitorUnit)
        else { throw .displayDisconnected(savedID) }
        let moved = supported.filter { storedEDID($0.id).flatMap(monitorUnit) == unit }
        guard moved.count == 1 else { throw .displayDisconnected(savedID) }
        return moved[0]
    }
    guard supported.count == 1 else { throw .ambiguousDisplay }
    return supported[0]
}

/// The base EDID block, when it has a serial number that separates units of one model.
private func monitorUnit(edid: [UInt8]) -> [UInt8]? {
    guard edid.count >= 128 else { return nil }
    // shortcut: units that share one fake serial still look identical; Windows offers nothing finer.
    let numbered = ![[0, 0, 0, 0], [1, 1, 1, 1]].contains(Array(edid[12..<16]))
    // The four 18-byte display descriptors hold the serial as text under tag 0xFF.
    let named = stride(from: 54, to: 126, by: 18).contains { edid[$0..<$0 + 4].elementsEqual([0, 0, 0, 0xFF]) }
    return numbered || named ? Array(edid.prefix(128)) : nil
}

/// The Windows device instance in a display id: `\\?\DISPLAY#model#instance#{class}|connector`.
public func monitorInstanceID(displayID: String) -> String? {
    let parts = displayID.split(separator: "#", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0].lowercased() == "\\\\?\\display", !parts[1].isEmpty, !parts[2].isEmpty else {
        return nil
    }
    return "DISPLAY\\\(parts[1])\\\(parts[2])"
}
