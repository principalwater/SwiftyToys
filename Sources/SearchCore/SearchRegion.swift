// SPDX-License-Identifier: MIT

/// Supplied regional preferences, independent of the operating system or a country/currency map.
public struct SearchRegion: Sendable, Equatable {
  public let countryCode: String?
  public let currencyCode: String?
  public let currencySymbol: String
  public let decimalSeparator: String
  public let groupingSeparator: String
  /// Group widths from right to left; the final width repeats.
  public let groupingSizes: [Int]
  public let usesUSMeasurement: Bool?
  private let validNumberMetadata: Bool

  /// Preserves the original parser's unit defaults and comma-as-decimal input.
  public static let invariant = SearchRegion()

  /// Creates preferences from validated native metadata; invalid number metadata rejects parsing.
  public init(countryCode: String? = nil, currencyCode: String? = nil,
    currencySymbol: String = "", decimalSeparator: String = ".",
    groupingSeparator: String = "", groupingSizes: [Int] = [3],
    usesUSMeasurement: Bool? = nil) {
    func code(_ value: String?, length: Int) -> String? {
      guard let value, value.utf8.count == length,
        value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
      else { return nil }
      return value.uppercased()
    }
    self.countryCode = code(countryCode, length: 2)
    self.currencyCode = code(currencyCode, length: 3)
    self.currencySymbol = currencySymbol.utf8.count <= 32
      && !currencySymbol.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      ? currencySymbol : ""
    self.decimalSeparator = decimalSeparator
    self.groupingSeparator = groupingSeparator
    self.groupingSizes = groupingSizes
    self.usesUSMeasurement = usesUSMeasurement
    func separator(_ value: String, grouping: Bool) -> Bool {
      if value.isEmpty { return grouping }
      guard value.count == 1, value.utf8.count <= 8, let character = value.first,
        !character.isLetter, !character.isNumber,
        !"+-*/^%=()√×÷".contains(character), grouping || !character.isWhitespace,
        !value.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }) else { return false }
      return true
    }
    validNumberMetadata = separator(decimalSeparator, grouping: false)
      && separator(groupingSeparator, grouping: true)
      && decimalSeparator != groupingSeparator && groupingSizes.count <= 4
      && groupingSizes.allSatisfy({ (1...9).contains($0) })
  }

  static func decimalDigit(_ character: Character) -> Int? {
    guard character.unicodeScalars.count == 1,
      character.unicodeScalars.first?.properties.generalCategory == .decimalNumber,
      let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
    return value
  }

  private var legacyCommaDecimal: Bool { self == .invariant }
  private func isDecimal(_ character: Character) -> Bool {
    String(character) == decimalSeparator || (legacyCommaDecimal && character == ",")
  }
  private func isGrouping(_ character: Character) -> Bool {
    guard !groupingSeparator.isEmpty else { return false }
    let spaces: [Character] = [" ", "\u{00A0}", "\u{202F}"]
    if spaces.contains(Character(groupingSeparator)) { return spaces.contains(character) }
    return String(character) == groupingSeparator
  }
  func canStartNumber(_ character: Character) -> Bool {
    Self.decimalDigit(character) != nil || isDecimal(character)
  }

  /// Reads one number without swallowing a following unit or ordinary word.
  func numberPrefix(_ characters: [Character], from start: Int = 0) throws
    -> (text: String, end: Int) {
    guard validNumberMetadata, start < characters.count else { throw SearchMathError.invalid }
    var end = start
    while end < characters.count {
      let character = characters[end]
      if Self.decimalDigit(character) != nil || isDecimal(character) {
        end += 1
      } else if isGrouping(character) {
        if character.isWhitespace,
          (end + 1 == characters.count || Self.decimalDigit(characters[end + 1]) == nil) { break }
        end += 1
      } else if (character == "+" || character == "-")
        && (end == start || characters[end - 1] == "e" || characters[end - 1] == "E") {
        end += 1
      } else if character == "e" || character == "E" {
        var next = end + 1
        if next < characters.count, characters[next] == "+" || characters[next] == "-" {
          next += 1
        }
        guard next < characters.count, Self.decimalDigit(characters[next]) != nil else { break }
        end += 1
      } else { break }
    }
    guard end > start else { throw SearchMathError.invalid }
    return (try normalizedNumber(characters[start..<end]), end)
  }

  private func normalizedNumber(_ characters: ArraySlice<Character>) throws -> String {
    var output = "", groups: [Int] = [], digits = 0, totalDigits = 0
    var decimal = false, exponent = false, exponentDigits = 0
    for (index, character) in characters.enumerated() {
      if let value = Self.decimalDigit(character) {
        output.append(Character(String(value)))
        if exponent { exponentDigits += 1 } else {
          totalDigits += 1
          if !decimal { digits += 1 }
        }
      } else if character == "+" || character == "-" {
        guard index == 0 || output.last == "e" else { throw SearchMathError.invalid }
        output.append(character)
      } else if character == "e" || character == "E" {
        guard !exponent, totalDigits > 0 else { throw SearchMathError.invalid }
        if !decimal { groups.append(digits) }
        exponent = true
        output.append("e")
      } else if isDecimal(character) {
        guard !decimal, !exponent else { throw SearchMathError.invalid }
        groups.append(digits)
        decimal = true
        output.append(".")
      } else if isGrouping(character) {
        guard !groupingSizes.isEmpty, !decimal, !exponent, digits > 0 else {
          throw SearchMathError.invalid
        }
        groups.append(digits)
        digits = 0
      } else { throw SearchMathError.invalid }
    }
    guard totalDigits > 0, !exponent || exponentDigits > 0 else { throw SearchMathError.invalid }
    if !decimal && !exponent { groups.append(digits) }
    if groups.count > 1 {
      for (index, width) in groups.reversed().enumerated() {
        let expected = groupingSizes[min(index, groupingSizes.count - 1)]
        guard width > 0, index == groups.count - 1 ? width <= expected : width == expected
        else { throw SearchMathError.invalid }
      }
    }
    guard let value = Double(output), value.isFinite else { throw SearchMathError.invalid }
    return output
  }

  /// Normalizes only numeric tokens; identifiers and other text stay outside the numeric grammar.
  func normalizedExpression(_ text: String) throws -> String {
    guard text.utf8.count <= 1024, validNumberMetadata else { throw SearchMathError.invalid }
    let characters = Array(text)
    var result = "", index = 0
    while index < characters.count {
      let previousIsIdentifier = index > 0
        && (characters[index - 1].isLetter || characters[index - 1] == "_")
      if canStartNumber(characters[index]), !previousIsIdentifier {
        let number = try numberPrefix(characters, from: index)
        result += number.text
        index = number.end
      } else {
        result.append(characters[index])
        index += 1
      }
    }
    guard result.utf8.count <= 1024 else { throw SearchMathError.invalid }
    return result
  }

  func currencySymbolCode(_ symbol: String) -> String? {
    let localSymbol = currencySymbol.lowercased(), symbol = symbol.lowercased()
    switch symbol {
    case "€": return "eur"
    case "£": return "gbp"
    case "₽": return "rub"
    case "$":
      if localSymbol.contains("$"), let currencyCode { return currencyCode.lowercased() }
      return "usd"
    case "¥", "￥":
      if (localSymbol.contains("¥") || localSymbol.contains("￥")),
        let currencyCode, ["JPY", "CNY"].contains(currencyCode) { return currencyCode.lowercased() }
      return "jpy"
    default:
      return !localSymbol.isEmpty && symbol == localSymbol ? currencyCode?.lowercased() : nil
    }
  }
}
