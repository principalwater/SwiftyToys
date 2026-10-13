// SPDX-License-Identifier: MIT
import Synchronization
import WinSDK
import WindowsDisplayABI

struct NativeSearchResult: Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    var accessibleText: String { "\(title). \(kind). \(subtitle)" }
}
struct NativeSearchSnapshot: Sendable {
    let generation: UInt64
    let results: [NativeSearchResult]
    let status: String
    let quickAnswer: String?
    fileprivate var isValid: Bool {
        func valid(_ text: String) -> Bool { text.utf16.count <= 4096 && !text.utf16.contains(0) }
        return results.count <= 64 && Set(results.map(\.id)).count == results.count &&
            results.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && [$0.id,$0.title,$0.subtitle,$0.kind].allSatisfy(valid) }) &&
            valid(status) && (quickAnswer.map(valid) ?? true)
    }
}
private struct NativeSearchPreview: Sendable {
    let generation: UInt64
    let resultID: String
    let title: String
    let text: String
}
private let searchSnapshotMessage: UINT = 0x8057
private let searchClientObject: LONG = -4 // OBJID_CLIENT: the SDK macro's unsigned literal overflows Swift's LONG importer.

/// Producers share values, never the UI object. The owner closes delivery before destroying its HWND.
final class NativeSearchDelivery: Sendable {
    private let state = Mutex((open: true, queued: false, pending: Optional<NativeSearchSnapshot>.none,
        preview: Optional<NativeSearchPreview>.none, requested: Optional<(UInt64,String)>.none))
    private let destination: MessageDestination
    fileprivate init(_ window: HWND) { destination = MessageDestination(window) }
    @discardableResult func post(_ snapshot: NativeSearchSnapshot) -> Bool {
        guard snapshot.isValid else { return false }
        return state.withLock { state in
            guard state.open, state.pending.map({ $0.generation <= snapshot.generation }) ?? true else { return false }
            state.pending = snapshot
            if state.queued { return true }
            state.queued = destination.post(searchSnapshotMessage); return state.queued
        }
    }
    @discardableResult func postPreview(generation: UInt64, resultID: String, title: String, text: String) -> Bool {
        guard !resultID.isEmpty, [resultID,title,text].allSatisfy({ $0.utf16.count <= 4096 && !$0.utf16.contains(0) }) else { return false }
        return state.withLock { state in
            guard state.open, let requested=state.requested, requested.0==generation, requested.1==resultID else { return false }
            state.preview=NativeSearchPreview(generation:generation,resultID:resultID,title:title,text:text)
            if state.queued { return true }
            state.queued = destination.post(searchSnapshotMessage); return state.queued
        }
    }
    fileprivate func expectPreview(generation: UInt64, resultID: String) { state.withLock { $0.requested=(generation,resultID); $0.preview=nil } }
    fileprivate func cancelPreview() { state.withLock { $0.requested=nil; $0.preview=nil } }
    fileprivate func take() -> (snapshot: NativeSearchSnapshot?, preview: NativeSearchPreview?) {
        state.withLock { state in let value=(state.pending,state.preview); state.pending=nil; state.preview=nil; state.queued=false; return value }
    }
    fileprivate func close() { state.withLock { $0.open=false; $0.queued=false; $0.pending=nil; $0.preview=nil; $0.requested=nil } }
}
private func searchProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window else { return DefWindowProcW(window, message, value, data) }
    if message == UINT(WM_NCCREATE), let creation = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(data)), let owner = creation.pointee.lpCreateParams {
        SetWindowLongPtrW(window, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: owner)))
    }
    if let owner = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(window, Int32(GWLP_USERDATA)))) {
        let result = Unmanaged<NativeSearchWindow>.fromOpaque(owner).takeUnretainedValue().handle(window, message, value, data)
        if message == UINT(WM_NCDESTROY) { SetWindowLongPtrW(window, Int32(GWLP_USERDATA), 0) }
        return result
    }
    return DefWindowProcW(window, message, value, data)
}
private func searchEditProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM, _ id: UINT_PTR, _ context: DWORD_PTR) -> LRESULT {
    guard let window, let pointer = UnsafeRawPointer(bitPattern:UInt(context)) else { return DefSubclassProc(window,message,value,data) }
    let owner = Unmanaged<NativeSearchWindow>.fromOpaque(pointer).takeUnretainedValue()
    if message == UINT(WM_IME_STARTCOMPOSITION) { owner.compositionChanged(true) }
    let result = DefSubclassProc(window,message,value,data)
    if message == UINT(WM_IME_ENDCOMPOSITION) { owner.compositionChanged(false) }
    if message == UINT(WM_NCDESTROY) { RemoveWindowSubclass(window,searchEditProcedure,id) }
    return result
}

/// UI-thread owned. Callbacks enqueue work; snapshots contain no file/model access.
final class NativeSearchWindow {
    private(set) var window: HWND?
    private(set) var generation: UInt64 = 0
    private var producer: NativeSearchDelivery?
    var delivery: NativeSearchDelivery { producer! }
    private let uiThread = GetCurrentThreadId()
    private let onQuery: (String) -> Void
    private let onActivate: (String) -> Void
    private let onPreview: (String) -> Void
    private let onCopy: (String) -> Void
    private let onDismiss: () -> Void
    private let onReveal: (String) -> Void
    private let localization: Localization
    private var controls: [Int: HWND] = [:]
    private var fonts: [HFONT] = []
    private var brushes: [HBRUSH] = []
    private var brand: ApplicationIcon?
    private var caption: ApplicationIcon?
    private var results: [NativeSearchResult] = []
    private var changingQuery = false
    private var composing = false
    private var dismissing = false
    private var previewID: String?
    private var highContrast = false
    private var scale: Double { window.map { Double(GetDpiForWindow($0)) / 96 } ?? 1 }
    private var textColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOWTEXT)) : 0x002D_2525 }
    private var secondaryColor: COLORREF { highContrast ? textColor : 0x006E_6162 }
    private var backgroundColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00F9_F7F7 }
    private var surfaceColor: COLORREF { highContrast ? backgroundColor : 0x00FF_FFFF }
    private var selectedColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_HIGHLIGHT)) : 0x00EF_F2FE }
    private var borderColor: COLORREF { highContrast ? textColor : 0x00E8_E3E2 }

    init(localization: Localization = Localization(), onQuery: @escaping (String) -> Void, onActivate: @escaping (String) -> Void,
        onPreview: @escaping (String) -> Void, onCopy: @escaping (String) -> Void, onDismiss: @escaping () -> Void = {}, onReveal: @escaping (String) -> Void = { _ in }) throws {
        self.onQuery = onQuery; self.onActivate = onActivate; self.onPreview = onPreview; self.onCopy = onCopy; self.onDismiss=onDismiss; self.onReveal=onReveal; self.localization = localization
        var type = WNDCLASSEXW(); type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = searchProcedure; type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        // Windows owns this optional short-lived-window shadow; no captured desktop or blur surface.
        type.style = UINT(CS_DROPSHADOW)
        let registered = withWideString("SwiftyToys.NativeSearch") { type.lpszClassName = $0; return RegisterClassExW(&type) }
        guard registered != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS) else { throw WindowsError.api("Register search panel", GetLastError()) }
        window = withWideString("SwiftyToys.NativeSearch") { name in withWideString(localization.text("SwiftyToys Search")) {
            CreateWindowExW(DWORD(WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT), name, $0, DWORD(WS_POPUP) | DWORD(WS_THICKFRAME | WS_CLIPCHILDREN),
                0, 0, 760, 468, nil, nil, GetModuleHandleW(nil), Unmanaged.passUnretained(self).toOpaque())
        } }
        guard let window else { throw WindowsError.api("Create search panel", GetLastError()) }
        producer = NativeSearchDelivery(window)
        try child("STATIC", "Search", 10)
        try child("EDIT", "", 1, style: DWORD(WS_TABSTOP | ES_AUTOHSCROLL))
        try child("STATIC", "Results", 11)
        try child("LISTBOX", "Search results", 2, style: DWORD(WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT))
        try child("STATIC", "Quick result", 12)
        try child("STATIC", "Choose a result", 13)
        try child("EDIT", "Press Space or Preview to inspect a result.", 14, style: DWORD(WS_TABSTOP | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL))
        try child("STATIC", "Search apps and files", 15)
        try child("STATIC", "↑↓ Choose   Enter Open   Tab Results   Space Preview   Esc Close", 16)
        try child("BUTTON", "Open", 6, style: DWORD(WS_TABSTOP | BS_DEFPUSHBUTTON))
        try child("BUTTON", "Preview", 3, style: DWORD(WS_TABSTOP | BS_PUSHBUTTON))
        try child("BUTTON", "Copy", 5, style: DWORD(WS_TABSTOP | BS_PUSHBUTTON))
        try child("BUTTON", "Close", 4, style: DWORD(WS_TABSTOP | BS_PUSHBUTTON))
        if let edit = controls[1] {
            SendMessageW(edit, UINT(EM_SETLIMITTEXT), 1024, 0)
            _ = withWideString(localization.text("Search apps, files, or calculate")) { SendMessageW(edit, UINT(EM_SETCUEBANNER), 1, LPARAM(Int(bitPattern: $0))) }
            guard SetWindowSubclass(edit,searchEditProcedure,1,DWORD_PTR(UInt(bitPattern:Unmanaged.passUnretained(self).toOpaque()))) else {
                throw WindowsError.api("Prepare native search composition",GetLastError())
            }
        }
        try theme(); try typography(); try updateIcons(); arrange()
        for id in [3,5,6] { EnableWindow(controls[id], false) }
    }
    @discardableResult private func child(_ kind: String, _ text: String, _ id: Int, style: DWORD = 0) throws -> HWND {
        let created = withWideString(kind) { kind in withWideString(localization.text(text)) {
            CreateWindowExW(0, kind, $0, DWORD(WS_CHILD | WS_VISIBLE) | style, 0, 0, 1, 1, window, HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
        } }
        guard let created else { throw WindowsError.api("Create search control", GetLastError()) }
        controls[id] = created; return created
    }
    private func checkThread() { precondition(GetCurrentThreadId() == uiThread, "Search UI must be updated on its owning thread") }
    private func setText(_ id: Int, _ text: String) { if let control = controls[id] { _ = withWideString(text) { SetWindowTextW(control, $0) } } }
    private func label(_ id: Int, _ english: String) { setText(id,localization.text(english)) }
    private func ownedParts(_ text:String) -> String {
        text.split(separator:"·",omittingEmptySubsequences:false).map { part in
            let part=String(part.drop(while:\.isWhitespace).reversed().drop(while:\.isWhitespace).reversed())
            if part.first?.isNumber == true || part.first=="-" || part.first=="+" { return part }
            return localization.text(part)
        }.joined(separator:" · ")
    }
    private func ownsTitle(_ result:NativeSearchResult) -> Bool { result.kind=="Action" || result.kind=="Website" && result.id=="web" }
    private func displayedTitle(_ result:NativeSearchResult) -> String { ownsTitle(result) ? localization.text(result.title) : result.title }
    private func ownsSubtitle(_ result:NativeSearchResult) -> Bool { result.kind=="Action" || result.id=="answer" }
    private func displayedSubtitle(_ result:NativeSearchResult) -> String {
        ownsSubtitle(result) ? ownedParts(result.subtitle) : result.subtitle
    }
    private func accessibleText(_ result:NativeSearchResult) -> String {
        "\(displayedTitle(result)). \(localization.text(result.kind)). \(displayedSubtitle(result))"
    }
    private func text(_ id: Int) -> String {
        guard let control = controls[id] else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(GetWindowTextLengthW(control)) + 1)
        let count = GetWindowTextW(control, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }
    private func theme(forcedHighContrast: Bool? = nil) throws {
        var contrast = HIGHCONTRASTW(); contrast.cbSize = DWORD(MemoryLayout<HIGHCONTRASTW>.size)
        let systemContrast = SystemParametersInfoW(UINT(SPI_GETHIGHCONTRAST), contrast.cbSize, &contrast, 0) && contrast.dwFlags & DWORD(HCF_HIGHCONTRASTON) != 0
        let previousContrast = highContrast
        highContrast = forcedHighContrast ?? systemContrast
        var replacements: [HBRUSH] = []
        for color in [backgroundColor, surfaceColor, selectedColor] {
            guard let brush = CreateSolidBrush(color) else { let error = GetLastError(); replacements.forEach { DeleteObject($0) }; highContrast = previousContrast; throw WindowsError.api("Create search colors", error) }
            replacements.append(brush)
        }
        let previous = brushes; brushes = replacements; previous.forEach { DeleteObject($0) }
        if let window { RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN)) }
    }
    private func typography() throws {
        var replacements: [HFONT] = []
        for (size, weight) in [(14, 400), (26, 400), (17, 600), (13, 400), (28, 600)] {
            guard let font = withWideString("Segoe UI", { CreateFontW(-Int32(Double(size) * scale), 0, 0, 0, Int32(weight), 0, 0, 0,
                DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0) }) else {
                let error = GetLastError(); replacements.forEach { DeleteObject($0) }; throw WindowsError.api("Create search typography", error)
            }
            replacements.append(font)
        }
        let previous = fonts; fonts = replacements
        for (id, control) in controls {
            let role = id == 1 ? 1 : id == 13 ? 4 : id == 11 || id == 12 ? 2 : id == 16 ? 3 : 0
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[role])), 1)
        }
        if let list = controls[2] { SendMessageW(list, UINT(LB_SETITEMHEIGHT), 0, LPARAM(Int32(62 * scale))) }
        previous.forEach { DeleteObject($0) }
    }
    private func updateIcons() throws {
        guard let window else { return }
        let large = try ApplicationIcon(size: Int32(48 * scale))
        let small = try ApplicationIcon(size: GetSystemMetricsForDpi(Int32(SM_CXSMICON), GetDpiForWindow(window)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: large.handle)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: small.handle)))
        brand = large; caption = small
    }
    private func arrange() {
        guard let window else { return }
        var client = RECT(); GetClientRect(window, &client)
        let width = Int(Double(client.right) / scale), height = Int(Double(client.bottom) / scale)
        let split = max(260, width * 57 / 100), footer = max(254, height - 48)
        label(16,width < 680 ? "Enter Open • Esc Close" : "↑↓ Choose • Enter Open • Space Preview")
        for (id, x, y, w, h) in [(10,76,18,width-100,20),(1,76,42,width-100,40),(11,24,112,split-40,24),
            (2,16,146,split-28,footer-154),(12,split+20,112,width-split-44,24),(13,split+20,158,width-split-44,54),
            (14,split+20,220,width-split-44,footer-234),(15,24,87,width-48,20),(16,24,footer+8,width-420,28),
            (6,width-384,footer+4,80,32),(3,width-296,footer+4,88,32),(5,width-200,footer+4,84,32),(4,width-108,footer+4,80,32)] {
            if let control = controls[id] { MoveWindow(control, Int32(Double(x) * scale), Int32(Double(y) * scale), Int32(Double(max(1,w)) * scale), Int32(Double(max(1,h)) * scale), false) }
        }
        RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN))
    }
    func show(query: String = "") throws {
        checkThread(); guard let window else { return }
        guard query.utf16.count <= 1024, !query.utf16.contains(0) else { throw WindowsError.unsupported("Search query exceeds its limit.") }
        var monitor = MONITORINFO(); monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        let screen = MonitorFromWindow(GetForegroundWindow(), DWORD(MONITOR_DEFAULTTONEAREST))
        guard GetMonitorInfoW(screen, &monitor) else { throw WindowsError.api("Locate search panel monitor", GetLastError()) }
        let area = monitor.rcWork
        // Moving first lets WM_DPICHANGED update fonts/icons before sizing for the destination monitor.
        SetWindowPos(window,nil,area.left,area.top,0,0,UINT(SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE))
        let width = min(Int32(760 * scale), area.right-area.left), height = min(Int32(468 * scale), area.bottom-area.top)
        SetWindowPos(window, nil, area.left+(area.right-area.left-width)/2, area.top+(area.bottom-area.top-height)/3,
            width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        changingQuery = true; setText(1, query); changingQuery = false
        ShowWindow(window, Int32(SW_SHOW)); SetForegroundWindow(window); SetFocus(controls[1]); queryChanged()
    }
    func hide() {
        checkThread(); guard !dismissing else { return }
        dismissing=true; defer { dismissing=false }
        generation &+= 1; previewID = nil; producer?.cancelPreview()
        if let window { ShowWindow(window, Int32(SW_HIDE)) }; onDismiss()
    }
    private func queryChanged() {
        generation &+= 1; results = []; previewID = nil; producer?.cancelPreview()
        if let list = controls[2] { SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0) }
        for id in [3,5,6] { EnableWindow(controls[id], false) }; label(13, "Choose a result"); label(14, "Press Space or Preview to inspect a result.")
        label(15, "Searching…"); onQuery(text(1))
    }
    fileprivate func compositionChanged(_ active: Bool) {
        composing = active
        if !active, !dismissing, let window, IsWindowVisible(window) { queryChanged() }
    }
    private var selected: NativeSearchResult? {
        guard let list = controls[2] else { return nil }
        let index = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
        return results.indices.contains(index) ? results[index] : nil
    }
    @discardableResult func apply(_ snapshot: NativeSearchSnapshot) throws -> Bool {
        checkThread(); guard snapshot.generation == generation else { return false }
        guard snapshot.isValid else { throw WindowsError.unsupported("Invalid search result snapshot.") }
        let previousID = selected?.id, requestedPreview=previewID
        results = snapshot.results
        if let list = controls[2] {
            SendMessageW(list, UINT(WM_SETREDRAW), 0, 0)
            defer { SendMessageW(list, UINT(WM_SETREDRAW), 1, 0); InvalidateRect(list, nil, true) }
            SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0)
            for result in results {
                let added = withWideString(accessibleText(result)) { SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
                if added < 0 { results = []; SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0); throw WindowsError.api("Populate native search results", GetLastError()) }
            }
            if !results.isEmpty { SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(results.firstIndex(where: { $0.id == previousID }) ?? 0), 0) }
        }
        previewID=requestedPreview==selected?.id ? requestedPreview : nil
        if previewID==nil { producer?.cancelPreview() }
        for id in [3,5,6] { EnableWindow(controls[id], !results.isEmpty) }; setText(15, ownedParts(snapshot.status))
        if previewID==nil {
            setText(13, selected.map { $0.id=="answer" ? snapshot.quickAnswer ?? $0.title : displayedTitle($0) } ?? snapshot.quickAnswer ?? localization.text("No results"))
            setText(14, selected.map(displayedSubtitle) ?? localization.text("Try another query."))
        }
        return true
    }
    @discardableResult func applyPreview(generation: UInt64, resultID: String, title: String, text: String) throws -> Bool {
        checkThread(); guard generation == self.generation, resultID == selected?.id, resultID == previewID else { return false }
        guard title.utf16.count <= 4096, text.utf16.count <= 4096, !title.utf16.contains(0), !text.utf16.contains(0) else { throw WindowsError.unsupported("Preview text exceeds its limit.") }
        setText(13,selected.map(ownsTitle) == true ? localization.text(title) : title)
        setText(14,selected.map(ownsSubtitle) == true ? ownedParts(text) : text); return true
    }
    private func selectionChanged() {
        previewID = nil; producer?.cancelPreview(); setText(13, selected.map(displayedTitle) ?? localization.text("No results")); setText(14, selected.map(displayedSubtitle) ?? localization.text("Try another query."))
        if let list = controls[2], let result = selected, let index = results.firstIndex(where: { $0.id == result.id }) {
            NotifyWinEvent(DWORD(EVENT_OBJECT_SELECTION), list, searchClientObject, LONG(index+1))
        }
    }
    private func moveSelection(_ delta: Int) {
        guard let list = controls[2], !results.isEmpty else { return }
        let current = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
        SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(max(0,min(results.count-1,current+delta))), 0); selectionChanged()
    }
    private func activate() { guard let selected else { return }; onActivate(selected.id); hide() }
    private func preview() {
        guard let selected else { return }; previewID = selected.id
        producer?.expectPreview(generation:generation,resultID:selected.id)
        label(14, "Loading preview…"); onPreview(selected.id)
    }
    private func copy() { guard let selected else { return }; onCopy(selected.id) }
    private func reveal() { guard let selected, ["File","Folder","Application"].contains(selected.kind) else { return }; onReveal(selected.id) }
    private func copyAnswerFromEdit() -> Bool {
        guard let edit=controls[1], selected?.id=="answer" else { return false }
        var start:DWORD=0, end:DWORD=0
        withUnsafeMutablePointer(to:&start) { start in withUnsafeMutablePointer(to:&end) { end in
            _=SendMessageW(edit,UINT(EM_GETSEL),WPARAM(UInt(bitPattern:start)),LPARAM(Int(bitPattern:end)))
        } }
        guard start==end else { return false }
        copy(); return true
    }
    private func key(_ key: WPARAM, target: HWND) -> Bool {
        if target == controls[1], composing { return false }
        if key == WPARAM(VK_ESCAPE) { hide(); return true }
        if key == WPARAM(VK_RETURN), target == controls[1] || target == controls[2] {
            if GetKeyState(Int32(VK_CONTROL)) < 0 { reveal() } else { activate() }; return true
        }
        if key == WPARAM(VK_DOWN), target == controls[1] || target == controls[2] { moveSelection(1); return true }
        if key == WPARAM(VK_UP), target == controls[1] || target == controls[2] { moveSelection(-1); return true }
        if key == WPARAM(VK_SPACE), target == controls[2] { preview(); return true }
        if key == WPARAM(0x43), GetKeyState(Int32(VK_CONTROL)) < 0 {
            if target == controls[1] { return copyAnswerFromEdit() }
            if target == controls[2] { copy(); return true }
        }
        return false
    }
    /// Invoke before TranslateMessage/DispatchMessage in the host's UI loop.
    func dialogMessage(_ message: inout MSG) -> Bool {
        checkThread(); guard let window, IsWindowVisible(window), let target = message.hwnd,
            target == window || IsChild(window,target) else { return false }
        if target == controls[1], composing { return false }
        if message.message == UINT(WM_KEYDOWN), key(message.wParam,target:target) { return true }
        return IsDialogMessageW(window, &message)
    }
    fileprivate func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        switch message {
        case searchSnapshotMessage:
            if let update=producer?.take() {
                if let snapshot=update.snapshot { do { try apply(snapshot) } catch { label(15, "Search results could not be displayed.") } }
                if let preview=update.preview {
                    do { try applyPreview(generation:preview.generation,resultID:preview.resultID,title:preview.title,text:preview.text) }
                    catch { label(15,"Search preview could not be displayed.") }
                }
            }; return 0
        case UINT(WM_COMMAND):
            let id = Int(value & 0xffff), notification = Int((value >> 16) & 0xffff)
            if id == 1, notification == Int(EN_CHANGE), !changingQuery, !composing { queryChanged() }
            if id == 2, notification == Int(LBN_SELCHANGE) { selectionChanged() }
            if id == 2, notification == Int(LBN_DBLCLK) { activate() }
            if id == 3, notification == Int(BN_CLICKED) { preview() }
            if id == 5, notification == Int(BN_CLICKED) { copy() }
            if id == 6, notification == Int(BN_CLICKED) { activate() }
            if id == 4, notification == Int(BN_CLICKED) { hide() }
            return 0
        case UINT(WM_CLOSE): hide(); return 0
        case UINT(WM_ACTIVATE):
            if value & 0xffff == WPARAM(WA_INACTIVE), IsWindowVisible(window) {
                let next=HWND(bitPattern:Int(data))
                if next==nil || GetAncestor(next,UINT(GA_ROOTOWNER)) != window { hide() }
            }; break
        case UINT(WM_GETMINMAXINFO):
            if let info=UnsafeMutablePointer<MINMAXINFO>(bitPattern:Int(data)) {
                info.pointee.ptMinTrackSize=POINT(x:Int32(560*scale),y:Int32(360*scale))
            }; return 0
        case UINT(WM_SIZE): arrange(); return 0
        case UINT(WM_DPICHANGED):
            if let area = UnsafePointer<RECT>(bitPattern: Int(data))?.pointee { SetWindowPos(window,nil,area.left,area.top,area.right-area.left,area.bottom-area.top,UINT(SWP_NOZORDER|SWP_NOACTIVATE)) }
            do { try typography(); try updateIcons() } catch { label(15,"Search appearance could not be refreshed.") }; arrange(); return 0
        case UINT(WM_SETTINGCHANGE), UINT(WM_SYSCOLORCHANGE), UINT(WM_THEMECHANGED):
            do { try theme() } catch { label(15,"Search colors could not be refreshed.") }; return 0
        case UINT(WM_MEASUREITEM):
            if let item = UnsafeMutablePointer<MEASUREITEMSTRUCT>(bitPattern:Int(data)) { item.pointee.itemHeight = UINT(62*scale); return 1 }
        case UINT(WM_DRAWITEM):
            if let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern:Int(data))?.pointee { drawRow(item); return 1 }
        case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLOREDIT), UINT(WM_CTLCOLORLISTBOX):
            guard let dc = HDC(bitPattern:UInt(value)), !brushes.isEmpty else { return 0 }
            SetBkMode(dc,Int32(TRANSPARENT)); SetTextColor(dc,textColor)
            let surface = message != UINT(WM_CTLCOLORSTATIC)
            SetBkColor(dc,surface ? surfaceColor : backgroundColor)
            return LRESULT(Int(bitPattern:brushes[surface ? 1 : 0]))
        case UINT(WM_ERASEBKGND): return 1
        case UINT(WM_PAINT):
            var paint = PAINTSTRUCT()
            if let dc = BeginPaint(window,&paint) { paintPanel(dc,window); EndPaint(window,&paint) }; return 0
        default: break
        }
        return DefWindowProcW(window,message,value,data)
    }
    private func paintPanel(_ dc: HDC, _ window: HWND) {
        guard brushes.count >= 2 else { return }
        var area=RECT(); GetClientRect(window,&area); FillRect(dc,&area,brushes[0])
        if let brand { DrawIconEx(dc,Int32(24*scale),Int32(32*scale),brand.handle,Int32(32*scale),Int32(32*scale),0,nil,UINT(DI_NORMAL)) }
        let pen=CreatePen(Int32(PS_SOLID),1,borderColor), oldPen=SelectObject(dc,pen), oldBrush=SelectObject(dc,GetStockObject(Int32(NULL_BRUSH)))
        RoundRect(dc,0,0,area.right,area.bottom,Int32(16*scale),Int32(16*scale))
        MoveToEx(dc,Int32(16*scale),Int32(108*scale),nil); LineTo(dc,area.right-Int32(16*scale),Int32(108*scale))
        SelectObject(dc,oldBrush); SelectObject(dc,oldPen); DeleteObject(pen)
    }
    private func drawRow(_ item: DRAWITEMSTRUCT) {
        guard let dc=item.hDC, brushes.count==3,fonts.count==5 else { return }
        let saved=SaveDC(dc); guard saved != 0 else { return }
        defer { RestoreDC(dc,saved) }
        var area=item.rcItem
        let index=Int(item.itemID), selected=item.itemState & UINT(ODS_SELECTED) != 0
        FillRect(dc,&area,brushes[selected ? 2 : 1]); guard results.indices.contains(index) else { return }
        let result=results[index], color=highContrast && selected ? GetSysColor(Int32(COLOR_HIGHLIGHTTEXT)) : textColor
        SetBkMode(dc,Int32(TRANSPARENT)); SetTextColor(dc,color)
        SelectObject(dc,fonts[2])
        var title=RECT(left:area.left+Int32(14*scale),top:area.top+Int32(8*scale),right:area.right-Int32(14*scale),bottom:area.top+Int32(31*scale))
        _=withWideString(displayedTitle(result)) { DrawTextW(dc,$0,-1,&title,UINT(DT_SINGLELINE|DT_END_ELLIPSIS)) }
        SelectObject(dc,fonts[3]); SetTextColor(dc,highContrast && selected ? color : secondaryColor)
        var subtitle=RECT(left:title.left,top:area.top+Int32(34*scale),right:title.right,bottom:area.bottom-Int32(5*scale))
        _=withWideString(localization.text(result.kind) + "  ·  " + displayedSubtitle(result)) { DrawTextW(dc,$0,-1,&subtitle,UINT(DT_SINGLELINE|DT_END_ELLIPSIS)) }
        if item.itemState & UINT(ODS_FOCUS) != 0 { InflateRect(&area,-3,-3); DrawFocusRect(dc,&area) }
    }
    private static func accessibleName(_ window: HWND, child: Int32 = 0) throws -> String {
        var id=GUID(Data1:0x618736e0,Data2:0x3c3d,Data3:0x11cf,Data4:(0x81,0x0c,0x00,0xaa,0x00,0x38,0x9b,0x71)), object: UnsafeMutableRawPointer?
        let status=AccessibleObjectFromWindow(window,DWORD(bitPattern:searchClientObject),&id,&object)
        guard status >= 0, let accessible=object?.assumingMemoryBound(to:IAccessible.self) else { throw WindowsError.unsupported("Native control accessibility is unavailable.") }
        defer { _=accessible.pointee.lpVtbl.pointee.Release(accessible) }
        var item=VARIANT(), name: BSTR?
        item.vt=VARTYPE(VT_I4.rawValue); item.lVal=child
        let read=accessible.pointee.lpVtbl.pointee.get_accName(accessible,item,&name)
        defer { SysFreeString(name) }
        guard read >= 0, let name else { throw WindowsError.unsupported("Native control has no accessible name.") }
        return String(decoding:UnsafeBufferPointer(start:name,count:Int(SysStringLen(name))),as:UTF16.self)
    }
    /// Hidden own-window checks. No global hotkey, desktop input, OS setting, file opening or model work.
    static func selfCheck() throws {
        func expect(_ value: Bool,_ message: String) throws { guard value else { throw WindowsError.unsupported("Search check failed: " + message) } }
        let initialized=CoInitializeEx(nil,DWORD(COINIT_APARTMENTTHREADED.rawValue))
        guard initialized >= 0 || initialized == HRESULT(bitPattern:0x80010106) else { throw WindowsError.status("Initialize accessibility COM",initialized) }
        defer { if initialized >= 0 { CoUninitialize() } }
        var queries:[String]=[], activations:[String]=[], previews:[String]=[], copies:[String]=[], reveals:[String]=[], dismissals=0, reentrantWindow:HWND?
        let panel=try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{queries.append($0)},onActivate:{activations.append($0)},onPreview:{previews.append($0)},onCopy:{copies.append($0)},onDismiss:{ dismissals += 1; if let reentrantWindow { _=SendMessageW(reentrantWindow,UINT(WM_CLOSE),0,0) } },onReveal:{reveals.append($0)})
        guard let window=panel.window, let edit=panel.controls[1],let list=panel.controls[2] else { throw WindowsError.unsupported("Search controls are missing.") }
        try expect(!IsWindowVisible(window),"fixture stays hidden")
        try expect(GetWindowLongPtrW(window,Int32(GWL_EXSTYLE)) & LONG_PTR(WS_EX_TOOLWINDOW) != 0,"tool window avoids taskbar")
        try expect(SendMessageW(window,UINT(WM_GETICON),WPARAM(ICON_SMALL),0) != 0 && SendMessageW(window,UINT(WM_GETICON),WPARAM(ICON_BIG),0) != 0,"owned Command Ember icons")
        func checkBounds() throws {
            var client=RECT(); GetClientRect(window,&client)
            for (_,control) in panel.controls {
                var area=RECT(); GetWindowRect(control,&area)
                _=withUnsafeMutablePointer(to:&area) { $0.withMemoryRebound(to:POINT.self,capacity:2) { MapWindowPoints(nil,window,$0,2) } }
                try expect(area.left >= 0 && area.top >= 0 && area.right <= client.right && area.bottom <= client.bottom,"native control bounds")
            }
        }
        try checkBounds()
        for (width,height) in [(560,360),(940,620),(760,468)] {
            SetWindowPos(window,nil,0,0,Int32(Double(width)*panel.scale),Int32(Double(height)*panel.scale),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            try checkBounds()
        }
        try expect(!(try accessibleName(edit)).isEmpty && !(try accessibleName(list)).isEmpty,"real edit/list accessible names")
        for (id,name) in [(3,"Preview"),(4,"Close"),(5,"Copy"),(6,"Open")] { try expect(try accessibleName(panel.controls[id]!) == name,"native button accessible name") }
        panel.setText(1,"120 USD")
        try expect(queries.last == "120 USD","native edit sends actual query")
        let generation=panel.generation
        let results=[NativeSearchResult(id:"amount",title:"120 USD",subtitle:"Amount recognized; no exchange rate applied",kind:"Amount"),
            NativeSearchResult(id:"notes",title:"Notes",subtitle:"Application",kind:"App"),
            NativeSearchResult(id:"file",title:"Project notes — пример.txt",subtitle:"Example document",kind:"File")]
        try expect(try !panel.apply(NativeSearchSnapshot(generation:generation-1,results:results,status:"Stale",quickAnswer:nil)),"stale generation rejected")
        try expect(try panel.apply(NativeSearchSnapshot(generation:generation,results:results,status:"3 example results",quickAnswer:"120 USD")),"current generation accepted")
        let current=NativeSearchSnapshot(generation:generation,results:results,status:"Delivered current results",quickAnswer:"120 USD")
        let stale=NativeSearchSnapshot(generation:generation-1,results:[],status:"Delivered stale results",quickAnswer:nil)
        try expect(panel.delivery.post(stale) && panel.delivery.post(current) && !panel.delivery.post(stale),"delivery keeps newer pending generation")
        var message=MSG()
        func drain() -> Int {
            var count=0
            while PeekMessageW(&message,window,searchSnapshotMessage,searchSnapshotMessage,UINT(PM_REMOVE)) { DispatchMessageW(&message); count += 1 }
            return count
        }
        try expect(drain()==1 && panel.text(15)=="Delivered current results","one native message delivers newest snapshot")
        try expect(SendMessageW(list,UINT(LB_GETCOUNT),0,0)==3,"actual native list items")
        for (index,result) in results.enumerated() {
            var words=[WCHAR](repeating:0,count:Int(SendMessageW(list,UINT(LB_GETTEXTLEN),WPARAM(index),0))+1)
            words.withUnsafeMutableBufferPointer { _=SendMessageW(list,UINT(LB_GETTEXT),WPARAM(index),LPARAM(Int(bitPattern:$0.baseAddress!))) }
            try expect(String(decoding:words.prefix(while:{$0 != 0}),as:UTF16.self)==result.accessibleText,"native list retains actual result strings")
            try expect(try accessibleName(list,child:Int32(index+1))==result.accessibleText,"MSAA result name matches displayed data")
        }
        guard let dc=CreateCompatibleDC(nil) else { throw WindowsError.api("Create own drawing fixture",GetLastError()) }
        defer { DeleteDC(dc) }
        SetTextColor(dc,0x0001_0203); SetBkMode(dc,Int32(OPAQUE))
        let originalFont=GetCurrentObject(dc,UINT(OBJ_FONT))
        var row=DRAWITEMSTRUCT(); row.hDC=dc; row.itemID=0; row.rcItem=RECT(left:0,top:0,right:320,bottom:62)
        panel.drawRow(row)
        try expect(GetTextColor(dc)==0x0001_0203 && GetBkMode(dc)==Int32(OPAQUE) && GetCurrentObject(dc,UINT(OBJ_FONT))==originalFont,"owner drawing restores the supplied native DC")
        var duplicateRejected=false
        do { _=try panel.apply(NativeSearchSnapshot(generation:generation,results:[results[0],results[0]],status:"Invalid",quickAnswer:nil)) } catch { duplicateRejected=true }
        try expect(duplicateRejected && SendMessageW(list,UINT(LB_GETCOUNT),0,0)==3,"invalid snapshot preserves list")
        try expect(!panel.delivery.post(NativeSearchSnapshot(generation:generation,results:results,status:String(repeating:"x",count:4097),quickAnswer:nil)),"mailbox rejects oversized values")
        try expect(panel.key(WPARAM(VK_DOWN),target:edit) && panel.selected?.id=="notes","Down selects result while editing")
        try expect(panel.key(WPARAM(VK_UP),target:edit) && panel.selected?.id=="amount","Up selects previous result")
        panel.moveSelection(1); _=try panel.apply(current)
        try expect(panel.selected?.id=="notes" && panel.text(13)=="Notes","later quick-answer snapshot preserves selected item preview title")
        panel.moveSelection(-1)
        try expect(!panel.key(WPARAM(VK_SPACE),target:edit),"Space remains query text in edit")
        panel.composing=true
        try expect(!panel.key(WPARAM(VK_RETURN),target:edit) && !panel.key(WPARAM(VK_DOWN),target:edit) && activations.isEmpty,"IME composition retains Enter and arrows")
        panel.composing=false
        try expect(panel.key(WPARAM(VK_SPACE),target:list) && previews.last=="amount","Space in results requests preview")
        try expect(try !panel.applyPreview(generation:generation,resultID:"notes",title:"Wrong",text:"Stale"),"wrong selected preview rejected")
        try expect(try panel.applyPreview(generation:generation,resultID:"amount",title:"120 USD",text:"No conversion rate was requested."),"selected preview accepted")
        try expect(!panel.delivery.postPreview(generation:generation-1,resultID:"amount",title:"Old",text:"Old") &&
            !panel.delivery.postPreview(generation:generation,resultID:"notes",title:"Wrong",text:"Wrong"),"preview mailbox rejects stale generation and selection")
        try expect(panel.delivery.postPreview(generation:generation,resultID:"amount",title:"120 USD",text:"First preview") &&
            panel.delivery.postPreview(generation:generation,resultID:"amount",title:"120 USD",text:"Latest preview") && panel.delivery.post(current),"coalesced snapshot and preview accepted")
        try expect(drain()==1 && panel.text(14)=="Latest preview","snapshot and latest preview share one message")
        try expect(panel.delivery.postPreview(generation:generation,resultID:"amount",title:"120 USD",text:"Late selection preview"),"queued preview fixture")
        panel.moveSelection(1)
        try expect(drain()==1 && panel.text(13)=="Notes" &&
            !panel.delivery.postPreview(generation:generation,resultID:"amount",title:"Old",text:"Old"),"selection cancels queued and subsequent previews")
        panel.moveSelection(-1)
        panel.moveSelection(2); panel.reveal()
        try expect(reveals==["file"] && activations.isEmpty,"Reveal delegates the selected file without opening it")
        panel.moveSelection(-2)
        let calculation=NativeSearchResult(id:"answer",title:"4",subtitle:"2 + 2",kind:"Calculator")
        _=try panel.apply(NativeSearchSnapshot(generation:generation,results:[calculation],status:"Calculated",quickAnswer:"4"))
        SendMessageW(edit,UINT(EM_SETSEL),0,0)
        try expect(panel.copyAnswerFromEdit() && copies==["answer"],"unselected query text copies the calculation")
        SendMessageW(edit,UINT(EM_SETSEL),0,3)
        try expect(!panel.copyAnswerFromEdit() && copies==["answer"],"selected query text keeps native Copy")
        _=try panel.apply(current)
        for id in [1,2,14,3,4,5,6] { try expect(GetWindowLongPtrW(panel.controls[id]!,Int32(GWL_STYLE)) & LONG_PTR(WS_TABSTOP) != 0,"keyboard tab stops") }
        try expect(GetNextDlgTabItem(window,edit,false)==list && GetNextDlgTabItem(window,list,false)==panel.controls[14],"native tab order")
        let previousFocus=GetFocus(); SetFocus(edit)
        try expect(GetFocus()==edit,"native edit focus")
        SetFocus(list); try expect(GetFocus()==list,"native result focus")
        SetFocus(previousFocus)
        try panel.theme(forcedHighContrast:true)
        try expect(panel.highContrast && panel.textColor==GetSysColor(Int32(COLOR_WINDOWTEXT)) && panel.selectedColor==GetSysColor(Int32(COLOR_HIGHLIGHT)),"high contrast palette callback")
        try panel.theme(forcedHighContrast:false)
        SendMessageW(panel.controls[5],UINT(BM_CLICK),0,0)
        try expect(copies==["answer","amount"] && activations.isEmpty,"Copy delegates once without opening")
        reentrantWindow=window
        try expect(panel.key(WPARAM(VK_RETURN),target:list) && activations==["amount"],"Enter callback once")
        try expect(dismissals==1,"activation dismissal notifies the host once through reentrant Close")
        try expect(try !panel.apply(NativeSearchSnapshot(generation:generation,results:results,status:"Late",quickAnswer:nil)),"hidden panel invalidates generation")
        _=panel.key(WPARAM(VK_ESCAPE),target:edit)
        try expect(!IsWindowVisible(window) && dismissals==2,"Escape hides own window and invalidates host work")
        let dismissedGeneration=panel.generation, queryCount=queries.count
        panel.compositionChanged(false)
        try expect(panel.generation==dismissedGeneration && queries.count==queryCount,"late IME completion cannot restart hidden search")
        reentrantWindow=nil
        panel.delivery.close(); try expect(!panel.delivery.post(NativeSearchSnapshot(generation:panel.generation,results:[],status:"Closed",quickAnswer:nil)) &&
            !panel.delivery.postPreview(generation:generation,resultID:"amount",title:"Late",text:"Late"),"closed delivery rejects producers")
        try panel.localization.select(LanguagePack(locale:"zz-ZZ",name:"Fixture",strings:[
            "Action":"Translated action","File":"Translated file","Application":"Translated app","Calculator":"Translated calculator","Website":"Translated web","Search the web":"Translated web title",
            "Sleep":"Translated sleep","Put this computer to sleep":"Translated subtitle","Apps and files":"Translated status",
            "reference rates":"Translated suffix","Bank of Russia reference rates":"Translated bank","13.10.2026":"Wrong date","8 / 64":"Wrong count"
        ]),persist:false)
        let ownedAction=NativeSearchResult(id:"action:sleep",title:"Sleep",subtitle:"Put this computer to sleep",kind:"Action")
        let userFile=NativeSearchResult(id:"file",title:"Sleep",subtitle:"User text",kind:"File")
        let userApp=NativeSearchResult(id:"app",title:"Sleep",subtitle:"User app text",kind:"Application")
        let web=NativeSearchResult(id:"web",title:"Search the web",subtitle:"Sleep",kind:"Website")
        _=try panel.apply(NativeSearchSnapshot(generation:panel.generation,results:[ownedAction,userFile,userApp,web],status:"Apps and files · reference rates · 8 / 64",quickAnswer:nil))
        try expect(try accessibleName(list,child:1)=="Translated sleep. Translated action. Translated subtitle" && panel.text(13)=="Translated sleep","owned result paint/header and MSAA share translated values")
        try expect(try accessibleName(list,child:2)=="Sleep. Translated file. User text" && accessibleName(list,child:3)=="Sleep. Translated app. User app text","file and app display names stay unchanged")
        try expect(try accessibleName(list,child:4)=="Translated web title. Translated web. Sleep","owned web label translates while query text stays raw")
        panel.reveal(); try expect(reveals==["file"],"Reveal rejects a result without a local item")
        try expect(panel.text(15)=="Translated status · Translated suffix · 8 / 64" && panel.ownedParts("Bank of Russia reference rates · 13.10.2026 · 120 USD")=="Translated bank · 13.10.2026 · 120 USD","status and currency labels preserve counts dates and amounts")
        _=try panel.apply(NativeSearchSnapshot(generation:panel.generation,results:[calculation],status:"Calculated",quickAnswer:"4"))
        SendMessageW(edit,UINT(EM_SETSEL),0,0)
        try expect(panel.selected?.kind=="Calculator" && panel.copyAnswerFromEdit() && copies.last=="answer","translated calculation keeps raw callback kind and Copy behavior")
        let clock=NativeSearchResult(id:"answer",title:"12:00",subtitle:"UTC · 2026-10-13 · Windows time-zone rules",kind:"World clock")
        _=try panel.apply(NativeSearchSnapshot(generation:panel.generation,results:[clock],status:"Calculated",quickAnswer:"12:00"))
        try expect(panel.copyAnswerFromEdit() && panel.selected?.kind=="World clock","new quick-answer kinds retain the same query Copy behavior")
        try panel.localization.select(.english,persist:false)
        func fixture() throws -> NativeSearchWindow {
            try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{_ in},onActivate:{_ in},onPreview:{_ in},onCopy:{_ in})
        }
        func refreshFixture(_ value:NativeSearchWindow) throws {
            for _ in 0..<4 { try value.typography(); try value.theme(forcedHighContrast:true); try value.theme(forcedHighContrast:false); try value.updateIcons(); value.arrange() }
        }
        // Warm native class/control caches before measuring only the next panel's owned resources.
        var owned:NativeSearchWindow?=try fixture(); try refreshFixture(owned!); owned=nil
        let gdi=GetGuiResources(GetCurrentProcess(),DWORD(GR_GDIOBJECTS)), user=GetGuiResources(GetCurrentProcess(),DWORD(GR_USEROBJECTS))
        owned=try fixture(); weak let weakPanel=owned
        let deadWindow=owned!.window!, deadDelivery=owned!.delivery
        try refreshFixture(owned!)
        owned=nil
        try expect(weakPanel==nil && !IsWindow(deadWindow),"destruction releases owner and native windows")
        try expect(!deadDelivery.post(current) && !deadDelivery.postPreview(generation:generation,resultID:"amount",title:"Late",text:"Late"),"retained producer cannot address destroyed window")
        let finalGDI=GetGuiResources(GetCurrentProcess(),DWORD(GR_GDIOBJECTS)), finalUser=GetGuiResources(GetCurrentProcess(),DWORD(GR_USEROBJECTS))
        try expect(gdi==finalGDI && user==finalUser,"owned resources return to warmed baseline (GDI \(gdi)/\(finalGDI), USER \(user)/\(finalUser))")
        Console.writeLine("PASS: native search controls/resizing, MSAA names/localization, query/selection/open/copy/preview/dismissal, tab/focus and IME guards, bounded snapshot/preview delivery, stale selections/generations, system high contrast, owned icons and destruction/resources; fixture stayed hidden")
    }
    deinit { producer?.close(); if let window { DestroyWindow(window) }; fonts.forEach { DeleteObject($0) }; brushes.forEach { DeleteObject($0) } }
}
