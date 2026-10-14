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
        NativeSearchLibraryActivity.touch()
        try prepare()
        guard let panel, let window = panel.window else { return }
        if IsWindowVisible(window) { panel.hide() } else { try panel.show() }
    }
    /// Creates the panel on its owning UI thread without showing it or starting a query.
    @discardableResult func prepare() throws -> HWND? {
        if panel == nil {
            panel = try NativeSearchWindow(onQuery: { [weak self] query in
                guard let self, let panel = self.panel else { return }
                NativeSearchLibraryActivity.setVisible(panel.window.map { IsWindowVisible($0) } ?? false)
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
                NativeSearchLibraryActivity.setVisible(false)
                guard let self, let panel = self.panel else { return }; self.service?.invalidate(generation:panel.generation)
            }, onReveal: { [weak self] id in self?.reveal(id) })
        }
        panel?.prepareMaterial()
        return panel?.window
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
    func stop() { NativeSearchLibraryActivity.setVisible(false); service?.stop(); service = nil; panel = nil }
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
        NativeSearchLibraryActivity.touch()
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
                    var text = NativeSearchFiles.preview(request.0)
                    if request.0.id.hasPrefix("library-fragment:"),
                        let store = try? NativeSearchLibraryStore(databasePath: NativeSearchLibraryStore.databasePath(), readOnly: true),
                        let fragment = try? store.fragment(itemID: request.0.id) {
                        text = fragment.location + "\r\n\r\n" + fragment.text + "\r\n\r\n" + request.0.path
                    }
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
    private static let actions = SearchCommands.items
    private func publish(_ query: Query, items: [SearchItem], answer: SearchAnswer?, status: String) {
        guard !cancelled(query.generation) else { return }
        let parsed = SearchQuery(query.text)
        var results = Array(items.filter { $0.id.utf16.count <= 4096 && parsed.accepts($0) }
            .prefix(parsed.text.isEmpty ? 32 : 31))
        if parsed.isValid, parsed.category == .all, !parsed.text.isEmpty {
            let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8), hex = Array("0123456789ABCDEF".utf8)
            let encoded = parsed.text.utf8.flatMap { byte -> [UInt8] in allowed.contains(byte) ? [byte] : [37,hex[Int(byte >> 4)],hex[Int(byte & 15)]] }
            let web = SearchItem(id:"web",title:"Search the web",subtitle:parsed.text,path:"https://www.google.com/search?q=" + String(decoding:encoded,as:UTF8.self),kind:"Website")
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
        var ratesPair = ""
        while !cancelled() {
            _ = WaitForSingleObject(event.raw, DWORD(INFINITE))
            if cancelled() { return }
            // Coalesce rapid typing without a polling timer while idle.
            while WaitForSingleObject(event.raw, 90) == DWORD(WAIT_OBJECT_0), !cancelled() {}
            let job = state.withLock { state in let value = state.query; state.query = nil; return value }
            guard let query = job, !cancelled(query.generation) else { continue }
            let parsed = SearchQuery(query.text)
            guard parsed.isValid else {
                publish(query, items: [], answer: nil,
                    status: "Invalid filter. Use files: kind:pdf or files: ext:pdf before your search.")
                continue
            }
            let term = parsed.text
            let alias = parsed.category == .all || parsed.category == .actions
                ? query.preferences.quickKeys.match(term) : nil
            let actions = parsed.category == .all || parsed.category == .actions
                ? alias.map { [$0] } ?? SearchRanking.results(Self.actions, query: term, limit: 9) : []
            if parsed.category == .actions || alias != nil {
                publish(query, items: actions, answer: nil,
                    status: alias == nil ? "Actions · Enter to run" : "Quick Key · Enter to run")
                continue
            }
            if parsed.category == .applications {
                publish(query, items: SearchRanking.results(recent.filter(parsed.accepts), query: term),
                    answer: nil, status: "Searching applications…")
                do {
                    let apps = try NativeSearchProcess.applications(term,
                        cancelled: { self.cancelled(query.generation) })
                    recent = apps
                    publish(query, items: apps, answer: nil, status: "Applications")
                } catch {
                    publish(query, items: [], answer: nil, status: "Applications are unavailable. Retry Search.")
                }
                continue
            }
            let region = parsed.category == .all ? NativeSearchRegion.current() : nil
            var answer: SearchAnswer?
            if let region {
                answer = SearchAnswers.quick(term, region: region.region)
                    .map { NativeSearchRegion.format($0, context: region) }
                    ?? NativeSearchClock.quick(term, localeName: region.localeName)
            }
            publish(query,items:actions + SearchRanking.results(recent.filter(parsed.accepts),query:term),answer:answer,status:"Searching…")
            if let region, answer == nil,
                let conversion = NativeSearchRegion.currencyQuery(term, context: region) {
                var status = "Currency reference rates"
                do {
                    guard !conversion.to.isEmpty else {
                        throw WindowsError.unsupported("Windows has no regional currency for this location. Specify a target, such as 120 USD EUR.")
                    }
                    if conversion.from == conversion.to {
                        answer = NativeSearchRegion.format(SearchAnswer(title: "Currency conversion",
                            value: SearchAnswers.number(conversion.amount) + " " + conversion.to,
                            detail: "Same currency · " + conversion.to), context: region)
                        status = "Quick result"
                    } else {
                        let pair = conversion.from + "/" + conversion.to
                        if rates == nil || ratesPair != pair || GetTickCount64() - ratesAt > 20 * 60 * 1000 {
                            rates = try NativeSearchProcess.rates(from: conversion.from, to: conversion.to,
                                cancelled: { self.cancelled(query.generation) })
                            ratesPair = pair; ratesAt = GetTickCount64()
                        }
                        if let rates, let converted = rates.0.convert(conversion, cached: rates.cached) {
                            answer = NativeSearchRegion.format(converted, context: region)
                            status += rates.cached ? " · cached reference rates" : " · reference rates"
                        } else { status = "This currency pair is not available in the reference feed." }
                    }
                } catch WindowsError.unsupported(let reason) { status = reason }
                catch { status = "Currency rates are unavailable. Connect to the internet and retry." }
                publish(query,items:actions,answer:answer,status:status)
                continue
            }
            if answer != nil, Double(term) == nil { publish(query,items:actions,answer:answer,status:"Quick result"); continue }
            if GetTickCount64() - filesAt > 15000 || filesAt == 0 {
                let roots = [FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_Downloads].compactMap { try? NativeSearchFiles.knownFolder($0) }
                let collected = NativeSearchFiles.collect(roots:roots,cancelled:{ self.cancelled(query.generation) })
                guard !cancelled(query.generation) else { continue }
                files = collected; filesAt = GetTickCount64()
            }
            var results = actions + SearchRanking.results(files.filter(parsed.accepts),query:term,limit:24)
            publish(query,items:results,answer:answer,status:"Local filenames")
            var libraryStatus = "Local library"
            if let indexed = try? NativeSearchProcess.library(parsed.libraryQuery, cancelled: { self.cancelled(query.generation) }) {
                var seen = Set<String>()
                let libraryItems = indexed.items.filter { parsed.accepts($0) && query.preferences.permitsLibraryPath($0.path) }
                results = (actions + libraryItems + results).filter { seen.insert(($0.path.isEmpty ? $0.id : $0.path).lowercased()).inserted }
                libraryStatus = indexed.status
                publish(query,items:results,answer:answer,status:indexed.status)
            }
            var status = parsed.category == .files ? libraryStatus : "Apps and files"
            if answer == nil, parsed.category == .all {
                if let apps = try? NativeSearchProcess.applications(term,cancelled:{ self.cancelled(query.generation) }) {
                    recent = apps
                    results = actions + apps + results.filter { $0.kind != "Action" }
                    publish(query,items:results,answer:answer,status:"Apps and local files")
                }
            }
            guard !cancelled(query.generation) else { continue }
            do {
                let indexed = try NativeSearchProcess.query(parsed.libraryQuery, cancelled: { self.cancelled(query.generation) })
                var seen = Set<String>()
                results = (actions + indexed.items.filter(parsed.accepts) + results).filter { seen.insert(($0.path.isEmpty ? $0.id : $0.path).lowercased()).inserted }
                recent += indexed.items; recent = Array(recent.prefix(64)); status = indexed.status
            } catch { status = "Windows Index unavailable · local filenames and apps" }
            guard !cancelled(query.generation) else { continue }
            publish(query,items:results,answer:answer,status:status)
            if answer == nil, query.preferences.semantic, !term.isEmpty, !cancelled(query.generation) {
                do {
                    let model = try NativeSearchModelCatalog.descriptor(repositoryID: query.preferences.modelRepository)
                    let semanticText = term
                    guard !semanticText.isEmpty else { continue }
                    publish(query,items:results,answer:answer,status:status + " · searching the local library by meaning…")
                    let vector = try NativeEmbedding.queryVector(semanticText, model: model, cancelled: { self.cancelled(query.generation) })
                    let semantic = try NativeSearchProcess.library(parsed.libraryQuery,
                        namespace: NativeSearchLibraryRuntime.namespace(preferences: query.preferences, model: model),
                        vector: vector, cancelled: { self.cancelled(query.generation) })
                    var seen = Set<String>()
                    let libraryItems = semantic.items.filter { parsed.accepts($0) && query.preferences.permitsLibraryPath($0.path) }
                    results = (actions + libraryItems + results).filter { seen.insert(($0.path.isEmpty ? $0.id : $0.path).lowercased()).inserted }
                    publish(query,items:results,answer:answer,status:semantic.status + (semantic.items.isEmpty
                        ? " · no saved semantic matches; check Index status" : " · semantic matches"))
                } catch {
                    let detail: String
                    if case WindowsError.unsupported(let message) = error { detail = String(message.prefix(240)) }
                    else { detail = "Semantic search is unavailable; check the optional model and Index status in settings." }
                    publish(query,items:results,answer:answer,status:status + " · " + detail)
                }
            }
        }
    }
}
