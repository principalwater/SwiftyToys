// SPDX-License-Identifier: MIT
import Testing
@testable import SearchCore

struct ReferenceRatesTests {
  @Test func neutralBaseConvertsBothDirectionsAndCrossRates() throws {
    let rates = try ReferenceRates(date: "2026-10-14", base: "USD",
      rates: ["GBP": 0.75, "JPY": 150, "INR": 90])
    #expect(rates.base == "USD")
    #expect(rates.rates["USD"] == 1)
    #expect(try rates.convert(ConversionQuery("100 USD GBP"))?.value == "75 GBP")
    #expect(try rates.convert(ConversionQuery("75 GBP USD"))?.value == "100 USD")
    #expect(try rates.convert(ConversionQuery("10 GBP JPY"))?.value == "2000 JPY")
    #expect(try rates.convert(ConversionQuery("100 USD INR"))?.value == "9000 INR")
    #expect(try rates.convert(ConversionQuery("10 USD RUB")) == nil)
    let cached = try rates.convert(ConversionQuery("100 USD GBP"), cached: true)
    #expect(cached?.detail == "Frankfurter daily reference rates · 2026-10-14 · cached · 100 USD")
  }

  @Test func differentBaseAndNewCurrencyCodesDoNotNeedAnAllowlist() throws {
    let rates = try ReferenceRates(date: "2026-10-14", base: "CHF", rates: ["KES": 140])
    #expect(try rates.convert(ConversionQuery("2 CHF KES"))?.value == "280 KES")
    for code in ["USD", "GBP", "JPY", "RUB", "INR", "KES", "XAF", "BHD", "ZMW", "CUP"] {
      #expect(ReferenceRates.currency(code.lowercased()) == code)
    }
    #expect(ReferenceRates.currency("dollars") == "USD")
    #expect(ReferenceRates.currency("€") == "EUR")
    for unit in ["min", "gal", "sec", "day", "lbs", "kib", "mib", "gib", "bar", "psi"] {
      #expect(ReferenceRates.currency(unit) == nil)
    }
    for malformed in ["US", "USDD", "US1", "../", "u sd", "USD\n"] {
      #expect(ReferenceRates.currency(malformed) == nil)
    }
  }

  @Test func currencyCodesThatOverlapUnitWordsRemainValidQuotes() throws {
    #expect(ReferenceRates.currency("cup") == "CUP")
    let rates = try ReferenceRates(date: "2026-10-14", base: "CUP", rates: ["USD": 0.05])
    #expect(rates.convert(.init(amount: 120, from: "CUP", to: "USD"))?.value == "6 USD")
    #expect(rates.convert(.init(amount: 6, from: "USD", to: "CUP"))?.value == "120 CUP")
  }

  @Test func exactGregorianDatesAndAgeAcrossLeapBoundaries() throws {
    let leap = try ReferenceRates(date: "2024-02-29", base: "EUR", rates: ["USD": 1.1])
    #expect(leap.ageInDays(onDate: "2024-03-01") == 1)
    #expect(leap.ageInDays(onDate: "2024-02-28") == -1)
    let century = try ReferenceRates(date: "2000-02-29", base: "EUR", rates: ["USD": 1])
    #expect(century.ageInDays(onDate: "2000-03-01") == 1)
    for date in ["2023-02-29", "1900-02-29", "2026-04-31", "2026-00-01", "2026-13-01",
      "2026-01-00", "2026-1-01", "14.10.2026", "0000-01-01", "2026-10-14\n"] {
      #expect(throws: (any Error).self) {
        try ReferenceRates(date: date, base: "EUR", rates: ["USD": 1])
      }
    }
  }

  @Test func rejectsInvalidRatesAndWrongBaseConvention() {
    for rate in [0.0, -1, Double.nan, .infinity, -.infinity] {
      #expect(throws: (any Error).self) {
        try ReferenceRates(date: "2026-10-14", base: "USD", rates: ["GBP": rate])
      }
    }
    #expect(throws: (any Error).self) {
      try ReferenceRates(date: "2026-10-14", base: "USD", rates: ["USD": 2, "GBP": 1])
    }
    #expect(throws: (any Error).self) {
      try ReferenceRates(date: "2026-10-14", base: "usd", rates: ["GBP": 1])
    }
    #expect(throws: (any Error).self) {
      try ReferenceRates(date: "2026-10-14", base: "USD", rates: ["gal": 1])
    }
  }

  @Test func nonfiniteAmountsAndOverflowNeverProduceQuotes() throws {
    let rates = try ReferenceRates(date: "2026-10-14", base: "USD", rates: ["GBP": 2])
    #expect(rates.convert(.init(amount: .infinity, from: "USD", to: "GBP")) == nil)
    #expect(rates.convert(.init(amount: Double.greatestFiniteMagnitude, from: "USD", to: "GBP")) == nil)
    #expect(rates.convert(.init(amount: -5, from: "USD", to: "GBP"))?.value == "-10 GBP")
  }
}
