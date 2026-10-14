// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK

/// Regional defaults come from Windows, independently of the application's display language.
enum NativeSearchRegion {
  struct Context: Sendable {
    let localeName: String
    let region: SearchRegion
    let knownCurrencies: Set<String>
    let userOverrides: Bool
  }
  private struct Entry {
    let name: String
    let country: String
    let currency: String
  }
  // First touched by the Search worker, never by the keyboard hook or its UI callbacks.
  private static let entries: [Entry] = {
    var result: [Entry] = []
    withUnsafeMutablePointer(to: &result) { output in
      _ = EnumSystemLocalesEx({ name, _, parameter in
        guard let name, let output = UnsafeMutablePointer<[Entry]>(bitPattern: Int(parameter)),
          output.pointee.count < 2048 else { return false }
        let locale = String(decodingCString: name, as: UTF16.self)
        if let country = info(locale, LOCALE_SISO3166CTRYNAME),
          let currency = info(locale, LOCALE_SINTLSYMBOL), validCountry(country), validCurrency(currency) {
          output.pointee.append(Entry(name: locale, country: country, currency: currency))
        }
        return true
      }, DWORD(LOCALE_SPECIFICDATA), LPARAM(Int(bitPattern: output)), nil)
    }
    return result
  }()
  private static let knownCurrencies = Set(entries.map(\.currency))

  private static func validCountry(_ value: String) -> Bool {
    value.utf8.count == 2 && value.utf8.allSatisfy { (65...90).contains($0) }
  }
  private static func validCurrency(_ value: String) -> Bool {
    value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) } && value != "XXX"
  }
  private static func info(_ locale: String, _ type: Int32, userOverrides: Bool = true) -> String? {
    var buffer = [WCHAR](repeating: 0, count: 128)
    let flags = LCTYPE(type) | (userOverrides ? 0 : LCTYPE(LOCALE_NOUSEROVERRIDE))
    let count = withWideString(locale) { GetLocaleInfoEx($0, flags, &buffer, Int32(buffer.count)) }
    guard count > 1, count <= buffer.count else { return nil }
    return String(decoding: buffer.prefix(Int(count) - 1), as: UTF16.self)
  }
  private static func userLocale() -> String {
    var buffer = [WCHAR](repeating: 0, count: 85)
    let count = GetUserDefaultLocaleName(&buffer, Int32(buffer.count))
    return count > 1 ? String(decoding: buffer.prefix(Int(count) - 1), as: UTF16.self) : ""
  }
  private static func userCountry() -> String? {
    var buffer = [WCHAR](repeating: 0, count: 16)
    let count = GetUserDefaultGeoName(&buffer, Int32(buffer.count))
    guard count > 1, count <= buffer.count else { return nil }
    let value = String(decoding: buffer.prefix(Int(count) - 1), as: UTF16.self)
    return validCountry(value) ? value : nil
  }

  /// Explicit arguments are read-only test fixtures; production preserves the user's NLS overrides.
  static func current(localeName: String? = nil, countryCode: String? = nil,
    userOverrides: Bool = true) -> Context {
    let locale = localeName ?? userLocale()
    let formatCountry = info(locale, LOCALE_SISO3166CTRYNAME, userOverrides: userOverrides)
    let country = countryCode ?? (localeName == nil ? userCountry() : nil) ?? formatCountry
    let language = locale.split(separator: "-").first
    let candidates = entries.filter { $0.country == country }
    let moneyLocale = candidates.first(where: { $0.name == locale })
      ?? candidates.first(where: { $0.name.split(separator: "-").first == language })
      ?? candidates.first
    let currency = moneyLocale?.currency
    let symbol = moneyLocale.flatMap { info($0.name, LOCALE_SCURRENCY, userOverrides: userOverrides) } ?? ""
    let decimal = info(locale, LOCALE_SDECIMAL, userOverrides: userOverrides) ?? "."
    let grouping = info(locale, LOCALE_STHOUSAND, userOverrides: userOverrides) ?? ""
    let sizes = (info(locale, LOCALE_SGROUPING, userOverrides: userOverrides) ?? "0")
      .split(separator: ";").compactMap { Int($0) }.filter { $0 > 0 }
    let measure = info(locale, LOCALE_IMEASURE, userOverrides: userOverrides)
    let region = SearchRegion(countryCode: country, currencyCode: currency,
      currencySymbol: symbol, decimalSeparator: decimal, groupingSeparator: grouping,
      groupingSizes: sizes, usesUSMeasurement: measure == "1" ? true : measure == "0" ? false : nil)
    return Context(localeName: locale, region: region,
      knownCurrencies: knownCurrencies, userOverrides: userOverrides)
  }

  static func currencyQuery(_ text: String, context: Context) -> ConversionQuery? {
    guard let parsed = try? ConversionQuery(text, region: context.region),
      let from = ReferenceRates.currency(parsed.from) else { return nil }
    let explicitISO = text.split(whereSeparator: { !$0.isLetter }).contains { String($0) == from }
    guard context.knownCurrencies.contains(from) || from == context.region.currencyCode || explicitISO else { return nil }
    if !parsed.to.isEmpty, ReferenceRates.currency(parsed.to) == nil { return nil }
    let target = parsed.to.isEmpty ? context.region.currencyCode : ReferenceRates.currency(parsed.to)
    return ConversionQuery(amount: parsed.amount, from: from, to: target ?? "")
  }

  /// Formats result numbers with NLS while keeping protocol data and currency codes invariant.
  static func number(_ value: Double, context: Context) -> String {
    let raw = SearchAnswers.number(value)
    guard !context.localeName.isEmpty, !raw.contains("e"), !raw.contains("E") else { return raw }
    var output = [WCHAR](repeating: 0, count: 256)
    let decimals = raw.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
    var format = NUMBERFMTW()
    format.NumDigits = UINT(min(9, decimals))
    format.LeadingZero = info(context.localeName, LOCALE_ILZERO,
      userOverrides: context.userOverrides) == "0" ? 0 : 1
    let sizes = context.region.groupingSizes
    guard sizes.count <= 4, sizes.allSatisfy({ (1...9).contains($0) }) else { return raw }
    format.Grouping = sizes.reduce(0) { $0 * 10 + UINT($1) }
    let negativeOrder = Int(info(context.localeName, LOCALE_INEGNUMBER,
      userOverrides: context.userOverrides) ?? "1") ?? 1
    format.NegativeOrder = UINT((0...4).contains(negativeOrder) ? negativeOrder : 1)
    let count = withWideString(context.region.decimalSeparator) { decimal in
      withWideString(context.region.groupingSeparator) { grouping in
        format.lpDecimalSep = UnsafeMutablePointer(mutating: decimal)
        format.lpThousandSep = UnsafeMutablePointer(mutating: grouping)
        return withWideString(context.localeName) { locale in
          withWideString(raw) { GetNumberFormatEx(locale, 0, $0, &format, &output, Int32(output.count)) }
        }
      }
    }
    return count > 1 ? String(decoding: output.prefix(Int(count) - 1), as: UTF16.self) : raw
  }

  static func format(_ answer: SearchAnswer, context: Context) -> SearchAnswer {
    func amount(_ text: String) -> String {
      let split = text.firstIndex(of: " ") ?? text.endIndex
      guard let value = Double(text[..<split]), value.isFinite else { return text }
      return number(value, context: context) + text[split...]
    }
    let detail: String
    if answer.title == "Currency conversion" {
      // Source labels/dates/amounts are independent fields, not a number to re-interpret.
      detail = answer.detail.split(separator: "·", omittingEmptySubsequences: false).map { part in
        let value = String(part).trimmingWhitespace()
        return date(value, localeName: context.localeName, userOverrides: context.userOverrides) ?? amount(value)
      }.joined(separator: " · ")
    } else { detail = answer.title == "Unit conversion" ? amount(answer.detail) : answer.detail }
    return SearchAnswer(title: answer.title, value: amount(answer.value), detail: detail)
  }

  static func date(_ text: String, localeName: String, userOverrides: Bool = true) -> String? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      let year = UInt16(parts[0]), let month = UInt16(parts[1]), let day = UInt16(parts[2]),
      (1...12).contains(month), (1...31).contains(day) else { return nil }
    var time = SYSTEMTIME(); time.wYear = year; time.wMonth = month; time.wDay = day
    return date(&time, localeName: localeName, userOverrides: userOverrides)
  }
  static func date(_ time: inout SYSTEMTIME, localeName: String, userOverrides: Bool = true) -> String? {
    var result = [WCHAR](repeating: 0, count: 128)
    let count = withWideString(localeName) {
      GetDateFormatEx($0, DWORD(DATE_SHORTDATE) | (userOverrides ? 0 : DWORD(LOCALE_NOUSEROVERRIDE)),
        &time, nil, &result, Int32(result.count), nil)
    }
    return count > 1 ? String(decoding: result.prefix(Int(count) - 1), as: UTF16.self) : nil
  }
  static func time(_ value: inout SYSTEMTIME, localeName: String, userOverrides: Bool = true) -> String? {
    var result = [WCHAR](repeating: 0, count: 128)
    let count = withWideString(localeName) {
      GetTimeFormatEx($0, DWORD(TIME_NOSECONDS) | (userOverrides ? 0 : DWORD(LOCALE_NOUSEROVERRIDE)),
        &value, nil, &result, Int32(result.count))
    }
    return count > 1 ? String(decoding: result.prefix(Int(count) - 1), as: UTF16.self) : nil
  }

  static func selfCheck() throws {
    for (locale, currency, us) in [("ru-RU", "RUB", false), ("en-GB", "GBP", false),
      ("ja-JP", "JPY", false), ("en-US", "USD", true), ("fr-CA", "CAD", false)] {
      let profile = current(localeName: locale, userOverrides: false)
      guard profile.region.currencyCode == currency, profile.region.usesUSMeasurement == us,
        let money = currencyQuery("120 USD", context: profile), money.to == currency else {
        throw WindowsError.unsupported("Native regional defaults failed for " + locale + ".")
      }
    }
    let mixed = current(localeName: "en-US", countryCode: "JP", userOverrides: false)
    guard mixed.region.currencyCode == "JPY", mixed.region.decimalSeparator == "." else {
      throw WindowsError.unsupported("Region currency was coupled to display/format language.")
    }
    let unknown = current(localeName: "en-US", countryCode: "ZZ", userOverrides: false)
    guard unknown.region.currencyCode == nil, currencyQuery("120 USD", context: unknown)?.to == "",
      currencyQuery("120 USD GBP", context: unknown)?.to == "GBP",
      currencyQuery("120 USD bananas", context: unknown) == nil else {
      throw WindowsError.unsupported("Unknown region silently selected a currency.")
    }
    let british = current(localeName: "en-GB", userOverrides: false)
    let russian = current(localeName: "ru-RU", userOverrides: false)
    let symbolFixture = Context(localeName: "en-GB",
      region: SearchRegion(currencyCode: "CUP", currencySymbol: "$"),
      knownCurrencies: knownCurrencies, userOverrides: false)
    guard currencyQuery("120 CUP GBP", context: british)?.from == "CUP",
      currencyQuery("120CUP", context: british)?.from == "CUP",
      currencyQuery("$120", context: symbolFixture)?.from == "CUP",
      currencyQuery("120 USD", context: symbolFixture)?.to == "CUP",
      SearchAnswers.quick("120 CUP", region: british.region) == nil,
      SearchAnswers.quick("$120", region: symbolFixture.region) == nil,
      SearchAnswers.quick("1 cup in ml", region: british.region) != nil else {
      throw WindowsError.unsupported("ISO currency or local symbol collided with a volume unit.")
    }
    var sample = SYSTEMTIME(); sample.wHour = 13; sample.wMinute = 5
    let americanTime = time(&sample, localeName: "en-US", userOverrides: false)
    let britishTime = time(&sample, localeName: "en-GB", userOverrides: false)
    guard number(1234.5, context: british) == "1,234.5",
      number(1234.5, context: russian).hasSuffix(",5"),
      americanTime?.containsText("PM") == true, britishTime == "13:05",
      date("2026-10-14", localeName: "en-US", userOverrides: false)
        != date("2026-10-14", localeName: "ja-JP", userOverrides: false) else {
      throw WindowsError.unsupported("Native number formats ignored regional separators.")
    }
    Console.writeLine("PASS: native Windows region/currency/measurement/number defaults, mixed region/format language, explicit target and unknown-region fallback; no system preferences changed")
  }
}
