// SPDX-License-Identifier: MIT
import Synchronization
import SearchCore
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
private let searchPendingMessage: UINT = 0x8058
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
private func searchLayoutCheckProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM, _ id: UINT_PTR, _ context: DWORD_PTR) -> LRESULT {
    if let counts = UnsafeMutablePointer<Int>(bitPattern:UInt(context)) {
        if message == UINT(WM_WINDOWPOSCHANGING) { counts[0] += 1 }
        if message == UINT(LB_RESETCONTENT) { counts[1] += 1 }
        if message == UINT(WM_SETTEXT) { counts[2] += 1 }
        if message == UINT(WM_SETREDRAW), value != 0 {
            counts[3] = Int(SendMessageW(window,UINT(LB_GETCURSEL),0,0))
            counts[4] = Int(SendMessageW(window,UINT(LB_GETTOPINDEX),0,0))
        }
    }
    return DefSubclassProc(window,message,value,data)
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
    private let designPreview: Bool
    private var controls: [Int: HWND] = [:]
    private var fonts: [HFONT] = []
    private var brushes: [HBRUSH] = []
    private var brand: ApplicationIcon?
    private var caption: ApplicationIcon?
    private var backdrop: NativeSearchBackdrop?
    private var materialAttempted = false
    private var results: [NativeSearchResult] = []
    private var resultStrings: [String] = []
    private var queryPending = false
    private var pendingStatusQueued = false
    private var bufferedPainting = false
    private var textLibrary: HMODULE?
    private var ownsCOM = false
    private var queryAccessibility: UnsafeMutablePointer<IAccPropServices>?
    private static var queryNameProperty: GUID { GUID(Data1:0x608d3df8,Data2:0x8128,Data3:0x4aa7,Data4:(0xa4,0x28,0xf5,0x5e,0x49,0x26,0x72,0x91)) }
    private var arranged: (Int32,Int32,UINT,Bool,Bool)?
    private var shaped: (Int32,Int32,UINT)?
    private var materialSize: (Int32,Int32,UINT,Bool)?
    private var changingQuery = false
    private var composing = false
    private(set) var category: SearchCategory = .all
    private var displayedCategory: SearchCategory = .all
    private var dismissing = false
    private var previewID: String?
    private var previewExpanded = false
    private var highContrast = false
    private var scale: Double { window.map { Double(GetDpiForWindow($0)) / 96 } ?? 1 }
    private var textColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOWTEXT)) : 0x002D_2525 }
    private var secondaryColor: COLORREF { highContrast ? textColor : 0x006E_6162 }
    private var backgroundColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_WINDOW)) : 0x00FC_FA_F8 }
    private var surfaceColor: COLORREF { backgroundColor }
    private var selectedColor: COLORREF { highContrast ? GetSysColor(Int32(COLOR_HIGHLIGHT)) : 0x00EF_F2FE }
    private var borderColor: COLORREF { highContrast ? textColor : 0x00E8_E3E2 }

    init(localization: Localization = Localization(), designPreview: Bool = false, onQuery: @escaping (String) -> Void, onActivate: @escaping (String) -> Void,
        onPreview: @escaping (String) -> Void, onCopy: @escaping (String) -> Void, onDismiss: @escaping () -> Void = {}, onReveal: @escaping (String) -> Void = { _ in }) throws {
        self.onQuery = onQuery; self.onActivate = onActivate; self.onPreview = onPreview; self.onCopy = onCopy; self.onDismiss=onDismiss; self.onReveal=onReveal; self.localization = localization
        self.designPreview = designPreview
        let initialized=CoInitializeEx(nil,DWORD(COINIT_APARTMENTTHREADED.rawValue))
        guard initialized >= 0 || initialized == HRESULT(bitPattern:0x80010106) else { throw WindowsError.status("Initialize Search accessibility",initialized) }
        ownsCOM=initialized >= 0
        bufferedPainting = BufferedPaintInit() >= 0
        var type = WNDCLASSEXW(); type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = searchProcedure; type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        // Windows owns this optional short-lived-window shadow; no captured desktop or blur surface.
        type.style = UINT(CS_DROPSHADOW)
        let registered = withWideString("SwiftyToys.NativeSearch") { type.lpszClassName = $0; return RegisterClassExW(&type) }
        guard registered != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS) else { throw WindowsError.api("Register search panel", GetLastError()) }
        let initialScale = Double(GetDpiForSystem()) / 96
        window = withWideString("SwiftyToys.NativeSearch") { name in withWideString(localization.text("SwiftyToys Search")) {
            CreateWindowExW(DWORD(designPreview ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW) | DWORD(WS_EX_CONTROLPARENT), name, $0, DWORD(WS_POPUP) | DWORD(WS_THICKFRAME | WS_CLIPCHILDREN),
                0, 0, Int32(720*initialScale), Int32(166*initialScale), nil, nil, GetModuleHandleW(nil), Unmanaged.passUnretained(self).toOpaque())
        } }
        guard let window else { throw WindowsError.api("Create search panel", GetLastError()) }
        producer = NativeSearchDelivery(window)
        textLibrary = withWideString("Msftedit.dll") { LoadLibraryExW($0,nil,DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)) }
        guard textLibrary != nil else { throw WindowsError.api("Load Windows Search input",GetLastError()) }
        try child("STATIC", "Search", 10, style: DWORD(SS_ICON | SS_REALSIZECONTROL))
        try child("RICHEDIT50W", "", 1, style: DWORD(WS_TABSTOP | ES_AUTOHSCROLL | ES_NOOLEDRAGDROP))
        try child("STATIC", "Results", 11)
        try child("LISTBOX", "Search results", 2, style: DWORD(WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT))
        try child("STATIC", "Quick result", 12)
        try child("STATIC", "Choose a result", 13, style: DWORD(SS_NOPREFIX | SS_ENDELLIPSIS))
        try child("EDIT", "Press Space or Preview to inspect a result.", 14, style: DWORD(WS_TABSTOP | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL))
        try child("STATIC", "Search apps and files", 15)
        try child("STATIC", "Enter Open • Tab Actions • Esc Close", 16)
        try child("BUTTON", "Open", 6, style: DWORD(WS_TABSTOP | BS_OWNERDRAW))
        try child("BUTTON", "Preview", 3, style: DWORD(WS_TABSTOP | BS_OWNERDRAW))
        try child("BUTTON", "Copy", 5, style: DWORD(WS_TABSTOP | BS_OWNERDRAW))
        try child("BUTTON", "Close", 4, style: DWORD(WS_TABSTOP | BS_OWNERDRAW))
        try child("STATIC", "Search apps, files, or calculate", 17, style:DWORD(SS_NOTIFY))
        for (index, category) in SearchCategory.allCases.enumerated() {
            try child("BUTTON", category == .applications ? "Apps" : category.title, 20+index, style:DWORD(WS_TABSTOP | BS_OWNERDRAW))
        }
        if let edit = controls[1] {
            guard SendMessageW(edit,UINT(EM_SETTEXTMODE),WPARAM(TM_PLAINTEXT.rawValue),0)==0 else {
                throw WindowsError.unsupported("Windows Search input could not enter plain-text mode.")
            }
            SendMessageW(edit,UINT(EM_EXLIMITTEXT),0,1024)
            SendMessageW(edit,UINT(EM_SETEVENTMASK),0,LPARAM(ENM_CHANGE))
            let languages=SendMessageW(edit,UINT(EM_GETLANGOPTIONS),0,0)
            // A search query must not change the keyboard layout or scale its font while typing.
            SendMessageW(edit,UINT(EM_SETLANGOPTIONS),0,languages & ~LPARAM(IMF_AUTOKEYBOARD|IMF_AUTOFONTSIZEADJUST))
            var clsid=GUID(Data1:0xb5f8350b,Data2:0x0548,Data3:0x48b1,Data4:(0xa6,0xee,0x88,0xbd,0x00,0xb4,0xa5,0xe7))
            var iid=GUID(Data1:0x6e26e776,Data2:0x04f0,Data3:0x495d,Data4:(0x80,0xe4,0x33,0x30,0x35,0x2e,0x31,0x69)), object:UnsafeMutableRawPointer?
            let accessible=CoCreateInstance(&clsid,nil,DWORD(CLSCTX_INPROC_SERVER.rawValue),&iid,&object)
            guard accessible >= 0, let object else { throw WindowsError.status("Create Search accessibility label",accessible) }
            let services=object.assumingMemoryBound(to:IAccPropServices.self); queryAccessibility=services
            let named=withWideString(localization.text("Search apps, files, or calculate")) {
                services.pointee.lpVtbl.pointee.SetHwndPropStr(services,edit,DWORD(bitPattern:searchClientObject),0,Self.queryNameProperty,$0)
            }
            guard named >= 0 else { throw WindowsError.status("Label Search input",named) }
            guard SetWindowSubclass(edit,searchEditProcedure,1,DWORD_PTR(UInt(bitPattern:Unmanaged.passUnretained(self).toOpaque()))) else {
                throw WindowsError.api("Prepare native search composition",GetLastError())
            }
        }
        try refreshCategories(); try theme(); try typography(); try updateIcons(); arrange()
        for id in [3,5,6] { EnableWindow(controls[id], false) }
    }
    @discardableResult private func child(_ kind: String, _ text: String, _ id: Int, style: DWORD = 0) throws -> HWND {
        let created = withWideString(kind) { kind in withWideString(localization.text(text)) {
            CreateWindowExW(0, kind, $0, DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS) | style, 0, 0, 1, 1, window, HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
        } }
        guard let created else { throw WindowsError.api("Create search control", GetLastError()) }
        controls[id] = created; return created
    }
    private func checkThread() { precondition(GetCurrentThreadId() == uiThread, "Search UI must be updated on its owning thread") }
    private func setText(_ id: Int, _ text: String) { if let control = controls[id], self.text(id) != text { _ = withWideString(text) { SetWindowTextW(control, $0) } } }
    private func label(_ id: Int, _ english: String) { setText(id,localization.text(english)) }
    private func refreshCategories() throws {
        guard let services=queryAccessibility else { return }
        for (index, item) in SearchCategory.allCases.enumerated() {
            guard let button=controls[20+index] else { continue }
            let name=localization.text(item == .applications ? "Apps" : item.title) + (item==displayedCategory ? ", " + localization.text("Selected category") : "")
            let named=withWideString(name) {
                services.pointee.lpVtbl.pointee.SetHwndPropStr(services,button,DWORD(bitPattern:searchClientObject),0,Self.queryNameProperty,$0)
            }
            guard named >= 0 else { throw WindowsError.status("Label Search category",named) }
            InvalidateRect(button,nil,false)
        }
    }
    private func withoutCategoryPrefix(_ text:String) -> String {
        let trimmed=text.drop(while:\.isWhitespace), lower=trimmed.lowercased()
        for prefix in SearchCategory.allCases.map(\.prefix).filter({ !$0.isEmpty }) + ["applications:"] {
            if lower.hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count).drop(while:\.isWhitespace)) }
        }
        return text
    }
    /// A category change preserves the query and its content filters, and cancels retained actions.
    func selectCategory(_ next:SearchCategory) {
        checkThread(); guard !composing else { return }
        let visible=withoutCategoryPrefix(text(1))
        guard next != category || visible != text(1) else { return }
        category=next
        if visible != text(1) {
            changingQuery=true; setText(1,visible); changingQuery=false
            SendMessageW(controls[1],UINT(EM_SETSEL),WPARAM(visible.utf16.count),LPARAM(visible.utf16.count))
        }
        SetFocus(controls[1]); queryChanged()
    }
    private func updateQueryHint() {
        guard let hint=controls[17],let field=controls[1] else { return }
        let visible = !composing && GetWindowTextLengthW(field)==0
        if (GetWindowLongPtrW(hint,Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE) != 0) != visible {
            ShowWindow(hint,Int32(visible ? SW_SHOW : SW_HIDE))
        }
    }
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
        if let edit=controls[1] {
            let previousChange=changingQuery; changingQuery=true; defer { changingQuery=previousChange }
            SendMessageW(edit,UINT(EM_SETBKGNDCOLOR),0,LPARAM(backgroundColor))
            var format=CHARFORMATW(); format.cbSize=UINT(MemoryLayout<CHARFORMATW>.size)
            format.dwMask=DWORD(CFM_COLOR); format.crTextColor=textColor
            let formatted=withUnsafePointer(to:&format) { SendMessageW(edit,UINT(EM_SETCHARFORMAT),WPARAM(SCF_ALL),LPARAM(Int(bitPattern:$0))) }
            guard formatted != 0 else { throw WindowsError.unsupported("Windows Search input colors could not be refreshed.") }
        }
        materialSize = nil
        arrange()
        if let window { RedrawWindow(window,nil,nil,UINT(RDW_INVALIDATE | RDW_ALLCHILDREN)) }
    }
    private func typography() throws {
        let previousChange=changingQuery; changingQuery=true; defer { changingQuery=previousChange }
        var replacements: [HFONT] = []
        for (size, weight) in [(13, 400), (28, 400), (16, 600), (12, 400), (28, 600)] {
            guard let font = withWideString("Segoe UI", { CreateFontW(-Int32(Double(size) * scale), 0, 0, 0, Int32(weight), 0, 0, 0,
                DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0) }) else {
                let error = GetLastError(); replacements.forEach { DeleteObject($0) }; throw WindowsError.api("Create search typography", error)
            }
            replacements.append(font)
        }
        let previous = fonts; fonts = replacements
        for (id, control) in controls {
            let role = id == 1 || id == 17 ? 1 : id == 13 ? 4 : id == 11 || id == 12 ? 2 : id == 16 ? 3 : 0
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[role])), 1)
        }
        if let list = controls[2] { SendMessageW(list, UINT(LB_SETITEMHEIGHT), 0, LPARAM(Int32(58 * scale))) }
        previous.forEach { DeleteObject($0) }
    }
    private func updateIcons() throws {
        guard let window else { return }
        let large = try ApplicationIcon(size: Int32(48 * scale))
        let small = try ApplicationIcon(size: GetSystemMetricsForDpi(Int32(SM_CXSMICON), GetDpiForWindow(window)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: large.handle)))
        SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: small.handle)))
        SendMessageW(controls[10], UINT(STM_SETICON), WPARAM(UInt(bitPattern: large.handle)), 0)
        brand = large; caption = small
    }
    private func arrange() {
        guard let window else { return }
        var client = RECT(); GetClientRect(window, &client)
        let width = Int(Double(client.right) / scale), height = Int(Double(client.bottom) / scale)
        let showPreview = previewExpanded && height >= 274
        let split = showPreview ? max(268, width * 56 / 100) : width, footer = max(128, height - 40)
        let hasResults = !results.isEmpty
        let dpi = GetDpiForWindow(window)
        let layout = (client.right,client.bottom,dpi,showPreview,hasResults)
        let layoutChanged = arranged.map { $0 != layout } ?? true
        if layoutChanged {
            arranged = layout
            label(16,width < 680 ? "Enter Open • Esc Close" : "Enter Open • Tab Actions • Esc Close")
            for (id, x, y, w, h) in [(10,26,28,24,24),(1,66,22,width-94,40),(11,0,0,1,1),(17,74,22,width-110,40),
                (20,26,68,70,28),(21,102,68,92,28),(22,200,68,82,28),(23,288,68,96,28),
                (2,14,128,split-28,max(1,footer-134)),(12,0,0,1,1),(13,split+18,130,width-split-40,42),
                (14,split+18,186,width-split-40,max(1,footer-194)),(15,26,102,width-52,18),(16,24,footer+8,max(1,width-356),22),
                (6,width-304,footer+3,68,30),(3,width-232,footer+3,82,30),(5,width-146,footer+3,64,30),(4,width-78,footer+3,60,30)] {
                if let control = controls[id] {
                    let hiddenPreview = (id == 13 || id == 14) && !showPreview
                    let left=hiddenPreview ? 0 : Int32(Double(x)*scale), top=hiddenPreview ? 0 : Int32(Double(y)*scale)
                    let size=(hiddenPreview ? 1 : Int32(Double(max(1,w))*scale),hiddenPreview ? 1 : Int32(Double(max(1,h))*scale))
                    var actual=RECT(); GetWindowRect(control,&actual)
                    _=withUnsafeMutablePointer(to:&actual) { $0.withMemoryRebound(to:POINT.self,capacity:2) { MapWindowPoints(nil,window,$0,2) } }
                    if (actual.left,actual.top,actual.right-actual.left,actual.bottom-actual.top) != (left,top,size.0,size.1) {
                        MoveWindow(control,left,top,size.0,size.1,true)
                    }
                }
            }
            func visibility(_ id:Int,_ visible:Bool) {
                guard let control=controls[id] else { return }
                if (GetWindowLongPtrW(control,Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE) != 0) != visible {
                    ShowWindow(control,Int32(visible ? SW_SHOW : SW_HIDE))
                }
            }
            for id in [11,12] { visibility(id,false) }
            if GetWindow(controls[17],UINT(GW_HWNDPREV)) != controls[10] {
                SetWindowPos(controls[17],controls[10],0,0,0,0,UINT(SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE))
            }
            updateQueryHint()
            visibility(2,hasResults)
            for id in [13,14] { visibility(id,showPreview) }
            for id in [3,5,6,16] { visibility(id,hasResults) }
        }
        let shape = (client.right,client.bottom,dpi)
        // Windows owns the region on success; no layered desktop surface is created.
        if shaped.map({ $0 != shape }) ?? true,
            let region = CreateRoundRectRgn(0,0,client.right+1,client.bottom+1,Int32(36*scale),Int32(36*scale)) {
            if SetWindowRgn(window,region,true)==0 { DeleteObject(region) } else { shaped = shape }
        }
        let material = (client.right,client.bottom,dpi,highContrast)
        if let backdrop, materialSize.map({ $0 != material }) ?? true {
            materialSize = backdrop.resize(width:client.right,height:client.bottom,cornerRadius:18*scale,highContrast:highContrast) ? material : nil
        }
        if layoutChanged { RedrawWindow(window, nil, nil, UINT(RDW_INVALIDATE | RDW_NOCHILDREN)) }
    }
    private func fitHeight() {
        guard let window, IsWindowVisible(window) else { arrange(); return }
        var area=RECT(); GetWindowRect(window,&area)
        var monitor=MONITORINFO(); monitor.cbSize=DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(MonitorFromWindow(window,DWORD(MONITOR_DEFAULTTONEAREST)),&monitor) else { arrange(); return }
        let resultHeight = results.isEmpty ? 168 : 174+min(results.count,6)*58
        let desired = previewExpanded ? max(374,resultHeight) : resultHeight
        let requested = Int32((Double(desired)*scale).rounded(.up))
        let reset=category == .all && text(1).allSatisfy(\.isWhitespace)
        let stable = reset ? requested : max(requested,area.bottom-area.top)
        let height=min(stable,monitor.rcWork.bottom-area.top)
        if height != area.bottom-area.top { SetWindowPos(window,nil,0,0,area.right-area.left,max(Int32(166*scale),height),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE)) }
        else { arrange() }
    }
    func prepareMaterial() {
        checkThread(); guard let window else { return }
        if !materialAttempted {
            materialAttempted = true
            do { backdrop = try NativeSearchBackdrop(parent:window) }
            catch { Diagnostics.write("Search material unavailable; using native opaque surface: \(error)") }
        }
    }
    func show(query: String = "") throws {
        checkThread(); guard let window else { return }
        guard query.utf16.count <= 1024, !query.utf16.contains(0) else { throw WindowsError.unsupported("Search query exceeds its limit.") }
        prepareMaterial()
        var monitor = MONITORINFO(); monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        let screen = MonitorFromWindow(GetForegroundWindow(), DWORD(MONITOR_DEFAULTTONEAREST))
        guard GetMonitorInfoW(screen, &monitor) else { throw WindowsError.api("Locate search panel monitor", GetLastError()) }
        let area = monitor.rcWork
        // Moving first lets WM_DPICHANGED update fonts/icons before sizing for the destination monitor.
        SetWindowPos(window,nil,area.left,area.top,0,0,UINT(SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE))
        let width = min(Int32(720 * scale), area.right-area.left), height = min(Int32((168 * scale).rounded(.up)), area.bottom-area.top)
        SetWindowPos(window, nil, area.left+(area.right-area.left-width)/2, area.top+(area.bottom-area.top-height)/3,
            width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        results = []; resultStrings = []; queryPending = false; previewExpanded = false
        if let list = controls[2] { SendMessageW(list,UINT(LB_RESETCONTENT),0,0) }
        changingQuery = true; setText(1, query); changingQuery = false
        arrange()
        ShowWindow(window, Int32(SW_SHOW)); SetForegroundWindow(window); SetFocus(controls[1]); queryChanged()
    }
    func hide() {
        checkThread(); guard !dismissing else { return }
        dismissing=true; defer { dismissing=false }
        generation &+= 1; queryPending = true; previewID = nil; producer?.cancelPreview()
        if let window { ShowWindow(window, Int32(SW_HIDE)) }; onDismiss()
    }
    private func queryChanged() {
        // Keep the last layout while providers work; no retained result is actionable.
        generation &+= 1; queryPending = true; previewID = nil; producer?.cancelPreview()
        updateQueryHint()
        for id in [3,5,6] { EnableWindow(controls[id], false) }
        let query=text(1)
        let submitted=category == .all ? query : category.prefix + " " + withoutCategoryPrefix(query)
        let scope=SearchQuery(submitted).category
        if displayedCategory != scope {
            displayedCategory=scope
            do { try refreshCategories() } catch { label(15,"Search category could not be displayed.") }
        }
        onQuery(submitted)
        if queryPending, !pendingStatusQueued, let window {
            // Quick replies can settle before the pending label is drawn; keep one queued notice.
            pendingStatusQueued = PostMessageW(window,searchPendingMessage,0,0)
            if !pendingStatusQueued { label(15,"Searching…") }
        }
    }
    fileprivate func compositionChanged(_ active: Bool) {
        composing = active
        updateQueryHint()
        if !active, !dismissing, let window, IsWindowVisible(window) { queryChanged() }
    }
    private var selected: NativeSearchResult? {
        guard !queryPending, let list = controls[2] else { return nil }
        let index = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
        return results.indices.contains(index) ? results[index] : nil
    }
    @discardableResult func apply(_ snapshot: NativeSearchSnapshot) throws -> Bool {
        checkThread(); guard snapshot.generation == generation else { return false }
        guard snapshot.isValid else { throw WindowsError.unsupported("Invalid search result snapshot.") }
        let previousID = selected?.id, requestedPreview=previewID
        let strings = snapshot.results.map(accessibleText)
        let rowsChanged = results != snapshot.results || resultStrings != strings, wasPending = queryPending
        let topIndex = controls[2].map { Int(SendMessageW($0,UINT(LB_GETTOPINDEX),0,0)) } ?? 0
        results = snapshot.results
        do {
            let pausedList = rowsChanged ? controls[2] : nil
            if let pausedList { SendMessageW(pausedList,UINT(WM_SETREDRAW),0,0) }
            defer {
                if let pausedList {
                    SendMessageW(pausedList,UINT(WM_SETREDRAW),1,0)
                    if results.isEmpty { ShowWindow(pausedList,Int32(SW_HIDE)) }
                    RedrawWindow(pausedList,nil,nil,UINT(RDW_ERASE|RDW_FRAME|RDW_INVALIDATE))
                }
            }
            if rowsChanged, let list = controls[2] {
                SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0)
                for string in strings {
                    let added = withWideString(string) { SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
                    if added < 0 { results = []; resultStrings = []; SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0); throw WindowsError.api("Populate native search results", GetLastError()) }
                }
                resultStrings = strings
            }
            queryPending = false
            if wasPending { previewExpanded = false }
            if rowsChanged || wasPending, let list = controls[2], !results.isEmpty {
                let selection = results.firstIndex(where: { $0.id == previousID }) ?? 0
                if SendMessageW(list,UINT(LB_GETCURSEL),0,0) != LRESULT(selection) {
                    SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(selection), 0)
                }
                if !wasPending, results.indices.contains(topIndex) {
                    var row=RECT(), bounds=RECT(); GetClientRect(list,&bounds)
                    _=withUnsafeMutablePointer(to:&row) { SendMessageW(list,UINT(LB_GETITEMRECT),WPARAM(selection),LPARAM(Int(bitPattern:$0))) }
                    let rowHeight=max(1,Int(row.bottom-row.top)), visibleRows=max(1,Int(bounds.bottom)/rowHeight)
                    if selection >= topIndex, selection < topIndex+visibleRows { SendMessageW(list,UINT(LB_SETTOPINDEX),WPARAM(topIndex),0) }
                }
            }
        }
        previewID=requestedPreview==selected?.id ? requestedPreview : nil
        if previewID==nil { producer?.cancelPreview() }
        for id in [3,5,6] { EnableWindow(controls[id], !results.isEmpty) }; setText(15, ownedParts(snapshot.status))
        if previewID==nil {
            setText(13, selected.map { $0.id=="answer" ? snapshot.quickAnswer ?? $0.title : displayedTitle($0) } ?? snapshot.quickAnswer ?? localization.text("No results"))
            setText(14, selected.map(displayedSubtitle) ?? localization.text("Try another query."))
        }
        fitHeight()
        return true
    }
    @discardableResult func applyPreview(generation: UInt64, resultID: String, title: String, text: String) throws -> Bool {
        checkThread(); guard generation == self.generation, resultID == selected?.id, resultID == previewID else { return false }
        guard title.utf16.count <= 4096, text.utf16.count <= 4096, !title.utf16.contains(0), !text.utf16.contains(0) else { throw WindowsError.unsupported("Preview text exceeds its limit.") }
        setText(13,selected.map(ownsTitle) == true ? localization.text(title) : title)
        setText(14,selected.map(ownsSubtitle) == true ? ownedParts(text) : text); return true
    }
    private func selectionChanged() {
        guard !queryPending else { return }
        previewID = nil; producer?.cancelPreview(); setText(13, selected.map(displayedTitle) ?? localization.text("No results")); setText(14, selected.map(displayedSubtitle) ?? localization.text("Try another query."))
        if let list = controls[2], let result = selected, let index = results.firstIndex(where: { $0.id == result.id }) {
            NotifyWinEvent(DWORD(EVENT_OBJECT_SELECTION), list, searchClientObject, LONG(index+1))
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !queryPending, let list = controls[2], !results.isEmpty else { return }
        let current = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
        SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(max(0,min(results.count-1,current+delta))), 0); selectionChanged()
    }
    private func activate() { guard let selected else { return }; onActivate(selected.id); hide() }
    private func preview() {
        guard let selected else { return }; previewID = selected.id
        previewExpanded=true; fitHeight()
        producer?.expectPreview(generation:generation,resultID:selected.id)
        label(14, "Loading preview…"); onPreview(selected.id)
    }
    private func copy() { guard let selected else { return }; onCopy(selected.id) }
    private func reveal() { guard let selected, ["File","Folder","Application"].contains(selected.kind) else { return }; onReveal(selected.id) }
    private enum ResultAction: Int, CaseIterable { case open=1, preview, copy, reveal }
    private func resultActions() -> [(ResultAction,String)] {
        guard let selected, !composing else { return [] }
        let local=["File","Folder","Application"].contains(selected.kind)
        var actions: [(ResultAction,String)] = selected.id=="answer" ? [] : [(.open,"Open")]
        actions.append((.preview,"Preview"))
        actions.append((.copy,local ? "Copy path" : "Copy result"))
        if local { actions.append((.reveal,"Reveal in File Explorer")) }
        return actions
    }
    private func perform(_ action:ResultAction, generation:UInt64, resultID:String) {
        guard generation==self.generation, selected?.id==resultID,
            resultActions().contains(where:{$0.0==action}) else { return }
        switch action {
        case .open: activate()
        case .preview: preview()
        case .copy: copy()
        case .reveal: reveal()
        }
    }
    @discardableResult private func resultMenu(at point:POINT?=nil) -> Bool {
        let actions=resultActions()
        guard let window, let selected, !actions.isEmpty, let menu=CreatePopupMenu() else { return false }
        defer { DestroyMenu(menu) }
        for (action, title) in actions {
            let added=withWideString(localization.text(title)) { AppendMenuW(menu,UINT(MF_STRING),UINT_PTR(action.rawValue),$0) }
            guard added else { label(15,"Result actions could not be displayed."); return true }
        }
        var anchor=point ?? POINT()
        if point==nil, let list=controls[2] {
            let index=SendMessageW(list,UINT(LB_GETCURSEL),0,0)
            var row=RECT()
            _=withUnsafeMutablePointer(to:&row) { SendMessageW(list,UINT(LB_GETITEMRECT),WPARAM(index),LPARAM(Int(bitPattern:$0))) }
            anchor=POINT(x:row.left+Int32(20*scale),y:row.top+Int32(20*scale))
            MapWindowPoints(list,nil,&anchor,1)
        }
        let expected=generation, resultID=selected.id
        let choice=BC_TrackPopupMenu(menu,UINT(TPM_RETURNCMD|TPM_RIGHTBUTTON),anchor.x,anchor.y,0,window,nil)
        if let action=ResultAction(rawValue:Int(choice)) { perform(action,generation:expected,resultID:resultID) }
        return true
    }
    private func copyAnswerFromEdit() -> Bool {
        guard let edit=controls[1], selected?.id=="answer" else { return false }
        var start:DWORD=0, end:DWORD=0
        withUnsafeMutablePointer(to:&start) { start in withUnsafeMutablePointer(to:&end) { end in
            _=SendMessageW(edit,UINT(EM_GETSEL),WPARAM(UInt(bitPattern:start)),LPARAM(Int(bitPattern:end)))
        } }
        guard start==end else { return false }
        copy(); return true
    }
    private func requestsResultMenu(_ key:WPARAM,target:HWND,control:Bool,shift:Bool) -> Bool {
        !composing && (target == controls[1] || target == controls[2]) && !resultActions().isEmpty &&
            (key == WPARAM(VK_TAB) && !control && !shift || key == WPARAM(VK_F10) && shift || key == WPARAM(VK_APPS))
    }
    private func key(_ key: WPARAM, target: HWND, control:Bool?=nil, shift:Bool?=nil) -> Bool {
        let control=control ?? (GetKeyState(Int32(VK_CONTROL)) < 0)
        let shift=shift ?? (GetKeyState(Int32(VK_SHIFT)) < 0)
        if target == controls[1], composing { return false }
        if control, !shift, key >= 0x30, key <= 0x33 {
            selectCategory(SearchCategory.allCases[Int(key-0x30)]); return true
        }
        if requestsResultMenu(key,target:target,control:control,shift:shift) { return resultMenu() }
        if key == WPARAM(0x52), control, target == controls[1] || target == controls[2] { reveal(); return true }
        if key == WPARAM(VK_ESCAPE) { hide(); return true }
        if key == WPARAM(VK_RETURN), target == controls[1] || target == controls[2] {
            if control { reveal() } else { activate() }; return true
        }
        if key == WPARAM(VK_DOWN), target == controls[1] || target == controls[2] { moveSelection(1); return true }
        if key == WPARAM(VK_UP), target == controls[1] || target == controls[2] { moveSelection(-1); return true }
        if key == WPARAM(VK_SPACE), target == controls[2] { preview(); return true }
        if key == WPARAM(0x43), control {
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
        case searchPendingMessage:
            pendingStatusQueued = false
            if queryPending, !dismissing, IsWindowVisible(window) { label(15,"Searching…") }
            return 0
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
            if id == 1, notification == Int(EN_CHANGE) {
                updateQueryHint()
                if !changingQuery, !composing { queryChanged() }
            }
            if id == 17, notification == Int(STN_CLICKED) { SetFocus(controls[1]) }
            if id == 2, notification == Int(LBN_SELCHANGE) { selectionChanged() }
            if id == 2, notification == Int(LBN_DBLCLK) { activate() }
            if id == 3, notification == Int(BN_CLICKED) { preview() }
            if id == 5, notification == Int(BN_CLICKED) { copy() }
            if id == 6, notification == Int(BN_CLICKED) { activate() }
            if id == 4, notification == Int(BN_CLICKED) { hide() }
            if notification == Int(BN_CLICKED), (20...23).contains(id) { selectCategory(SearchCategory.allCases[id-20]) }
            return 0
        case UINT(WM_CONTEXTMENU):
            if HWND(bitPattern:Int(value))==controls[2], !composing {
                if data == -1 { _=resultMenu() }
                else {
                    let point=POINT(x:LONG(Int16(truncatingIfNeeded:data & 0xffff)),y:LONG(Int16(truncatingIfNeeded:(data >> 16) & 0xffff)))
                    var local=point
                    MapWindowPoints(nil,controls[2],&local,1)
                    let index=SendMessageW(controls[2],UINT(LB_ITEMFROMPOINT),0,LPARAM((Int(local.y)&0xffff)<<16 | (Int(local.x)&0xffff)))
                    if index >> 16 == 0, !queryPending {
                        var row=RECT()
                        let found=withUnsafeMutablePointer(to:&row) { SendMessageW(controls[2],UINT(LB_GETITEMRECT),WPARAM(index & 0xffff),LPARAM(Int(bitPattern:$0))) }
                        if found != LRESULT(LB_ERR), PtInRect(&row,local) {
                            SendMessageW(controls[2],UINT(LB_SETCURSEL),WPARAM(index & 0xffff),0); selectionChanged(); _=resultMenu(at:point)
                        }
                    }
                }
                return 0
            }
        case UINT(WM_CLOSE): hide(); return 0
        case UINT(WM_ACTIVATE):
            if !designPreview, value & 0xffff == WPARAM(WA_INACTIVE), IsWindowVisible(window) {
                let next=HWND(bitPattern:Int(data))
                if next==nil || GetAncestor(next,UINT(GA_ROOTOWNER)) != window { hide() }
            }; break
        case UINT(WM_GETMINMAXINFO):
            if let info=UnsafeMutablePointer<MINMAXINFO>(bitPattern:Int(data)) {
                let minimum = previewExpanded ? 374 : results.isEmpty ? 166 : 232
                info.pointee.ptMinTrackSize=POINT(x:Int32(560*scale),y:Int32((Double(minimum)*scale).rounded(.up)))
            }; return 0
        case UINT(WM_NCCALCSIZE): return 0
        case UINT(WM_NCHITTEST):
            var area=RECT(); GetWindowRect(window,&area)
            let x=Int32(Int16(truncatingIfNeeded:data & 0xffff))-area.left
            let y=Int32(Int16(truncatingIfNeeded:(data >> 16) & 0xffff))-area.top
            let edge=Int32(7*scale), left=x<edge, right=x>=area.right-area.left-edge, top=y<edge, bottom=y>=area.bottom-area.top-edge
            if top && left { return LRESULT(HTTOPLEFT) }; if top && right { return LRESULT(HTTOPRIGHT) }
            if bottom && left { return LRESULT(HTBOTTOMLEFT) }; if bottom && right { return LRESULT(HTBOTTOMRIGHT) }
            if left { return LRESULT(HTLEFT) }; if right { return LRESULT(HTRIGHT) }
            if top { return LRESULT(HTTOP) }; if bottom { return LRESULT(HTBOTTOM) }
            return y<Int32(20*scale) ? LRESULT(HTCAPTION) : LRESULT(HTCLIENT)
        case UINT(WM_SIZE): arrange(); return 0
        case UINT(WM_DPICHANGED):
            if let area = UnsafePointer<RECT>(bitPattern: Int(data))?.pointee { SetWindowPos(window,nil,area.left,area.top,area.right-area.left,area.bottom-area.top,UINT(SWP_NOZORDER|SWP_NOACTIVATE)) }
            do { try typography(); try updateIcons() } catch { label(15,"Search appearance could not be refreshed.") }; arrange(); return 0
        case UINT(WM_SETTINGCHANGE), UINT(WM_SYSCOLORCHANGE), UINT(WM_THEMECHANGED):
            do { try theme() } catch { label(15,"Search colors could not be refreshed.") }; return 0
        case UINT(WM_MEASUREITEM):
            if let item = UnsafeMutablePointer<MEASUREITEMSTRUCT>(bitPattern:Int(data)) { item.pointee.itemHeight = UINT(58*scale); return 1 }
        case UINT(WM_DRAWITEM):
            if let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern:Int(data))?.pointee {
                if item.CtlID==2 { drawRow(item) } else { drawButton(item) }; return 1
            }
        case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLOREDIT), UINT(WM_CTLCOLORLISTBOX):
            guard let dc = HDC(bitPattern:UInt(value)), !brushes.isEmpty else { return 0 }
            SetBkMode(dc,Int32(TRANSPARENT)); SetTextColor(dc,message == UINT(WM_CTLCOLORSTATIC) ? secondaryColor : textColor)
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
        let pen=CreatePen(Int32(PS_SOLID),1,borderColor), oldPen=SelectObject(dc,pen), oldBrush=SelectObject(dc,GetStockObject(Int32(NULL_BRUSH)))
        RoundRect(dc,0,0,area.right-1,area.bottom-1,Int32(36*scale),Int32(36*scale))
        if backdrop != nil {
            let inset=Int32(8*scale)
            RoundRect(dc,inset,inset,area.right-inset,area.bottom-inset,Int32(24*scale),Int32(24*scale))
        }
        if !results.isEmpty { MoveToEx(dc,Int32(22*scale),Int32(124*scale),nil); LineTo(dc,area.right-Int32(22*scale),Int32(124*scale)) }
        SelectObject(dc,oldBrush); SelectObject(dc,oldPen); DeleteObject(pen)
    }
    private func drawBuffered(_ target: HDC, in area: RECT, _ draw: (HDC) -> Bool) {
        var area=area, drawing:HDC?
        guard bufferedPainting, let buffer=BeginBufferedPaint(target,&area,BPBF_COMPATIBLEBITMAP,nil,&drawing) else { _=draw(target); return }
        guard let drawing else { _=EndBufferedPaint(buffer,false); _=draw(target); return }
        let completed=draw(drawing), committed=EndBufferedPaint(buffer,completed)
        if !completed || committed < 0 { _=draw(target) }
    }
    private func drawRow(_ item: DRAWITEMSTRUCT) {
        guard let target=item.hDC else { return }
        drawBuffered(target,in:item.rcItem) { dc in
            var item=item; item.hDC=dc; return drawRowContent(item)
        }
    }
    private func drawRowContent(_ item: DRAWITEMSTRUCT) -> Bool {
        guard let dc=item.hDC, brushes.count==3,fonts.count==5 else { return false }
        let saved=SaveDC(dc); guard saved != 0 else { return false }
        defer { RestoreDC(dc,saved) }
        var area=item.rcItem
        let index=Int(item.itemID), selected=item.itemState & UINT(ODS_SELECTED) != 0
        FillRect(dc,&area,brushes[1]); guard results.indices.contains(index) else { return true }
        if selected {
            let oldBrush=SelectObject(dc,brushes[2]),oldPen=SelectObject(dc,GetStockObject(Int32(NULL_PEN)))
            RoundRect(dc,area.left+Int32(4*scale),area.top+Int32(2*scale),area.right-Int32(4*scale),area.bottom-Int32(2*scale),Int32(20*scale),Int32(20*scale))
            SelectObject(dc,oldBrush); SelectObject(dc,oldPen)
        }
        let result=results[index], color=highContrast && selected ? GetSysColor(Int32(COLOR_HIGHLIGHTTEXT)) : textColor
        SetBkMode(dc,Int32(TRANSPARENT)); SetTextColor(dc,color)
        SelectObject(dc,fonts[2])
        var title=RECT(left:area.left+Int32(14*scale),top:area.top+Int32(8*scale),right:area.right-Int32(14*scale),bottom:area.top+Int32(31*scale))
        _=withWideString(displayedTitle(result)) { DrawTextW(dc,$0,-1,&title,UINT(DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX)) }
        SelectObject(dc,fonts[3]); SetTextColor(dc,highContrast && selected ? color : secondaryColor)
        var subtitle=RECT(left:title.left,top:area.top+Int32(34*scale),right:title.right,bottom:area.bottom-Int32(5*scale))
        _=withWideString(localization.text(result.kind) + "  ·  " + displayedSubtitle(result)) { DrawTextW(dc,$0,-1,&subtitle,UINT(DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX)) }
        if item.itemState & UINT(ODS_FOCUS) != 0 { InflateRect(&area,-3,-3); DrawFocusRect(dc,&area) }
        return true
    }
    private func drawButton(_ item:DRAWITEMSTRUCT) {
        guard let target=item.hDC else { return }
        drawBuffered(target,in:item.rcItem) { dc in
            var item=item; item.hDC=dc; return drawButtonContent(item)
        }
    }
    private func drawButtonContent(_ item:DRAWITEMSTRUCT) -> Bool {
        guard let dc=item.hDC, controls[Int(item.CtlID)] != nil, !fonts.isEmpty, brushes.count==3 else { return false }
        let saved=SaveDC(dc); guard saved != 0 else { return false }; defer { RestoreDC(dc,saved) }
        var area=item.rcItem; FillRect(dc,&area,brushes[0])
        let categoryIndex=Int(item.CtlID)-20
        let selectedCategory=SearchCategory.allCases.indices.contains(categoryIndex) && SearchCategory.allCases[categoryIndex]==displayedCategory
        let disabled=item.itemState & UINT(ODS_DISABLED) != 0, pressed=item.itemState & UINT(ODS_SELECTED) != 0 || selectedCategory
        let brush=SelectObject(dc,brushes[pressed ? 2 : 0]), pen=CreatePen(Int32(PS_SOLID),1,borderColor),oldPen=SelectObject(dc,pen)
        RoundRect(dc,area.left+1,area.top+1,area.right-1,area.bottom-1,Int32(22*scale),Int32(22*scale))
        SelectObject(dc,brush); SelectObject(dc,oldPen); DeleteObject(pen)
        let color=highContrast && pressed ? GetSysColor(Int32(COLOR_HIGHLIGHTTEXT)) : textColor
        SetBkMode(dc,Int32(TRANSPARENT)); SetTextColor(dc,disabled ? GetSysColor(Int32(COLOR_GRAYTEXT)) : color); SelectObject(dc,fonts[0])
        let label=text(Int(item.CtlID)); _=withWideString(label) { DrawTextW(dc,$0,-1,&area,UINT(DT_CENTER|DT_VCENTER|DT_SINGLELINE)) }
        if item.itemState & UINT(ODS_FOCUS) != 0 { InflateRect(&area,-4,-4); DrawFocusRect(dc,&area) }
        return true
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
        guard read >= 0, let name else {
            var kind=[WCHAR](repeating:0,count:64); let count=GetClassNameW(window,&kind,64)
            throw WindowsError.unsupported("Native \(String(decoding:kind.prefix(Int(count)),as:UTF16.self)) control has no accessible name.")
        }
        return String(decoding:UnsafeBufferPointer(start:name,count:Int(SysStringLen(name))),as:UTF16.self)
    }
    /// Explicit visible own-window check; no input hooks, display changes or external actions.
    static func layeringCheck() throws {
        func expect(_ value: Bool,_ message: String) throws { guard value else { throw WindowsError.unsupported("Search layering check failed: " + message) } }
        var panel: NativeSearchWindow? = try NativeSearchWindow(localization:Localization(pack:.english),designPreview:true,
            onQuery:{ _ in },onActivate:{ _ in },onPreview:{ _ in },onCopy:{ _ in })
        defer { panel=nil; NativeSearchBackdrop.shutdown() }
        guard let window=panel?.window else { throw WindowsError.unsupported("Search fixture is unavailable.") }
        try panel?.show(query:"2+3*4")
        guard let background=panel?.backdrop?.window else { throw WindowsError.unsupported("Search material is unavailable for the active layering check.") }
        let snapshot=NativeSearchSnapshot(generation:panel!.generation,
            results:[NativeSearchResult(id:"answer",title:"14",subtitle:"2 + 3 * 4",kind:"Calculator")],status:"Native layering check",quickAnswer:"14")
        _=try panel?.apply(snapshot)
        // This explicit interactive fixture remains above other windows while checking native DC regions.
        SetWindowPos(window,HWND(bitPattern:-1),0,0,0,0,UINT(SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE))
        for expanded in [false,true,false] {
            panel?.previewExpanded=expanded; panel?.fitHeight()
            let deadline=GetTickCount64()+250
            repeat {
                var message=MSG()
                var count=0
                while count<1024,GetTickCount64()<deadline,PeekMessageW(&message,nil,0,0,UINT(PM_REMOVE)) {
                    count += 1
                    if message.message==UINT(WM_QUIT) { PostQuitMessage(Int32(truncatingIfNeeded:message.wParam)); throw WindowsError.unsupported("Search layering fixture was closed.") }
                    TranslateMessage(&message); DispatchMessageW(&message)
                }
                _=MsgWaitForMultipleObjectsEx(0,nil,10,DWORD(QS_ALLINPUT),DWORD(MWMO_INPUTAVAILABLE))
            } while GetTickCount64()<deadline
            try expect(IsWindowVisible(window),"fixture must be visible")
            guard let backgroundDC=GetDC(background) else { throw WindowsError.api("Read Search material clipping",GetLastError()) }
            defer { ReleaseDC(background,backgroundDC) }
            var client=RECT(); GetClientRect(window,&client)
            try expect(PtVisible(backgroundDC,client.right/2,Int32(4*panel!.scale)),"material perimeter remains visible")
            try expect(!PtVisible(backgroundDC,Int32(18*panel!.scale),Int32(88*panel!.scale)),"native content card excludes interior material")
            for (id,control) in panel!.controls where GetWindowLongPtrW(control,Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE) != 0 {
                var area=RECT(); GetClientRect(control,&area)
                let center=POINT(x:area.right/2,y:area.bottom/2)
                var backgroundPoint=center; MapWindowPoints(control,background,&backgroundPoint,1)
                try expect(!PtVisible(backgroundDC,backgroundPoint.x,backgroundPoint.y),"material excludes native control \(id)")
                guard let controlDC=GetDC(control) else { throw WindowsError.api("Read Search control clipping",GetLastError()) }
                let visible=PtVisible(controlDC,center.x,center.y); ReleaseDC(control,controlDC)
                try expect(visible,"native control \(id) remains visible")
            }
        }
        for count in [6,1,3,0] {
            var before=RECT(); GetWindowRect(window,&before)
            panel?.setText(1,"query \(count)")
            let rows=(0..<count).map { NativeSearchResult(id:"row:\($0)",title:"Example \($0)",subtitle:"Text",kind:"File") }
            _=try panel?.apply(NativeSearchSnapshot(generation:panel!.generation,results:rows,status:"Stable frame",quickAnswer:nil))
            var after=RECT(); GetWindowRect(window,&after)
            try expect(after.bottom-after.top >= before.bottom-before.top,"successive nonempty queries do not shrink frame")
        }
        panel?.setText(1,"")
        panel?.selectCategory(.files)
        for count in [6,1,0] {
            var before=RECT(); GetWindowRect(window,&before)
            let rows=(0..<count).map { NativeSearchResult(id:"row:\($0)",title:"Example \($0)",subtitle:"Text",kind:"File") }
            _=try panel?.apply(NativeSearchSnapshot(generation:panel!.generation,results:rows,status:"Empty scoped catalog",quickAnswer:nil))
            var after=RECT(); GetWindowRect(window,&after)
            try expect(after.bottom-after.top==before.bottom-before.top,"empty scoped catalog updates preserve the established frame")
        }
        panel?.selectCategory(.all)
        _=try panel?.apply(NativeSearchSnapshot(generation:panel!.generation,results:[],status:"Search apps and files",quickAnswer:nil))
        var cleared=RECT(); GetWindowRect(window,&cleared)
        try expect(cleared.bottom-cleared.top==Int32((168*panel!.scale).rounded(.up)),"cleared query resets compact frame")
        Console.writeLine("PASS: active material excludes input/results/preview/actions at their native visible regions through expansion and collapse")
    }
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
            for (id,control) in panel.controls {
                var area=RECT(); GetWindowRect(control,&area)
                _=withUnsafeMutablePointer(to:&area) { $0.withMemoryRebound(to:POINT.self,capacity:2) { MapWindowPoints(nil,window,$0,2) } }
                try expect(area.left >= 0 && area.top >= 0 && area.right <= client.right && area.bottom <= client.bottom,
                    "native control \(id) bounds \(area.left),\(area.top),\(area.right),\(area.bottom) in \(client.right)×\(client.bottom)")
            }
        }
        try checkBounds()
        for (width,height) in [(560,166),(560,394),(940,654),(720,502)] {
            SetWindowPos(window,nil,0,0,Int32(Double(width)*panel.scale),Int32(Double(height)*panel.scale),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            try checkBounds()
        }
        try expect(!(try accessibleName(edit)).isEmpty && !(try accessibleName(list)).isEmpty,"real edit/list accessible names")
        do {
            var scopedQueries:[String]=[], actions:[String]=[]
            let scoped=try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{scopedQueries.append($0)},
                onActivate:{actions.append("open:"+$0)},onPreview:{actions.append("preview:"+$0)},
                onCopy:{actions.append("copy:"+$0)},onReveal:{actions.append("reveal:"+$0)})
            let field=scoped.controls[1]!, host=scoped.window!, rows=scoped.controls[2]!
            scoped.changingQuery=true; scoped.setText(1,"files:report"); scoped.changingQuery=false
            SendMessageW(field,UINT(EM_SETSEL),2,4)
            ValidateRect(field,nil)
            let prefixedSelection=SendMessageW(field,UINT(EM_GETSEL),0,0)
            scoped.queryChanged()
            try expect(scoped.category == .all && scoped.displayedCategory == .files && scopedQueries.last=="files:report" &&
                scoped.text(1)=="files:report" && SendMessageW(field,UINT(EM_GETSEL),0,0)==prefixedSelection && !GetUpdateRect(field,nil,false),
                "typed file prefix updates only category display and preserves native input text/caret/paint")
            try expect(try accessibleName(scoped.controls[22]!)=="Files, Selected category" && accessibleName(scoped.controls[20]!)=="All",
                "typed file prefix exposes the actual scope through MSAA")
            scoped.selectCategory(.all)
            try expect(scoped.displayedCategory == .all && scoped.text(1)=="report" && scopedQueries.last=="report",
                "All explicitly removes a typed category prefix and resets the displayed scope")
            scoped.setText(1,"files:another report")
            try expect(scoped.displayedCategory == .files,"editing a new category prefix updates its display")
            scoped.setText(1,"another report")
            try expect(scoped.displayedCategory == .all && scoped.category == .all,"deleting a typed prefix returns to All without retaining a hidden scope")
            scoped.setText(1,"files: kind:pdf invoice")
            scoped.selectCategory(.files)
            try expect(scoped.category == .files && scoped.text(1)=="kind:pdf invoice" && scopedQueries.last=="files: kind:pdf invoice",
                "category change removes only a category prefix and preserves file filters")
            try expect(try accessibleName(scoped.controls[22]!)=="Files, Selected category" && accessibleName(scoped.controls[20]!)=="All",
                "category buttons expose their selected category through native MSAA")
            SendMessageW(field,UINT(EM_SETSEL),2,4)
            ValidateRect(field,nil)
            let prior=SendMessageW(field,UINT(EM_GETSEL),0,0)
            scoped.selectCategory(.applications)
            try expect(scoped.text(1)=="kind:pdf invoice" && SendMessageW(field,UINT(EM_GETSEL),0,0)==prior && !GetUpdateRect(field,nil,false),
                "switching a plain category does not redraw, move or replace query text/caret")
            scoped.setText(1,"")
            scoped.selectCategory(.actions)
            try expect(scopedQueries.last=="actions: " && scoped.resultActions().isEmpty,
                "empty category query reaches the catalog and retained actions remain blocked")
            try expect(!scoped.requestsResultMenu(WPARAM(VK_TAB),target:field,control:false,shift:false),"pending/no-result Tab keeps native traversal")
            let count=scopedQueries.count
            scoped.compositionChanged(true)
            scoped.selectCategory(.all)
            try expect(scoped.category == .actions && scopedQueries.count==count && !scoped.key(0x30,target:field,control:true,shift:false),
                "IME composition blocks category shortcuts and leaves input to Windows")
            scoped.compositionChanged(false)
            for index in 0..<4 {
                try expect(scoped.key(WPARAM(0x30+index),target:field,control:true,shift:false) && scoped.category==SearchCategory.allCases[index],
                    "native Ctrl+0/1/2/3 selects a category")
            }
            SendMessageW(host,UINT(WM_COMMAND),23,LPARAM(Int(bitPattern:scoped.controls[23]!)))
            try expect(scoped.category == .actions,"category button command selects the same scope")
            let file=NativeSearchResult(id:"file",title:"Document",subtitle:"Example",kind:"File")
            _=try scoped.apply(NativeSearchSnapshot(generation:scoped.generation,results:[file],status:"Ready",quickAnswer:nil))
            try expect(scoped.resultActions().map(\.0)==[.open,.preview,.copy,.reveal] &&
                scoped.requestsResultMenu(WPARAM(VK_TAB),target:field,control:false,shift:false) &&
                scoped.requestsResultMenu(WPARAM(VK_F10),target:rows,control:false,shift:true) &&
                !scoped.requestsResultMenu(WPARAM(VK_TAB),target:field,control:false,shift:true),
                "ready file actions include native Tab/Shift+F10 and preserve backward focus traversal")
            let ready=scoped.generation
            scoped.perform(.copy,generation:ready,resultID:"file")
            try expect(actions==["copy:file"],"result menu action delegates its callback once")
            scoped.queryChanged()
            scoped.perform(.reveal,generation:ready,resultID:"file")
            try expect(actions==["copy:file"] && scoped.resultActions().isEmpty,"query invalidation rejects an action chosen from a stale menu")
            let answer=NativeSearchResult(id:"answer",title:"14",subtitle:"2+3*4",kind:"Calculator")
            _=try scoped.apply(NativeSearchSnapshot(generation:scoped.generation,results:[answer],status:"Ready",quickAnswer:"14"))
            try expect(scoped.resultActions().map(\.0)==[.preview,.copy],"quick answers show Copy result without file commands")
            scoped.perform(.reveal,generation:scoped.generation,resultID:"answer")
            try expect(actions==["copy:file"],"unsupported result-menu command cannot invoke a callback")
        }
        do {
            var lastQuery=""
            let typing=try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{lastQuery=$0},onActivate:{_ in},onPreview:{_ in},onCopy:{_ in})
            let field=typing.controls[1]!
            try expect(SendMessageW(field,UINT(EM_GETTEXTMODE),0,0) & LRESULT(TM_PLAINTEXT.rawValue) != 0 &&
                GetWindowLongPtrW(field,Int32(GWL_STYLE)) & LONG_PTR(ES_MULTILINE)==0,"native single-line plain-text input")
            let layout=GetKeyboardLayout(0), query="Swift café Привет "+String(repeating:"abc",count:32)
            for character in query { _=withWideString(String(character)) { SendMessageW(field,UINT(EM_REPLACESEL),1,LPARAM(Int(bitPattern:$0))) } }
            func selection() -> (DWORD,DWORD) {
                var start:DWORD=0,end:DWORD=0
                withUnsafeMutablePointer(to:&start) { first in withUnsafeMutablePointer(to:&end) { last in
                    _=SendMessageW(field,UINT(EM_GETSEL),WPARAM(UInt(bitPattern:first)),LPARAM(Int(bitPattern:last)))
                } }
                return (start,end)
            }
            try expect(typing.text(1)==query && lastQuery==query && Int(selection().1)==query.utf16.count && GetKeyboardLayout(0)==layout,
                "rapid Unicode insertion retains text, caret and input layout")
            SendMessageW(field,UINT(EM_STOPGROUPTYPING),0,0)
            SendMessageW(field,UINT(EM_SETSEL),0,5)
            _=withWideString("Native") { SendMessageW(field,UINT(EM_REPLACESEL),1,LPARAM(Int(bitPattern:$0))) }
            try expect(typing.text(1).hasPrefix("Native café"),"native selection replacement")
            SendMessageW(field,UINT(EM_UNDO),0,0)
            try expect(typing.text(1)==query,"native Undo restores Unicode input")
            SendMessageW(field,UINT(EM_SETSEL),2,6)
            try typing.theme(forcedHighContrast:true); try typing.theme(forcedHighContrast:false)
            var format=CHARFORMATW(); format.cbSize=UINT(MemoryLayout<CHARFORMATW>.size)
            _=withUnsafeMutablePointer(to:&format) { SendMessageW(field,UINT(EM_GETCHARFORMAT),WPARAM(SCF_SELECTION),LPARAM(Int(bitPattern:$0))) }
            try expect(typing.text(1)==query && selection()==(2,6) && format.crTextColor==typing.textColor,"theme retains populated input/selection and refreshes native text color")
            typing.setText(1,""); typing.compositionChanged(true)
            try expect(GetWindowLongPtrW(typing.controls[17],Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE)==0,"hint never covers IME composition")
            typing.compositionChanged(false)
            try expect(GetWindowLongPtrW(typing.controls[17],Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE) != 0,"empty hint returns after composition cancellation")
            typing.setText(1,"")
            for _ in 0..<1030 { SendMessageW(field,UINT(WM_CHAR),WPARAM(120),1) }
            try expect(typing.text(1).utf16.count==1024 && lastQuery.utf16.count==1024,"native insertion enforces query length limit")
        }
        for (id,name) in [(3,"Preview"),(4,"Close"),(5,"Copy"),(6,"Open")] { try expect(try accessibleName(panel.controls[id]!) == name,"native button accessible name") }
        panel.setText(1,"120 USD")
        try expect(queries.last == "120 USD","native edit sends actual query")
        let generation=panel.generation
        let results=[NativeSearchResult(id:"amount",title:"120 USD",subtitle:"Amount recognized; no exchange rate applied",kind:"Amount"),
            NativeSearchResult(id:"notes",title:"Notes",subtitle:"Application",kind:"App"),
            NativeSearchResult(id:"file",title:"Project notes & examples — пример.txt",subtitle:"Example document",kind:"File")]
        try expect(try !panel.apply(NativeSearchSnapshot(generation:generation-1,results:results,status:"Stale",quickAnswer:nil)),"stale generation rejected")
        try expect(try panel.apply(NativeSearchSnapshot(generation:generation,results:results,status:"3 example results",quickAnswer:"120 USD")),"current generation accepted")
        for count in [1,6] {
            let rows=(0..<count).map { NativeSearchResult(id:"row:\($0)",title:"Example \($0)",subtitle:"Text",kind:"File") }
            _=try panel.apply(NativeSearchSnapshot(generation:generation,results:rows,status:"Fixture",quickAnswer:nil))
            SetWindowPos(window,nil,0,0,Int32(720*panel.scale),Int32((Double(174+count*58)*panel.scale).rounded(.up)),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            var row=RECT(), bounds=RECT(); GetClientRect(list,&bounds)
            _=withUnsafeMutablePointer(to:&row) { SendMessageW(list,UINT(LB_GETITEMRECT),WPARAM(count-1),LPARAM(Int(bitPattern:$0))) }
            try expect(row.top >= 0 && row.bottom <= bounds.bottom,
                "last result row \(count) fits without clipping (\(row.top)…\(row.bottom), list height \(bounds.bottom), scale \(panel.scale))")
            try checkBounds()
        }
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
        do {
            var info=BITMAPINFO(), pixels:UnsafeMutableRawPointer?
            info.bmiHeader.biSize=DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            info.bmiHeader.biWidth=64; info.bmiHeader.biHeight = -64
            info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32
            info.bmiHeader.biCompression=DWORD(BI_RGB)
            guard let bitmap=CreateDIBSection(dc,&info,UINT(DIB_RGB_COLORS),&pixels,nil,0), pixels != nil else { throw WindowsError.api("Create owned paint bitmap",GetLastError()) }
            defer { DeleteObject(bitmap) }
            guard let sentinel=CreateSolidBrush(0x0010_2030) else { throw WindowsError.api("Create paint fixture color",GetLastError()) }
            defer { DeleteObject(sentinel) }
            let oldBitmap=SelectObject(dc,bitmap)
            defer { SelectObject(dc,oldBitmap) }
            var whole=RECT(left:0,top:0,right:64,bottom:64), area=RECT(left:7,top:9,right:45,bottom:48)
            FillRect(dc,&whole,sentinel)
            var usedBuffer=false, targetStayedIntact=false
            panel.drawBuffered(dc,in:area) { drawing in
                usedBuffer=drawing != dc
                let filled=FillRect(drawing,&area,panel.brushes[1])
                targetStayedIntact=GetPixel(dc,12,14)==0x0010_2030
                return filled != 0
            }
            try expect((!usedBuffer || targetStayedIntact) && GetPixel(dc,12,14)==panel.surfaceColor &&
                GetPixel(dc,2,2)==0x0010_2030,"buffered paint commits complete content at a nonzero origin without changing exterior pixels")
            FillRect(dc,&whole,sentinel)
            panel.drawBuffered(dc,in:area) { drawing in
                if drawing != dc { _=FillRect(drawing,&area,panel.brushes[1]) }
                return false
            }
            try expect(GetPixel(dc,12,14)==0x0010_2030,"incomplete buffer is discarded")
            let initialized=panel.bufferedPainting
            panel.bufferedPainting=false
            defer { panel.bufferedPainting=initialized }
            panel.drawBuffered(dc,in:area) { drawing in FillRect(drawing,&area,panel.brushes[1]) != 0 }
            try expect(GetPixel(dc,12,14)==panel.surfaceColor && GetPixel(dc,2,2)==0x0010_2030 &&
                GetTextColor(dc)==0x0001_0203 && GetBkMode(dc)==Int32(OPAQUE) && GetCurrentObject(dc,UINT(OBJ_FONT))==originalFont,
                "direct-paint fallback retains pixels and DC state")
            Console.writeLine("PASS: owned buffered drawing atomicity, nonzero origin, incomplete-buffer discard and direct fallback (buffer available: \(usedBuffer))")
        }
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
        for id in [1,2,14,3,4,5,6,20,21,22,23] { try expect(GetWindowLongPtrW(panel.controls[id]!,Int32(GWL_STYLE)) & LONG_PTR(WS_TABSTOP) != 0,"keyboard tab stops") }
        try expect(GetNextDlgTabItem(window,edit,false)==list && GetNextDlgTabItem(window,list,false)==panel.controls[14],"native tab order")
        panel.previewExpanded=false; panel.arrange()
        try expect(GetNextDlgTabItem(window,list,false)==panel.controls[6],"collapsed preview stays outside tab order")
        for expanded in [false,true] {
            panel.previewExpanded=expanded
            var limits=MINMAXINFO()
            _=withUnsafeMutablePointer(to:&limits) { SendMessageW(window,UINT(WM_GETMINMAXINFO),0,LPARAM(Int(bitPattern:$0))) }
            try expect(limits.ptMinTrackSize.y==Int32((Double(expanded ? 374 : 232)*panel.scale).rounded(.up)),"state-dependent minimum height")
            SetWindowPos(window,nil,0,0,Int32(560*panel.scale),limits.ptMinTrackSize.y,UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            try checkBounds()
        }
        try checkBounds()
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
            "reference rates":"Translated suffix","Frankfurter daily reference rates":"Translated bank","2026-10-13":"Wrong date","8 / 64":"Wrong count"
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
        try expect(panel.text(15)=="Translated status · Translated suffix · 8 / 64" && panel.ownedParts("Frankfurter daily reference rates · 2026-10-13 · 120 USD")=="Translated bank · 2026-10-13 · 120 USD","status and currency labels preserve counts dates and amounts")
        _=try panel.apply(NativeSearchSnapshot(generation:panel.generation,results:[calculation],status:"Calculated",quickAnswer:"4"))
        SendMessageW(edit,UINT(EM_SETSEL),0,0)
        try expect(panel.selected?.kind=="Calculator" && panel.copyAnswerFromEdit() && copies.last=="answer","translated calculation keeps raw callback kind and Copy behavior")
        let clock=NativeSearchResult(id:"answer",title:"12:00",subtitle:"UTC · 2026-10-13 · Windows time-zone rules",kind:"World clock")
        _=try panel.apply(NativeSearchSnapshot(generation:panel.generation,results:[clock],status:"Calculated",quickAnswer:"12:00"))
        try expect(panel.copyAnswerFromEdit() && panel.selected?.kind=="World clock","new quick-answer kinds retain the same query Copy behavior")
        try panel.localization.select(.english,persist:false)
        do {
            var calls: [String] = []
            let smooth = try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{ _ in },
                onActivate:{ calls.append("open:"+$0) },onPreview:{ calls.append("preview:"+$0) },
                onCopy:{ calls.append("copy:"+$0) },onReveal:{ calls.append("reveal:"+$0) })
            let smoothWindow=smooth.window!, smoothList=smooth.controls[2]!, smoothEdit=smooth.controls[1]!
            let rows=[calculation,results[2]]
            func snapshot() -> NativeSearchSnapshot {
                NativeSearchSnapshot(generation:smooth.generation,results:rows,status:"Stable results",quickAnswer:"4")
            }
            _=try smooth.apply(snapshot())
            SetWindowPos(smoothWindow,nil,0,0,Int32(720*smooth.scale),Int32((290*smooth.scale).rounded(.up)),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            var counts=[Int](repeating:0,count:5)
            try counts.withUnsafeMutableBufferPointer { buffer in
                let reference=DWORD_PTR(UInt(bitPattern:buffer.baseAddress!))
                let handles=[smoothWindow]+Array(smooth.controls.values)
                var observed: [HWND] = []
                defer { for handle in observed { RemoveWindowSubclass(handle,searchLayoutCheckProcedure,2) } }
                for handle in handles {
                    guard SetWindowSubclass(handle,searchLayoutCheckProcedure,2,reference) else {
                        throw WindowsError.api("Observe Search fixture layout",GetLastError())
                    }
                    observed.append(handle)
                }
                for index in [0,1] {
                    SendMessageW(smoothList,UINT(LB_SETCURSEL),WPARAM(index),0)
                    var before=RECT(); GetWindowRect(smoothWindow,&before)
                    let positions=buffer[0], resets=buffer[1]
                    smooth.setText(1,"query \(index)")
                    smooth.activate(); smooth.copy(); smooth.preview(); smooth.reveal()
                    _=smooth.key(WPARAM(VK_RETURN),target:smoothEdit)
                    _=smooth.key(WPARAM(VK_SPACE),target:smoothList)
                    SendMessageW(smoothWindow,UINT(WM_COMMAND),WPARAM(2 | (Int(LBN_DBLCLK)<<16)),LPARAM(Int(bitPattern:smoothList)))
                    try expect(!smooth.copyAnswerFromEdit() && calls.isEmpty && smooth.selected==nil,"all retained-result actions stay blocked while querying")
                    try expect(!IsWindowEnabled(smooth.controls[3]) && !IsWindowEnabled(smooth.controls[5]) && !IsWindowEnabled(smooth.controls[6]),"pending result buttons disabled")
                    var after=RECT(); GetWindowRect(smoothWindow,&after)
                    try expect((before.left,before.top,before.right,before.bottom)==(after.left,after.top,after.right,after.bottom) &&
                        buffer[0]==positions && buffer[1]==resets && SendMessageW(smoothList,UINT(LB_GETCOUNT),0,0)==2,"typing retains frame and rows without geometry or list resets")
                    _=try smooth.apply(snapshot())
                    try expect(buffer[0]==positions && buffer[1]==resets && smooth.selected?.id=="answer","same-row reply restores actions without relayout")
                    let unchanged=(buffer[0],buffer[1],buffer[2])
                    _=try smooth.apply(snapshot()); smooth.arrange()
                    try expect((buffer[0],buffer[1],buffer[2])==unchanged,"identical snapshot does not move windows, reset rows or replace text")
                }
                smooth.copy(); try expect(calls==["copy:answer"],"fresh result is actionable after pending reply")
                smooth.previewExpanded=true; smooth.arrange()
                let positions=buffer[0]
                smooth.queryChanged()
                try expect(smooth.previewExpanded && buffer[0]==positions,"pending query preserves expanded preview geometry")
                let many=(0..<20).map { NativeSearchResult(id:"item:\($0)",title:"Item \($0)",subtitle:"Text",kind:"File") }
                _=try smooth.apply(NativeSearchSnapshot(generation:smooth.generation,results:many,status:"Progressive",quickAnswer:nil))
                var viewport=RECT(); GetClientRect(smoothList,&viewport)
                let rowHeight=SendMessageW(smoothList,UINT(LB_GETITEMHEIGHT),0,0)
                try expect(rowHeight > 0 && Int(viewport.bottom) >= Int(rowHeight)*2,
                    "scroll preservation fixture has two completely visible native rows")
                SendMessageW(smoothList,UINT(LB_SETCURSEL),10,0)
                SendMessageW(smoothList,UINT(LB_SETTOPINDEX),9,0)
                var changed=many
                changed[0]=NativeSearchResult(id:"item:0",title:"Updated item",subtitle:"Text",kind:"File")
                _=try smooth.apply(NativeSearchSnapshot(generation:smooth.generation,results:changed,status:"Progressive update",quickAnswer:nil))
                try expect(smooth.selected?.id=="item:10" && SendMessageW(smoothList,UINT(LB_GETTOPINDEX),0,0)==9,
                    "same-generation progressive rows preserve selected item and valid scroll position")
                try expect(buffer[3]==10 && buffer[4]==9,"rows resume drawing only after selection and viewport are restored")
                _=try smooth.apply(NativeSearchSnapshot(generation:smooth.generation,results:[],status:"No results",quickAnswer:nil))
                try expect(GetWindowLongPtrW(smoothList,Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE)==0,"redraw resume does not expose an empty list")
            }
        }
        do {
            weak var quick: NativeSearchWindow?
            let synchronous=try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{ _ in
                guard let quick else { return }
                _=try? quick.apply(NativeSearchSnapshot(generation:quick.generation,results:[calculation],status:"Ready",quickAnswer:"4"))
            },onActivate:{_ in},onPreview:{_ in},onCopy:{_ in})
            quick=synchronous
            synchronous.setText(1,"2+2")
            try expect(!synchronous.queryPending && !synchronous.pendingStatusQueued && synchronous.text(15)=="Ready","synchronous reply never replaces ready status with pending text")
            SendMessageW(synchronous.window,searchPendingMessage,0,0)
            try expect(synchronous.text(15)=="Ready","obsolete pending notice cannot overwrite a completed reply")
        }
        do {
            let steady=try NativeSearchWindow(localization:Localization(pack:.english),onQuery:{_ in},onActivate:{_ in},onPreview:{_ in},onCopy:{_ in})
            let field=steady.controls[1]!, host=steady.window!
            SetWindowPos(host,nil,0,0,Int32(720*steady.scale),Int32(488*steady.scale),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
            steady.setText(1,"stable query")
            _=try steady.apply(NativeSearchSnapshot(generation:steady.generation,results:[calculation],status:"Ready",quickAnswer:"4"))
            SendMessageW(field,UINT(EM_SETSEL),2,5)
            ValidateRect(field,nil)
            var observed=[Int](repeating:0,count:5)
            try observed.withUnsafeMutableBufferPointer { buffer in
                let reference=DWORD_PTR(UInt(bitPattern:buffer.baseAddress!))
                guard SetWindowSubclass(field,searchLayoutCheckProcedure,3,reference) else { throw WindowsError.api("Observe query invalidation",GetLastError()) }
                defer { RemoveWindowSubclass(field,searchLayoutCheckProcedure,3) }
                for rows: [NativeSearchResult] in [[],[calculation]] {
                    _=try steady.apply(NativeSearchSnapshot(generation:steady.generation,results:rows,status:"Changed results",quickAnswer:nil))
                    try expect(buffer[0]==0 && !GetUpdateRect(field,nil,false),"result visibility changes neither move nor invalidate unchanged query input")
                }
                for expanded in [true,false] {
                    steady.previewExpanded=expanded; steady.arrange()
                    try expect(buffer[0]==0 && !GetUpdateRect(field,nil,false),"preview visibility changes do not redraw unchanged query input")
                }
                let range=SendMessageW(field,UINT(EM_GETSEL),0,0)
                try expect(range & 0xffff == 2 && (range >> 16) & 0xffff == 5,"visibility changes retain query selection")
                SetWindowPos(host,nil,0,0,Int32(800*steady.scale),Int32(488*steady.scale),UINT(SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))
                try expect(buffer[0] > 0,"real width changes still resize query input")
                ValidateRect(field,nil); try steady.theme(forcedHighContrast:true)
                var colors=CHARFORMATW(); colors.cbSize=UINT(MemoryLayout<CHARFORMATW>.size)
                _=withUnsafeMutablePointer(to:&colors) { SendMessageW(field,UINT(EM_GETCHARFORMAT),WPARAM(SCF_SELECTION),LPARAM(Int(bitPattern:$0))) }
                try expect(colors.crTextColor==steady.textColor && steady.text(1)=="stable query","real theme changes still refresh native input colors and retain text")
            }
        }
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
        Console.writeLine("PASS: native search compact/expanded bounds and complete rows, MSAA names/localization, query/selection/open/copy/preview/dismissal, tab/focus and IME guards, bounded snapshot/preview delivery, stale selections/generations, system high contrast, owned icons and destruction/resources; fixture stayed hidden")
    }
    deinit {
        producer?.close(); backdrop?.close(); backdrop=nil
        if let services=queryAccessibility {
            for id in [1,20,21,22,23] {
                if let control=controls[id] { var property=Self.queryNameProperty; _=services.pointee.lpVtbl.pointee.ClearHwndProps(services,control,DWORD(bitPattern:searchClientObject),0,&property,1) }
            }
            _=services.pointee.lpVtbl.pointee.Release(services)
        }
        if let window { DestroyWindow(window) }
        if let textLibrary { FreeLibrary(textLibrary) }
        fonts.forEach { DeleteObject($0) }; brushes.forEach { DeleteObject($0) }
        if bufferedPainting { _=BufferedPaintUnInit() }; if ownsCOM { CoUninitialize() }
    }
}
