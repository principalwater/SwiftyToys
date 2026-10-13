// SPDX-License-Identifier: MIT
import Testing
@testable import SearchCore

struct SearchTests {
    @Test func calculatorPrecedenceAndFunctions() throws {
        for (query, answer) in [("2+3*4",14.0),("(2+3)*4",20),("-2^2",-4),("2^3^2",512),("15% of 85",12.75),("√144",12),("sqrt(144)",12),("sin(pi/2)",1),("log10(100)",2),("1e3/4",250),("=5×3",15)] {
            #expect(abs(try SearchAnswers.calculate(query) - answer) < 1e-9)
        }
    }
    @Test func rejectsUnboundedOrInvalidMath() {
        for query in ["1/0", "sqrt(-1)", "ln(0)", "2^10000", "1;shutdown", "__import__(1)", "1+", "2(3)", String(repeating:"(",count:80)+"1"+String(repeating:")",count:80)] {
            #expect(throws: (any Error).self) { try SearchAnswers.calculate(query) }
        }
        #expect(SearchAnswers.quick("project notes") == nil)
        #expect(SearchAnswers.quick("report-2026") == nil)
    }
    @Test func unitGroupsAndTemperatureOffsets() throws {
        for (query, answer) in [("5 miles in km",8.04672),("32F in C",0),("273.15K to C",0),("1 lb kg",0.45359237),("1 GiB MB",1073.741824),("98.6°F in celsius",37)] {
            #expect(abs(try UnitConversion(query).value - answer) < 1e-8)
        }
        #expect(throws: (any Error).self) { try UnitConversion("3 kg km") }
        #expect(abs(try UnitConversion("1 in cm").value - 2.54) < 1e-8)
        #expect(SearchAnswers.quick("1 min to sec")?.value == "60 s")
        #expect(ReferenceRates.currency("min") == nil)
        #expect(ReferenceRates.currency("gal") == nil)
        #expect(SearchAnswers.quick("32F")?.value == "0 °C")
        #expect(try ConversionQuery("$120 in rub") == ConversionQuery(amount:120,from:"usd",to:"rub"))
    }
    @Test func ratesUsePublishedNominalAndDate() throws {
        let bytes = Array("<ValCurs Date=\"13.10.2026\"><Valute ID=\"USD\"><CharCode>USD</CharCode><Nominal>1</Nominal><Value>80,1234</Value></Valute><Valute ID=\"JPY\"><CharCode>JPY</CharCode><Nominal>100</Nominal><Value>52,3456</Value></Valute></ValCurs>".utf8)
        let rates = try ReferenceRates.parseCBR(bytes)
        #expect(abs((rates.rates["JPY"] ?? 0) - 0.523456) < 1e-12)
        let result = try rates.convert(ConversionQuery("120 usd rub"))
        #expect(result?.value == "9614.808 RUB")
        #expect(result?.detail.contains("13.10.2026") == true)
        #expect(try rates.convert(ConversionQuery("10 btc rub")) == nil)
        #expect(throws: (any Error).self) { try ReferenceRates.parseCBR(Array("<!DOCTYPE bad>".utf8)+bytes) }
        #expect(throws: (any Error).self) { try ReferenceRates(date:"13.50.2026",rates:["USD":80]) }
    }
    @Test func rankingAndWireHandleUnicodeAndHostileFields() throws {
        let first = SearchItem(id:"calc",title:"Calculator",subtitle:"Application",path:"shell:app",kind:"Application")
        let second = SearchItem(id:"note",title:"Калькулятор notes",subtitle:"line\nbreak",path:"C:\\Example\\tab\tname.txt",kind:"File")
        #expect(SearchRanking.results([second,first,first],query:"calc") == [first])
        #expect(SearchRanking.score("Visual Studio Code",query:"vsc") > 0)
        let encoded = try SearchWire.encode([first,second],status:"Ready")
        #expect(try SearchWire.decode(encoded).items == [first,second])
        #expect(throws: (any Error).self) { try SearchWire.decode(encoded+[0]) }
        #expect(throws: (any Error).self) { try SearchWire.decode(Array(encoded.dropLast())) }
        #expect(throws: (any Error).self) { try SearchWire.encode([SearchItem(id:"x",title:"\0",subtitle:"",path:"",kind:"")]) }
    }
}
