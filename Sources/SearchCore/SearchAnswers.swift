// SPDX-License-Identifier: MIT
#if os(Windows)
import CRT
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SearchAnswer: Sendable, Equatable {
    public let title: String
    public let value: String
    public let detail: String
    public init(title: String, value: String, detail: String) { self.title = title; self.value = value; self.detail = detail }
}
public enum SearchMathError: Error, Sendable { case invalid, domain }

public enum SearchAnswers {
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "Undefined" }
        if value == 0 { return "0" }
        let rounded = (value * 1_000_000_000).rounded() / 1_000_000_000
        var text = String(rounded.isFinite && rounded != 0 ? rounded : value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }
    public static func calculate(_ text: String, region: SearchRegion = .invariant) throws -> Double {
        guard text.utf8.count <= 1024 else { throw SearchMathError.invalid }
        var parser = try Calculator(text, region: region)
        let result = try parser.expression()
        parser.whitespace()
        guard parser.position == parser.bytes.count else { throw SearchMathError.invalid }
        guard result.isFinite else { throw SearchMathError.domain }
        return result
    }
    public static func quick(_ text: String, region: SearchRegion = .invariant) -> SearchAnswer? {
        guard text.utf8.count <= 1024 else { return nil }
        if let conversion = try? UnitConversion(text, region: region) {
            return SearchAnswer(title: "Unit conversion", value: number(conversion.value) + " " + conversion.target, detail: conversion.source)
        }
        // Ordinary words are queries. Display a domain error only for clearly mathematical input.
        let normalized = try? region.normalizedExpression(text)
        let looksLikeMath = normalized.flatMap(Double.init) != nil || text.contains(where: { "+*/^%=()√×÷".contains($0) }) || text.first?.isNumber == true && text.contains("-")
        guard looksLikeMath else { return nil }
        do { return SearchAnswer(title: "Calculator", value: number(try calculate(text, region: region)), detail: "Enter or Copy copies the result.") }
        catch SearchMathError.domain { return SearchAnswer(title: "Calculator", value: "Undefined", detail: "Check the expression: division by zero or an invalid function argument.") }
        catch { return nil }
    }
}

private struct Calculator {
    var bytes: [UInt8]
    var position = 0
    var depth = 0
    var operations = 0
    init(_ text: String, region: SearchRegion) throws {
        var normalized = ""
        for character in text.lowercased() {
            switch character { case "×": normalized += "*"; case "÷": normalized += "/"; case "√": normalized += "sqrt "; default: normalized.append(character) }
        }
        bytes = Array(try region.normalizedExpression(normalized).utf8)
    }
    mutating func whitespace() { while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { whitespace(); guard position < bytes.count, bytes[position] == byte else { return false }; position += 1; return true }
    mutating func bump() throws { operations += 1; guard operations <= 256, bytes.count <= 1024 else { throw SearchMathError.invalid } }
    mutating func expression() throws -> Double {
        try bump(); depth += 1; defer { depth -= 1 }; guard depth <= 32 else { throw SearchMathError.invalid }
        if position == 0 { _ = take(61) }
        var value = try product()
        while true { if take(43) { value += try product() } else if take(45) { value -= try product() } else { return value } }
    }
    mutating func product() throws -> Double {
        var value = try unary()
        while true {
            if take(42) { value *= try unary() }
            else if take(47) { let divisor = try unary(); guard divisor != 0 else { throw SearchMathError.domain }; value /= divisor }
            else {
                whitespace()
                if position + 2 <= bytes.count, Array(bytes[position..<position+2]) == [111, 102] { position += 2; value *= try unary() }
                else { return value }
            }
        }
    }
    mutating func unary() throws -> Double {
        try bump(); depth += 1; defer { depth -= 1 }; guard depth <= 32 else { throw SearchMathError.invalid }
        if take(43) { return try unary() }
        if take(45) { return try -unary() }
        var value = try atom()
        if take(94) { value = pow(value, try unary()) }
        while take(37) { value /= 100 }
        return value
    }
    mutating func atom() throws -> Double {
        if take(40) { let result = try expression(); guard take(41) else { throw SearchMathError.invalid }; return result }
        whitespace(); let start = position
        while position < bytes.count, (97...122).contains(bytes[position]) || position > start && (48...57).contains(bytes[position]) { position += 1 }
        if position > start {
            let name = String(decoding: bytes[start..<position], as: UTF8.self)
            if name == "pi" { return .pi }; if name == "e" { return exp(1) }
            let value: Double
            if take(40) { value = try expression(); guard take(41) else { throw SearchMathError.invalid } }
            else if name == "sqrt" { value = try unary() }
            else { throw SearchMathError.invalid }
            switch name {
            case "sqrt": guard value >= 0 else { throw SearchMathError.domain }; return value.squareRoot()
            case "abs": return abs(value)
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "ln": guard value > 0 else { throw SearchMathError.domain }; return log(value)
            case "log", "log10": guard value > 0 else { throw SearchMathError.domain }; return log10(value)
            default: throw SearchMathError.invalid
            }
        }
        while position < bytes.count, (48...57).contains(bytes[position]) || bytes[position] == 46 { position += 1 }
        if position < bytes.count, bytes[position] == 101 {
            position += 1
            if position < bytes.count, bytes[position] == 43 || bytes[position] == 45 { position += 1 }
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        }
        guard position > start, let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)) else { throw SearchMathError.invalid }
        return value
    }
}

public struct UnitConversion: Sendable, Equatable {
    public let value: Double
    public let target: String
    public let source: String
    private struct Unit { let group: Int; let factor: Double; let offset: Double; let symbol: String }
    private static let groups: [[(String, Double, String)]] = [
        [("m meter meters metre metres",1,"m"),("km kilometer kilometers kilometre kilometres",1000,"km"),("cm centimeter centimeters",0.01,"cm"),("mm millimeter millimeters",0.001,"mm"),("mi mile miles",1609.344,"mi"),("ft foot feet",0.3048,"ft"),("in inch inches",0.0254,"in"),("yd yard yards",0.9144,"yd")],
        [("kg kilogram kilograms",1,"kg"),("g gram grams",0.001,"g"),("mg milligram milligrams",0.000001,"mg"),("lb lbs pound pounds",0.45359237,"lb"),("oz ounce ounces",0.028349523125,"oz"),("st stone",6.35029318,"st")],
        [("l liter liters litre litres",1,"L"),("ml milliliter milliliters",0.001,"mL"),("gal gallon gallons usgal usgallon usgallons",3.785411784,"US gal"),("ukgal ukgallon ukgallons impgal impgallon impgallons",4.54609,"imp gal"),("cup cups",0.2365882365,"US cup")],
        [("s sec second seconds",1,"s"),("min minute minutes",60,"min"),("h hr hour hours",3600,"h"),("d day days",86400,"d")],
        [("b byte bytes",1,"B"),("kb kilobyte kilobytes",1000,"kB"),("mb megabyte megabytes",1e6,"MB"),("gb gigabyte gigabytes",1e9,"GB"),("tb terabyte terabytes",1e12,"TB"),("kib",1024,"KiB"),("mib",1048576,"MiB"),("gib",1073741824,"GiB")],
    ]
    private static func unit(_ text: String) -> Unit? {
        let text = text.lowercased().filter { $0 != "°" }
        for (group, values) in groups.enumerated() {
            for (names, factor, symbol) in values where names.split(separator: " ").contains(Substring(text)) { return Unit(group: group, factor: factor, offset: 0, symbol: symbol) }
        }
        switch text {
        case "c", "celsius": return Unit(group: 5, factor: 1, offset: 273.15, symbol: "°C")
        case "f", "fahrenheit": return Unit(group: 5, factor: 5.0/9, offset: 255.3722222222222, symbol: "°F")
        case "k", "kelvin": return Unit(group: 5, factor: 1, offset: 0, symbol: "K")
        default: return nil
        }
    }
    public init(_ text: String, region: SearchRegion = .invariant) throws {
        let parts = try ConversionQuery(text, region: region, unitOnly: true)
        guard let from = Self.unit(parts.from) else { throw SearchMathError.invalid }
        let defaultTarget: String
        switch (from.group, region.usesUSMeasurement) {
        case (0, true): defaultTarget = ["km", "mi"].contains(from.symbol) ? "mi" : ["cm", "mm", "in"].contains(from.symbol) ? "in" : "ft"
        case (0, false): defaultTarget = from.symbol == "mi" ? "km" : from.symbol == "in" ? "cm" : "m"
        case (1, true): defaultTarget = ["g", "mg", "oz"].contains(from.symbol) ? "oz" : "lb"
        case (1, false): defaultTarget = "kg"
        case (2, true): defaultTarget = "usgal"
        case (2, false): defaultTarget = "l"
        case (5, true): defaultTarget = "f"
        case (5, false): defaultTarget = "c"
        case (0, nil): defaultTarget = from.symbol == "mi" ? "km" : from.symbol == "in" ? "cm" : from.symbol == "m" ? "ft" : "m"
        case (1, nil): defaultTarget = from.symbol == "kg" ? "lb" : "kg"
        case (2, nil): defaultTarget = from.symbol == "L" ? "gal" : "l"
        case (3, _): defaultTarget = from.symbol == "h" ? "min" : "s"
        case (4, _): defaultTarget = "b"
        default: defaultTarget = from.symbol == "°C" ? "f" : "c"
        }
        guard let to = Self.unit(parts.to.isEmpty ? defaultTarget : parts.to), from.group == to.group else { throw SearchMathError.invalid }
        value = (parts.amount * from.factor + from.offset - to.offset) / to.factor
        guard value.isFinite else { throw SearchMathError.domain }
        target = to.symbol; source = SearchAnswers.number(parts.amount) + " " + from.symbol
    }
}

public struct ConversionQuery: Sendable, Equatable {
    public let amount: Double
    public let from: String
    public let to: String
    public init(amount:Double,from:String,to:String) { self.amount = amount; self.from = from; self.to = to }
    public init(_ text: String, region: SearchRegion = .invariant) throws {
        try self.init(text, region: region, unitOnly: false)
    }
    fileprivate init(_ text: String, region: SearchRegion, unitOnly: Bool) throws {
        guard text.utf8.count <= 1024 else { throw SearchMathError.invalid }
        var text = String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
        let symbols = ([region.currencySymbol.lowercased(), "$", "€", "£", "¥", "￥", "₽"])
            .filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let folded = text.lowercased()
        let prefix = symbols.first { folded.hasPrefix($0) }
        let symbol = prefix.flatMap { region.currencySymbolCode($0) }
        if let prefix {
            guard symbol != nil else { throw SearchMathError.invalid }
            text.removeFirst(prefix.count)
            text = String(text.drop(while: \.isWhitespace))
        }
        let characters = Array(text)
        let number = try region.numberPrefix(characters)
        guard let amount = Double(number.text), amount.isFinite else { throw SearchMathError.invalid }
        var words = String(characters[number.end...]).split(whereSeparator: \.isWhitespace).map(String.init)
        if unitOnly {
            // An explicit currency spelling wins over a colliding unit alias, such as CUP versus cup.
            guard symbol.flatMap(ReferenceRates.currency) == nil, words.allSatisfy({ word in
                region.currencySymbolCode(word).flatMap(ReferenceRates.currency) == nil
                    && !(word.utf8.count == 3
                    && word.utf8.allSatisfy { (65...90).contains($0) }
                    && ReferenceRates.currency(word) != nil)
            }) else { throw SearchMathError.invalid }
        }
        words = words.map { $0.lowercased() }
        var index = 0
        while index + 1 < words.count {
            if ["us", "uk", "imp", "imperial"].contains(words[index]),
                ["gal", "gallon", "gallons"].contains(words[index + 1]) {
                words[index] = (words[index] == "imperial" ? "imp" : words[index]) + "gal"
                words.remove(at: index + 1)
            }
            index += 1
        }
        words = words.map { region.currencySymbolCode($0) ?? $0 }
        if let symbol { words.insert(symbol,at:0) }
        if words.count == 3, ["to", "in"].contains(words[1]) { words.remove(at: 1) }
        guard (1...2).contains(words.count), words.allSatisfy({ word in
            !word.isEmpty && word.unicodeScalars.allSatisfy {
                (97...122).contains($0.value) || $0.value == 176
            }
        }) else { throw SearchMathError.invalid }
        self.amount = amount; from = words[0]; to = words.count == 2 ? words[1] : ""
    }
}
