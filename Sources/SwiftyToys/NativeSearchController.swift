// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import Synchronization
import WinSDK

/// UI ownership ends here. The service receives only Sendable queries, preferences and result deliveries.
final class NativeSearchController {
    private var panel: NativeSearchWindow?
    private var service: NativeSearchService?
    var preferences: SearchPreferences
    private let action: (String) throws -> Void
    init(preferences: SearchPreferences, action: @escaping (String) throws -> Void) {
        self.preferences = preferences; self.action = action
    }
    func toggle() throws {
        if panel == nil {
            panel = try NativeSearchWindow(onQuery: { [weak self] query in
                guard let self, let panel = self.panel else { return }
                if query.allSatisfy(\.isWhitespace) {
                    self.service?.invalidate(generation:panel.generation)
                    _ = panel.delivery.post(NativeSearchSnapshot(generation:panel.generation,results:[],
                        status:"Search apps, files, or calculate",quickAnswer:nil))
                    return
                }
                do {
                    if self.service == nil { self.service = try NativeSearchService(delivery: panel.delivery) }
                    self.service?.submit(query: query, generation: panel.generation, preferences: self.preferences)
                } catch { _ = panel.delivery.post(NativeSearchSnapshot(generation: panel.generation, results: [], status: "Search could not start. Retry after closing unused applications.", quickAnswer: nil)) }
            }, onActivate: { [weak self] id in self?.activate(id) }, onPreview: { [weak self] id in
                guard let self, let panel = self.panel else { return }; self.service?.preview(id: id, generation: panel.generation)
            }, onCopy: { [weak self] id in self?.copy(id) }, onDismiss: { [weak self] in
                guard let self, let panel = self.panel else { return }; self.service?.invalidate(generation:panel.generation)
            }, onReveal: { [weak self] id in self?.reveal(id) })
        }
        guard let panel, let window = panel.window else { return }
        if IsWindowVisible(window) { panel.hide() } else { try panel.show() }
    }
    func dialogMessage(_ message: inout MSG) -> Bool { panel?.dialogMessage(&message) ?? false }
    private func activate(_ id: String) {
        do {
            if id == "answer" { try clipboard(service?.answer ?? ""); return }
            if id.hasPrefix("action:") { try action(String(id.dropFirst(7))); return }
            guard let item = service?.item(id), !item.path.isEmpty else { return }
            if item.path.hasPrefix("shell:AppsFolder\\") || ["Application","File","Folder","Website"].contains(item.kind) { try shellOpen(item.path) }
        } catch { report(error) }
    }
    private func copy(_ id: String) {
        do {
            let item = service?.item(id)
            try clipboard(id == "answer" ? service?.answer ?? "" : item?.kind == "Action" ? item?.title ?? "" : item?.path ?? "")
        } catch { report(error) }
    }
    private func reveal(_ id:String) {
        do {
            guard let item = service?.item(id), !item.path.isEmpty else { throw WindowsError.unsupported("This result has no file location.") }
            if item.path.hasPrefix("shell:AppsFolder\\") { try shellOpen("shell:AppsFolder"); return }
            guard ["File","Folder","Application"].contains(item.kind) else { throw WindowsError.unsupported("This result has no file location.") }
            let initialized = CoInitializeEx(nil,DWORD(COINIT_APARTMENTTHREADED.rawValue))
            guard initialized >= 0 || initialized == HRESULT(bitPattern:0x80010106) else { throw WindowsError.status("Initialize file reveal",initialized) }
            defer { if initialized >= 0 { CoUninitialize() } }
            var identifier: UnsafeMutablePointer<ITEMIDLIST>?
            let parsed = withWideString(item.path) { SHParseDisplayName($0,nil,&identifier,0,nil) }
            guard parsed >= 0, let identifier else { throw WindowsError.status("Locate search result",parsed) }
            defer { CoTaskMemFree(identifier) }
            let result = SHOpenFolderAndSelectItems(identifier,0,nil,0)
            guard result >= 0 else { throw WindowsError.status("Reveal search result",result) }
        } catch { report(error) }
    }
    private func report(_ error: any Error) {
        let text = "The search action could not complete.\n\n" + String(describing: error)
        _ = withWideString(text) { text in withWideString("SwiftyToys Search") { MessageBoxW(panel?.window, text, $0, UINT(MB_OK | MB_ICONERROR)) } }
    }
    private func clipboard(_ text: String) throws {
        guard !text.isEmpty, text.utf16.count < 32768, !text.utf16.contains(0) else { throw WindowsError.unsupported("There is no result to copy.") }
        let bytes = Array(text.utf16) + [0]
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes.count * 2)) else { throw WindowsError.api("Allocate clipboard result", GetLastError()) }
        var transferred = false
        defer { if !transferred { GlobalFree(memory) } }
        guard let destination = GlobalLock(memory) else { throw WindowsError.api("Prepare clipboard result", GetLastError()) }
        bytes.withUnsafeBufferPointer { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count * 2) }; GlobalUnlock(memory)
        guard OpenClipboard(panel?.window) else { throw WindowsError.unsupported("The clipboard is busy. Retry Copy.") }
        defer { CloseClipboard() }
        guard EmptyClipboard(), SetClipboardData(UINT(CF_UNICODETEXT), memory) != nil else { throw WindowsError.api("Copy search result", GetLastError()) }
        transferred = true
    }
    func stop() { service?.stop(); service = nil; panel = nil }
    deinit { stop() }
}

private final class NativeSearchService: @unchecked Sendable {
    private struct Query: Sendable { let text: String; let generation: UInt64; let preferences: SearchPreferences }
    private struct State: Sendable {
        var stopped = false
        var generation: UInt64 = 0
        var query: Query?
        var preview: (id: String, generation: UInt64)?
        var previewBusy = false
        var items: [String: SearchItem] = [:]
        var answer: String?
    }
    private let state = Mutex(State())
    private let event: OwnedHandle
    private let delivery: NativeSearchDelivery
    var answer: String? { state.withLock { $0.answer } }
    init(delivery: NativeSearchDelivery) throws {
        self.delivery = delivery
        event = try OwnedHandle(CreateEventW(nil, false, false, nil))
        _ = try NativeThread(name: "SwiftyToys Search") { self.run() }
    }
    func submit(query: String, generation: UInt64, preferences: SearchPreferences) {
        state.withLock { $0.generation = generation; $0.query = Query(text: query, generation: generation, preferences: preferences); $0.preview = nil; $0.items = [:]; $0.answer = nil }
        SetEvent(event.raw)
    }
    func item(_ id: String) -> SearchItem? { state.withLock { $0.items[id] } }
    func invalidate(generation:UInt64) { state.withLock { $0.generation = generation; $0.query = nil; $0.preview = nil; $0.items = [:]; $0.answer = nil }; SetEvent(event.raw) }
    func preview(id: String, generation: UInt64) {
        let start = state.withLock { state -> Bool in
            guard !state.stopped, generation == state.generation else { return false }
            state.preview = (id,generation)
            if state.previewBusy { return false }; state.previewBusy = true; return true
        }
        guard start else { return }
        do {
            _ = try NativeThread(name:"SwiftyToys Search preview") {
                while let request = self.state.withLock({ state -> (SearchItem,UInt64)? in
                    guard !state.stopped, let pending = state.preview, pending.generation == state.generation,
                        let item = state.items[pending.id] else { state.previewBusy = false; state.preview = nil; return nil }
                    state.preview = nil; return (item,pending.generation)
                }) {
                    let text = NativeSearchFiles.preview(request.0)
                    if !self.cancelled(request.1) { _ = self.delivery.postPreview(generation:request.1,resultID:request.0.id,title:request.0.title,text:text) }
                }
            }
        } catch {
            state.withLock { $0.previewBusy = false; $0.preview = nil }
            _ = delivery.postPreview(generation:generation,resultID:id,title:"Preview unavailable",text:"The preview could not start. Close unused applications and retry.")
        }
    }
    func stop() { state.withLock { $0.stopped = true; $0.query = nil }; SetEvent(event.raw) }
    private func cancelled(_ generation: UInt64? = nil) -> Bool { state.withLock { state in state.stopped || (generation.map { $0 != state.generation } ?? false) } }
    private static let actions: [SearchItem] = [
        SearchItem(id:"action:settings",title:"SwiftyToys Settings",subtitle:"Open the tool overview",path:"",kind:"Action"),
        SearchItem(id:"action:windows-settings",title:"Windows Settings",subtitle:"Configure Windows",path:"",kind:"Action"),
        SearchItem(id:"action:calculator",title:"Calculator",subtitle:"Open Windows Calculator",path:"",kind:"Action"),
        SearchItem(id:"action:explorer",title:"File Explorer",subtitle:"Browse files and folders",path:"",kind:"Action"),
        SearchItem(id:"action:lock",title:"Lock screen",subtitle:"Lock this Windows session",path:"",kind:"Action"),
        SearchItem(id:"action:sleep",title:"Sleep",subtitle:"Put this computer to sleep",path:"",kind:"Action"),
        SearchItem(id:"action:bluetooth",title:"Bluetooth settings",subtitle:"Manage paired devices",path:"",kind:"Action"),
        SearchItem(id:"action:sound",title:"Sound settings",subtitle:"Choose audio devices",path:"",kind:"Action"),
        SearchItem(id:"action:display",title:"Display settings",subtitle:"Resolution and display options",path:"",kind:"Action"),
    ]
    private static func currencyQuery(_ text:String) -> ConversionQuery? {
        guard let parsed = try? ConversionQuery(text), ReferenceRates.currency(parsed.from) != nil,
            parsed.to.isEmpty || ReferenceRates.currency(parsed.to) != nil else { return nil }
        if !parsed.to.isEmpty { return parsed }
        var home = [WCHAR](repeating:0,count:8)
        let count = GetLocaleInfoEx(nil,DWORD(LOCALE_SINTLSYMBOL),&home,Int32(home.count))
        let localCurrency = count > 1 ? String(decoding:home.prefix(Int(count)-1),as:UTF16.self) : "USD"
        let target = ReferenceRates.currency(localCurrency) ?? "USD"
        return ConversionQuery(amount:parsed.amount,from:parsed.from,to:ReferenceRates.currency(parsed.from) == target ? (target == "USD" ? "EUR" : "USD") : target)
    }
    private func publish(_ query: Query, items: [SearchItem], answer: SearchAnswer?, status: String) {
        guard !cancelled(query.generation) else { return }
        var results = Array(items.filter { $0.id.utf16.count <= 4096 }.prefix(query.text.isEmpty ? 32 : 31))
        if !query.text.isEmpty {
            let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8), hex = Array("0123456789ABCDEF".utf8)
            let encoded = query.text.utf8.flatMap { byte -> [UInt8] in allowed.contains(byte) ? [byte] : [37,hex[Int(byte >> 4)],hex[Int(byte & 15)]] }
            let web = SearchItem(id:"web",title:"Search the web",subtitle:query.text,path:"https://www.google.com/search?q=" + String(decoding:encoded,as:UTF8.self),kind:"Website")
            results.append(web)
        }
        if let answer { results.insert(SearchItem(id:"answer",title:answer.value,subtitle:answer.detail,path:"",kind:answer.title),at:0) }
        state.withLock { state in
            guard state.generation == query.generation else { return }
            state.items.merge(Dictionary(results.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })) { _,new in new }; state.answer = answer?.value
        }
        _ = delivery.post(NativeSearchSnapshot(generation: query.generation, results: results.map { NativeSearchResult(id:$0.id,title:String(decoding:$0.title.utf16.prefix(4096),as:UTF16.self),subtitle:String(decoding:$0.subtitle.utf16.prefix(4096),as:UTF16.self),kind:$0.kind) },status:status,quickAnswer:answer?.value))
    }
    private func run() {
        _ = SetThreadPriority(GetCurrentThread(), Int32(-1)) // Documented THREAD_PRIORITY_BELOW_NORMAL; the SDK macro is not imported.
        var files: [SearchItem] = [], filesAt: UInt64 = 0, recent: [SearchItem] = []
        var rates: (ReferenceRates, cached: Bool)?
        var ratesAt: UInt64 = 0
        while !cancelled() {
            _ = WaitForSingleObject(event.raw, DWORD(INFINITE))
            if cancelled() { return }
            // Coalesce rapid typing without a polling timer while idle.
            while WaitForSingleObject(event.raw, 90) == DWORD(WAIT_OBJECT_0), !cancelled() {}
            let job = state.withLock { state in let value = state.query; state.query = nil; return value }
            guard let query = job, !cancelled(query.generation) else { continue }
            var answer = SearchAnswers.quick(query.text) ?? NativeSearchClock.quick(query.text)
            let actions = SearchRanking.results(Self.actions, query: query.text, limit: 6)
            publish(query,items:actions + SearchRanking.results(recent,query:query.text),answer:answer,status:"Searching…")
            if answer == nil, let conversion = Self.currencyQuery(query.text) {
                var status = "Currency reference rates"
                do {
                    if rates == nil || GetTickCount64() - ratesAt > 20 * 60 * 1000 { rates = try NativeSearchProcess.rates(cancelled:{ self.cancelled(query.generation) }); ratesAt = GetTickCount64() }
                    if let rates, let converted = rates.0.convert(conversion) { answer = converted; status += rates.cached ? " · cached reference rates" : " · reference rates" }
                    else { status = "This currency is not available in the reference table." }
                } catch { status = "Currency rates are unavailable. Connect to the internet and retry." }
                publish(query,items:actions,answer:answer,status:status)
                continue
            }
            if answer != nil, Double(query.text) == nil { publish(query,items:actions,answer:answer,status:"Quick result"); continue }
            if GetTickCount64() - filesAt > 15000 || filesAt == 0 {
                let roots = [FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_Downloads].compactMap { try? NativeSearchFiles.knownFolder($0) }
                let collected = NativeSearchFiles.collect(roots:roots,cancelled:{ self.cancelled(query.generation) })
                guard !cancelled(query.generation) else { continue }
                files = collected; filesAt = GetTickCount64()
            }
            var results = actions + SearchRanking.results(files,query:query.text,limit:24)
            publish(query,items:results,answer:answer,status:"Local filenames")
            var status = "Apps and files"
            if answer == nil {
                if let apps = try? NativeSearchProcess.applications(query.text,cancelled:{ self.cancelled(query.generation) }) {
                    recent = apps
                    results = actions + apps + results.filter { $0.kind != "Action" }
                    publish(query,items:results,answer:answer,status:"Apps and local files")
                }
            }
            do {
                let indexed = try NativeSearchProcess.query(query.text, cancelled: { self.cancelled(query.generation) })
                var seen = Set<String>()
                results = (actions + indexed.items + results).filter { seen.insert(($0.path.isEmpty ? $0.id : $0.path).lowercased()).inserted }
                recent += indexed.items; recent = Array(recent.prefix(64)); status = indexed.status
            } catch { status = "Windows Index unavailable · local filenames and apps" }
            guard !cancelled(query.generation) else { continue }
            publish(query,items:results,answer:answer,status:status)
            if answer == nil, query.preferences.semantic, !query.text.isEmpty, !cancelled(query.generation) {
                do {
                    let candidates = NativeSearchFiles.collect(roots:[query.preferences.folder],maximum:64,textOnly:true,cancelled:{ self.cancelled(query.generation) })
                    let sorted = candidates.sorted { SearchRanking.score($0.title,query:query.text) > SearchRanking.score($1.title,query:query.text) }
                    let documents = sorted.prefix(64).compactMap { item -> NativeEmbeddingDocument? in
                        guard let bytes = try? NativeSearchFiles.readSnippet(item.path,maximum:4096), let text = NativeSearchFiles.decodeSnippet(bytes), !text.isEmpty else { return nil }
                        return NativeEmbeddingDocument(id:item.id,title:item.title,text:text)
                    }
                    guard !documents.isEmpty else { publish(query,items:results,answer:answer,status:status + " · no local plain-text files in the semantic folder"); continue }
                    publish(query,items:results,answer:answer,status:status + " · searching by meaning…")
                    var matches: [NativeEmbeddingMatch] = []
                    let lexical = results
                    for start in stride(from:0,to:documents.count,by:4) {
                        guard !cancelled(query.generation) else { break }
                        matches += try NativeEmbedding.rank(query:query.text,documents:Array(documents[start..<min(start+4,documents.count)]),cancelled:{ self.cancelled(query.generation) })
                        let meaningful = matches.filter { $0.score.isFinite }.sorted { $0.score > $1.score }.prefix(12).compactMap { match in candidates.first { $0.id == match.id } }
                        var seen = Set<String>()
                        results = (actions + meaningful + lexical).filter { seen.insert(($0.path.isEmpty ? $0.id : $0.path).lowercased()).inserted }
                        publish(query,items:results,answer:answer,status:status + " · local semantic results · " + String(min(start+4,documents.count)) + " / " + String(documents.count))
                    }
                } catch { publish(query,items:results,answer:answer,status:status + " · semantic search unavailable; check the optional model in settings") }
            }
        }
    }
}
