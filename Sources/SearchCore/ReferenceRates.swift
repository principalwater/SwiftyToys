// SPDX-License-Identifier: MIT
import BrightnessCore
/// Published central-bank reference rates, not a tradable quote. Values are RUB per currency unit.
public struct ReferenceRates: Sendable, Equatable {
    public let date: String
    public let rates: [String: Double]
    public init(date: String, rates: [String: Double]) throws {
        let parts = date.split(separator: ".")
        guard parts.count == 3, let day = Int(parts[0]), (1...31).contains(day), let month = Int(parts[1]), (1...12).contains(month),
            let year = Int(parts[2]), (2000...2200).contains(year), rates.count <= 100,
            rates.allSatisfy({ $0.key.utf8.count == 3 && $0.key.utf8.allSatisfy { (65...90).contains($0) } && $0.value.isFinite && $0.value > 0 && $0.value < 1e12 })
        else { throw SearchMathError.invalid }
        self.date = date; self.rates = rates.merging(["RUB": 1]) { _, new in new }
    }
    public static func currency(_ text: String) -> String? {
        switch text.lowercased() {
        case "$", "usd", "dollar", "dollars": return "USD"
        case "€", "eur", "euro", "euros": return "EUR"
        case "₽", "rub", "ruble", "rubles", "rouble", "roubles": return "RUB"
        case "£", "gbp": return "GBP"
        case "¥", "jpy", "yen": return "JPY"
        default:
            let code = text.uppercased()
            return ["AUD","AZN","AMD","BHD","BRL","BYN","CAD","CHF","CNY","CZK","DKK","DZD","EGP","ETB","GEL","HKD","HUF","IDR","ILS","INR","IRR","KGS","KRW","KWD","KZT","MDL","MNT","NGN","NOK","NZD","OMR","PLN","QAR","RON","RSD","SAR","SEK","SGD","THB","TJS","TRY","TMT","UAH","UZS","VND","ZAR"].contains(code) ? code : nil
        }
    }
    public func convert(_ query: ConversionQuery) -> SearchAnswer? {
        guard let from = Self.currency(query.from), let to = Self.currency(query.to), let first = rates[from], let second = rates[to] else { return nil }
        let converted = query.amount * first / second
        guard converted.isFinite else { return nil }
        return SearchAnswer(title: "Currency conversion", value: SearchAnswers.number(converted) + " " + to,
            detail: "Bank of Russia reference rates · " + date + " · " + SearchAnswers.number(query.amount) + " " + from)
    }
    /// Only consumes the bounded ASCII numeric fields from the official XML feed. It never resolves XML entities or external resources.
    public static func parseCBR(_ bytes: [UInt8]) throws -> ReferenceRates {
        guard bytes.count <= 262144, !bytes.contains(0) else { throw SearchMathError.invalid }
        let text = String(decoding: bytes, as: UTF8.self)
        guard !text.containsText("<!DOCTYPE"), !text.containsText("<!ENTITY"), let start = text.literalRange("<ValCurs "),
            let dateStart = text.literalRange("Date=\"", within: start.upperBound..<text.endIndex),
            let dateEnd = text[dateStart.upperBound...].firstIndex(of: "\"") else { throw SearchMathError.invalid }
        let date = String(text[dateStart.upperBound..<dateEnd])
        var rates: [String: Double] = [:], cursor = dateEnd
        func field(_ name: String, _ section: Substring) throws -> String {
            guard let first = section.literalRange("<" + name + ">"), let last = section.literalRange("</" + name + ">", within: first.upperBound..<section.endIndex) else { throw SearchMathError.invalid }
            return String(section[first.upperBound..<last.lowerBound])
        }
        while let first = text.literalRange("<Valute ", within: cursor..<text.endIndex) {
            guard rates.count < 100, let last = text.literalRange("</Valute>", within: first.upperBound..<text.endIndex) else { throw SearchMathError.invalid }
            let section = text[first.upperBound..<last.lowerBound]
            let code = try field("CharCode", section)
            guard rates[code] == nil, let nominal = Double(try field("Nominal", section)), nominal > 0,
                let value = Double(String(try field("Value", section).map { $0 == "," ? "." : $0 })) else { throw SearchMathError.invalid }
            rates[code] = value / nominal; cursor = last.upperBound
        }
        guard !rates.isEmpty, text.containsText("</ValCurs>") else { throw SearchMathError.invalid }
        return try ReferenceRates(date: date, rates: rates)
    }
}
