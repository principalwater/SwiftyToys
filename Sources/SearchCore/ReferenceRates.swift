// SPDX-License-Identifier: MIT

/// Dated reference rates expressed as quote-currency units per unit of `base`.
public struct ReferenceRates: Sendable, Equatable {
  public static let sourceName = "Frankfurter daily reference rates"
  public let date: String
  public let base: String
  public let rates: [String: Double]
  public let source: String
  private let dayNumber: Int
  private static let unitCodes: Set<String> = [
    "MIN", "GAL", "CUP", "SEC", "DAY", "LBS", "KIB", "MIB", "GIB", "TIB",
    "BIT", "BAR", "PSI", "KPA", "MPH", "RPM", "KWH", "MOL", "OHM", "RAD", "DEG",
  ]

  public init(date: String, base: String, rates: [String: Double],
    source: String = Self.sourceName) throws {
    guard let dayNumber = Self.dayNumber(date), Self.currency(base) == base,
      !rates.isEmpty, rates.count <= 256, rates[base] == nil || rates[base] == 1,
      rates.allSatisfy({ Self.currency($0.key) == $0.key && $0.value.isFinite && $0.value > 0 }),
      !source.isEmpty, source.utf8.count <= 128,
      !source.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw SearchMathError.invalid
    }
    self.date = date
    self.base = base
    self.rates = rates.merging([base: 1]) { _, new in new }
    self.source = source
    self.dayNumber = dayNumber
  }

  /// Recognizes currency aliases and ISO-style codes, leaving catalog validation to the caller.
  public static func currency(_ text: String) -> String? {
    guard text.utf8.count <= 32 else { return nil }
    switch text.lowercased() {
    case "$", "usd", "dollar", "dollars": return "USD"
    case "€", "eur", "euro", "euros": return "EUR"
    case "₽", "rub", "ruble", "rubles", "rouble", "roubles": return "RUB"
    case "£", "gbp", "sterling": return "GBP"
    case "¥", "jpy", "yen": return "JPY"
    default:
      let code = text.uppercased()
      return code.utf8.count == 3 && code.utf8.allSatisfy({ (65...90).contains($0) })
        && !unitCodes.contains(code) ? code : nil
    }
  }

  /// Returns signed calendar-day age; negative values indicate a future observation.
  public func ageInDays(onDate date: String) -> Int? {
    Self.dayNumber(date).map { $0 - dayNumber }
  }

  public func convert(_ query: ConversionQuery, cached: Bool = false) -> SearchAnswer? {
    guard query.amount.isFinite, let from = Self.currency(query.from),
      let to = Self.currency(query.to), let first = rates[from], let second = rates[to] else {
      return nil
    }
    let converted = query.amount / first * second
    guard converted.isFinite else { return nil }
    return SearchAnswer(title: "Currency conversion",
      value: SearchAnswers.number(converted) + " " + to,
      detail: source + " · " + date + (cached ? " · cached" : "")
        + " · " + SearchAnswers.number(query.amount) + " " + from)
  }

  private static func dayNumber(_ date: String) -> Int? {
    let bytes = Array(date.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
      bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7
        || (48...57).contains($0.element) }) else { return nil }
    func number(_ range: Range<Int>) -> Int {
      range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
    }
    let year = number(0..<4), month = number(5..<7), day = number(8..<10)
    guard year > 0, (1...12).contains(month) else { return nil }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let months = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...months[month - 1]).contains(day) else { return nil }
    let prior = year - 1
    return prior * 365 + prior / 4 - prior / 100 + prior / 400
      + months.prefix(month - 1).reduce(0, +) + day
  }
}
