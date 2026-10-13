// SPDX-License-Identifier: MIT
import SearchCore
import WinSDK
import WindowsDisplayABI

enum NativeSearchRates {
    /// The request contains no search text. It fetches only the public daily reference table.
    static func current() throws -> (ReferenceRates, cached: Bool) {
        let cache = try NativeFiles.path("search-rates.xml")
        let previous = try? ReferenceRates.parseCBR(NativeFiles.read(cache, maximum: 262144))
        var attributes = WIN32_FILE_ATTRIBUTE_DATA(), now = FILETIME()
        GetSystemTimeAsFileTime(&now)
        func ticks(_ time: FILETIME) -> UInt64 { UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime) }
        if let previous, withWideString(cache, { GetFileAttributesExW($0, GetFileExInfoStandard, &attributes) }),
            ticks(now) >= ticks(attributes.ftLastWriteTime), ticks(now) - ticks(attributes.ftLastWriteTime) < 6 * 3600 * 10_000_000 { return (previous, true) }
        do {
            let bytes = try fetch()
            let rates = try ReferenceRates.parseCBR(bytes)
            try NativeFiles.write(bytes, to: cache)
            return (rates, false)
        } catch { if let previous { return (previous, true) }; throw error }
    }
    private static func fetch() throws -> [UInt8] {
        guard let session = withWideString("SwiftyToys/" + AppVersion.string, { WinHttpOpen($0, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) }) else { throw WindowsError.api("Connect to reference rates", GetLastError()) }
        defer { WinHttpCloseHandle(session) }
        WinHttpSetTimeouts(session, 3000, 3000, 3000, 3000)
        guard let connection = withWideString("www.cbr.ru", { WinHttpConnect(session, $0, INTERNET_PORT(443), 0) }) else { throw WindowsError.api("Connect to Bank of Russia", GetLastError()) }
        defer { WinHttpCloseHandle(connection) }
        guard let request = withWideString("GET", { verb in withWideString("/scripts/XML_daily.asp", { WinHttpOpenRequest(connection, verb, $0, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) }) }) else { throw WindowsError.api("Request reference rates", GetLastError()) }
        defer { WinHttpCloseHandle(request) }
        var redirect = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
        guard WinHttpSetOption(request, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &redirect, DWORD(MemoryLayout<DWORD>.size)),
            WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0), WinHttpReceiveResponse(request, nil) else { throw WindowsError.api("Fetch reference rates", GetLastError()) }
        var status: DWORD = 0, size = DWORD(MemoryLayout<DWORD>.size)
        guard WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &status, &size, nil), status == 200 else { throw WindowsError.unsupported("Reference rates are unavailable. Retry when online.") }
        var bytes: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 8192)
        let deadline = GetTickCount64() + 6000
        while true {
            var count: DWORD = 0
            guard GetTickCount64() < deadline, WinHttpReadData(request, &chunk, DWORD(chunk.count), &count), bytes.count + Int(count) <= 262144 else { throw WindowsError.unsupported("Reference rates exceeded their time or size limit.") }
            if count == 0 { return bytes }; bytes += chunk.prefix(Int(count))
        }
    }
}
