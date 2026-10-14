// SPDX-License-Identifier: MIT
import Testing
@testable import SearchCore

struct SearchRegionTests {
  private let us = SearchRegion(countryCode: "US", currencyCode: "USD", currencySymbol: "$",
    groupingSeparator: ",", usesUSMeasurement: true)
  private let gb = SearchRegion(countryCode: "GB", currencyCode: "GBP", currencySymbol: "£",
    groupingSeparator: ",", usesUSMeasurement: false)
  private let ru = SearchRegion(countryCode: "RU", currencyCode: "RUB", currencySymbol: "₽",
    decimalSeparator: ",", groupingSeparator: "\u{00A0}", usesUSMeasurement: false)
  private let jp = SearchRegion(countryCode: "JP", currencyCode: "JPY", currencySymbol: "￥",
    groupingSeparator: ",", usesUSMeasurement: false)
  private let ca = SearchRegion(countryCode: "CA", currencyCode: "CAD", currencySymbol: "CA$",
    groupingSeparator: ",", usesUSMeasurement: false)
  private let frenchCanada = SearchRegion(countryCode: "CA", currencyCode: "CAD",
    currencySymbol: "$", decimalSeparator: ",", groupingSeparator: "\u{202F}",
    usesUSMeasurement: false)
  private let arabic = SearchRegion(countryCode: "EG", currencyCode: "EGP", currencySymbol: "ج.م.",
    decimalSeparator: "٫", groupingSeparator: "٬", usesUSMeasurement: false)
  private let india = SearchRegion(countryCode: "IN", currencyCode: "INR", currencySymbol: "₹",
    groupingSeparator: ",", groupingSizes: [3, 2], usesUSMeasurement: false)

  @Test func metadataDoesNotGuessCountryCurrencyOrMeasurements() {
    let countryOnly = SearchRegion(countryCode: "ca")
    #expect(countryOnly.countryCode == "CA")
    #expect(countryOnly.currencyCode == nil)
    #expect(countryOnly.usesUSMeasurement == nil)
    #expect(SearchRegion(countryCode: "123", currencyCode: "US$").currencyCode == nil)
    #expect(SearchRegion(countryCode: "123").countryCode == nil)
    #expect(SearchRegion(currencyCode: "eur").currencyCode == "EUR")
  }

  @Test func parsesSuppliedDecimalAndGroupingStyles() throws {
    for (region, text, expected) in [
      (us, "1,234.5 kg", 1234.5), (gb, "12,345.5 kg", 12345.5),
      (ru, "1\u{00A0}234,5 kg", 1234.5), (ru, "1\u{202F}234,5 kg", 1234.5),
      (jp, "１,２３４.５ kg", 1234.5), (ca, "1,234.5 kg", 1234.5),
      (frenchCanada, "1 234,5 kg", 1234.5), (arabic, "١٬٢٣٤٫٥ kg", 1234.5),
      (india, "12,34,567.5 kg", 1234567.5), (india, "1,234 kg", 1234.0),
    ] {
      #expect(try ConversionQuery(text, region: region).amount == expected)
    }
    #expect(try ConversionQuery("1,5 kg").amount == 1.5)
    #expect(try ConversionQuery("10eur").from == "eur")
  }

  @Test func rejectsMalformedOrWrongLocaleGrouping() {
    for (region, text) in [
      (gb, "1,00,000 kg"), (gb, "1,23 kg"), (gb, "1,,234 kg"),
      (gb, "1,234, kg"), (gb, "1.2.3 kg"), (gb, "1,234.5,6 kg"),
      (gb, "1 234 kg"), (india, "123,456 kg"), (india, "1,234,567 kg"),
      (ru, "1.234,5 kg"), (ru, "1 23,5 kg"), (arabic, "١٬٢٣٫٥ kg"),
    ] {
      #expect(throws: SearchMathError.self) { try ConversionQuery(text, region: region) }
      #expect(SearchAnswers.quick(text, region: region) == nil)
    }
  }

  @Test func calculatorsNormalizeOnlyNumericTokens() throws {
    for (region, text, expected) in [
      (ru, "1 234,5 + 2,5", 1237.0), (gb, "1,234.5 + 2.5", 1237.0),
      (arabic, "١٬٢٣٤٫٥ + ٢٫٥", 1237.0), (india, "1,23,456 + 2", 123458.0),
      (jp, "１２×３", 36.0), (frenchCanada, "sqrt(١٤٤)+0,5", 12.5),
      (us, "1e3/4", 250.0),
    ] {
      #expect(try SearchAnswers.calculate(text, region: region) == expected)
    }
    #expect(SearchAnswers.quick("١٢", region: arabic)?.value == "12")
    #expect(SearchAnswers.quick("1,5", region: .invariant)?.value == "1.5")
    for text in ["report-2026", "2026-report.swift", "unit١٢", "notes ١٬٢٣٤", "log١٠(100)"] {
      #expect(SearchAnswers.quick(text, region: arabic) == nil)
    }
    #expect(SearchAnswers.quick("1/0", region: ru)?.value == "Undefined")
  }

  @Test func explicitTargetsOverrideSuppliedMeasurementPreference() throws {
    #expect(try UnitConversion("1 m", region: us).target == "ft")
    #expect(try UnitConversion("1 m", region: gb).target == "m")
    #expect(try UnitConversion("1 kg", region: us).target == "lb")
    #expect(try UnitConversion("1 kg", region: ru).target == "kg")
    #expect(try UnitConversion("1 L", region: us).target == "US gal")
    #expect(try UnitConversion("1 L", region: ca).target == "L")
    #expect(try UnitConversion("0 C", region: us).target == "°F")
    #expect(try UnitConversion("32 F", region: jp).target == "°C")
    #expect(try UnitConversion("1 m in cm", region: us).value == 100)
    #expect(try UnitConversion("0 C to F", region: ru).target == "°F")
    #expect(try UnitConversion("1 m").target == "ft")
    #expect(try UnitConversion("32 F").target == "°C")
  }

  @Test func imperialAndUSGallonsStayDistinct() throws {
    for query in ["1 ukgal to L", "1 impgal in L", "1 imperial gallon to L", "1 UK gal L"] {
      #expect(try UnitConversion(query, region: gb).value == 4.54609)
    }
    for query in ["1 usgal to L", "1 US gallon to L", "1 gal L"] {
      #expect(try UnitConversion(query, region: gb).value == 3.785411784)
    }
    #expect(abs(try UnitConversion("1 impgal to usgal").value - 1.2009499255) < 1e-9)
  }

  @Test func explicitSymbolsUseActualLocalCurrencyMetadata() throws {
    #expect(try ConversionQuery("$120 in rub") == .init(amount: 120, from: "usd", to: "rub"))
    #expect(try ConversionQuery("$120 in usd", region: ca).from == "cad")
    #expect(try ConversionQuery("CA$120 USD", region: ca).from == "cad")
    #expect(try ConversionQuery("120 $ to USD", region: frenchCanada).from == "cad")
    #expect(try ConversionQuery("$120 USD", region: gb).from == "usd")
    #expect(try ConversionQuery("¥120 USD", region: jp).from == "jpy")
    #expect(try ConversionQuery("￥120 USD", region: jp).from == "jpy")
    let china = SearchRegion(countryCode: "CN", currencyCode: "CNY", currencySymbol: "¥")
    #expect(try ConversionQuery("￥120 USD", region: china).from == "cny")
    #expect(try ConversionQuery("¥120 USD", region: us).from == "jpy")
    #expect(try ConversionQuery("€120 GBP", region: ru).from == "eur")
    #expect(try ConversionQuery("£120 EUR", region: us).from == "gbp")
    #expect(try ConversionQuery("₽120 EUR", region: ca).from == "rub")
    #expect(try ConversionQuery("₹1,00,000 USD", region: india).amount == 100000)
    #expect(try ConversionQuery("100 CAD", region: ca).to.isEmpty)
    #expect(try ConversionQuery("100 XYZ to USD", region: .invariant).from == "xyz")
  }

  @Test func invalidMetadataAndBoundariesFailWithoutLocaleFallback() {
    for region in [
      SearchRegion(decimalSeparator: ".."), SearchRegion(decimalSeparator: "x"),
      SearchRegion(decimalSeparator: ",", groupingSeparator: ","),
      SearchRegion(groupingSizes: [0]), SearchRegion(groupingSeparator: "12"),
    ] {
      #expect(SearchAnswers.quick("1+2", region: region) == nil)
      #expect(throws: SearchMathError.self) { try ConversionQuery("1 kg", region: region) }
    }
    #expect(SearchRegion(currencySymbol: "\0").currencySymbol.isEmpty)
    let missingCurrency = SearchRegion(countryCode: "CA", currencySymbol: "CA$")
    #expect(throws: SearchMathError.self) { try ConversionQuery("CA$10 EUR", region: missingCurrency) }
    for query in [String(repeating: "1", count: 1025), "½ kg", "١\u{0301} kg", "1e999 kg",
      String(repeating: "(", count: 80) + "1" + String(repeating: ")", count: 80)] {
      #expect(SearchAnswers.quick(query, region: us) == nil)
    }
  }

  @Test func customSeparatorsAndDisabledGroupingAreRespected() throws {
    let custom = SearchRegion(decimalSeparator: "·", groupingSeparator: "_", groupingSizes: [3])
    #expect(try ConversionQuery("1_234·5 kg", region: custom).amount == 1234.5)
    #expect(try SearchAnswers.calculate("1_234·5 + 2·5", region: custom) == 1237)
    let ungrouped = SearchRegion(groupingSeparator: ",", groupingSizes: [])
    #expect(try ConversionQuery("1234.5 kg", region: ungrouped).amount == 1234.5)
    #expect(throws: SearchMathError.self) { try ConversionQuery("1,234.5 kg", region: ungrouped) }
  }

  @Test func explicitCurrencySpellingWinsOverLowercaseUnitAlias() throws {
    let local = SearchRegion(currencyCode: "CUP", currencySymbol: "$", usesUSMeasurement: false)
    #expect(try UnitConversion("1 cup L", region: local).value == 0.2365882365)
    #expect(SearchAnswers.quick("1 cup L", region: local)?.value == "0.236588237 L")
    #expect(try UnitConversion("1 MIN SEC", region: local).value == 60)
    #expect(try UnitConversion("1 GAL L", region: local).value == 3.785411784)
    for query in ["120 CUP", "120CUP", "120 CUP in L", "1 L to CUP", "$120", "120 $"] {
      #expect(throws: SearchMathError.self) { try UnitConversion(query, region: local) }
      #expect(SearchAnswers.quick(query, region: local) == nil)
    }
    #expect(try ConversionQuery("120CUP", region: local).from == "cup")
    #expect(try ConversionQuery("$120", region: local).from == "cup")
    #expect(try ConversionQuery("120 $", region: local).from == "cup")
    let symbol = SearchRegion(currencyCode: "CUP", currencySymbol: "CU$")
    #expect(SearchAnswers.quick("CU$120", region: symbol) == nil)
    #expect(try ConversionQuery("CU$120", region: symbol).from == "cup")
    #expect(try UnitConversion("1 Cup L", region: local).value == 0.2365882365)
  }
}
