// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK

enum NativeSearchClock {
    private static let zones: [String:(key:String,city:String)] = [
        "london":("GMT Standard Time","London"),"paris":("Romance Standard Time","Paris"),
        "berlin":("W. Europe Standard Time","Berlin"),"rome":("W. Europe Standard Time","Rome"),
        "madrid":("Romance Standard Time","Madrid"),"moscow":("Russian Standard Time","Moscow"),
        "tokyo":("Tokyo Standard Time","Tokyo"),"japan":("Tokyo Standard Time","Japan"),
        "new york":("Eastern Standard Time","New York"),"los angeles":("Pacific Standard Time","Los Angeles"),
        "san francisco":("Pacific Standard Time","San Francisco"),"chicago":("Central Standard Time","Chicago"),
        "sydney":("AUS Eastern Standard Time","Sydney"),"singapore":("Singapore Standard Time","Singapore"),
        "dubai":("Arabian Standard Time","Dubai"),"delhi":("India Standard Time","Delhi"),
        "beijing":("China Standard Time","Beijing"),"hong kong":("China Standard Time","Hong Kong"),
        "toronto":("Eastern Standard Time","Toronto"),"seoul":("Korea Standard Time","Seoul"),
    ]
    static func quick(_ text: String) -> SearchAnswer? {
        let query = text.lowercased().trimmingWhitespace()
        let name: String
        if query.hasPrefix("time in ") { name = String(query.dropFirst(8)) }
        else if query.hasPrefix("time ") { name = String(query.dropFirst(5)) }
        else { return nil }
        var now = SYSTEMTIME(), local = SYSTEMTIME(); GetSystemTime(&now)
        var matched = false
        if name == "utc" { local = now; matched = true }
        else if let zone = zones[name] {
            for index in 0..<512 {
                var information = DYNAMIC_TIME_ZONE_INFORMATION()
                let result = EnumDynamicTimeZoneInformation(DWORD(index),&information)
                if result == DWORD(ERROR_NO_MORE_ITEMS) { break }
                if result != 0 { return nil }
                let key = withUnsafePointer(to:&information.TimeZoneKeyName) { $0.withMemoryRebound(to:WCHAR.self,capacity:128) {
                    String(decoding:UnsafeBufferPointer(start:$0,count:128).prefix(while:{$0 != 0}),as:UTF16.self)
                } }
                if key == zone.key { matched = SystemTimeToTzSpecificLocalTimeEx(&information,&now,&local); break }
            }
        }
        guard matched else { return nil }
        let hour = String(local.wHour), minute = String(local.wMinute), date = String(local.wYear)+"-"+String(local.wMonth)+"-"+String(local.wDay)
        return SearchAnswer(title:"World clock",value:(hour.count == 1 ? "0" : "") + hour + ":" + (minute.count == 1 ? "0" : "") + minute,
            detail:(zones[name]?.city ?? "UTC") + " · " + date + " · Windows time-zone rules")
    }
}
