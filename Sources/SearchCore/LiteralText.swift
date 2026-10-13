// SPDX-License-Identifier: MIT
import BrightnessCore

extension StringProtocol {
    func literalRange(_ pattern: String, within range: Range<Index>? = nil) -> Range<Index>? {
        guard !pattern.isEmpty else { return nil }
        let range = range ?? startIndex..<endIndex
        for index in self[range].indices where self[index..<range.upperBound].hasPrefix(pattern) {
            return index..<self.index(index, offsetBy: pattern.count)
        }
        return nil
    }
}
