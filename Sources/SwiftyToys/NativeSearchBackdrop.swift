// SPDX-License-Identifier: MIT
import WinSDK
import SearchXamlABI

private func searchMaterialProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM,
    _ identifier: UINT_PTR, _ reference: DWORD_PTR) -> LRESULT {
    if message == UINT(WM_NCHITTEST) { return LRESULT(HTTRANSPARENT) }
    if message == UINT(WM_NCDESTROY) { _ = RemoveWindowSubclass(window, searchMaterialProcedure, identifier) }
    return DefSubclassProc(window, message, value, data)
}

// SDK interfaces own their references; construction failures release the same set.
private final class SearchXamlReferences {
    private var values: [UnsafeMutablePointer<IUnknown>] = []
    func own<T>(_ pointer: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<T> {
        values.append(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: IUnknown.self))
        return pointer
    }
    func release() {
        for pointer in values.reversed() { _ = pointer.pointee.lpVtbl.pointee.Release(pointer) }
        values.removeAll()
    }
    deinit { release() }
    func query<T,U>(_ pointer: UnsafeMutablePointer<U>, _ identifier: String, as: T.Type) throws -> UnsafeMutablePointer<T> {
        let unknown = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: IUnknown.self)
        var iid = try Self.guid(identifier)
        var result: UnsafeMutableRawPointer?
        try Self.check(unknown.pointee.lpVtbl.pointee.QueryInterface(unknown, &iid, &result), "Query Search material interface")
        guard let result else { throw WindowsError.unsupported("Search material interface is unavailable.") }
        return own(result.assumingMemoryBound(to: T.self))
    }
    func factory<T>(_ name: String, _ identifier: String, as: T.Type) throws -> UnsafeMutablePointer<T> {
        var iid = try Self.guid(identifier)
        var result: UnsafeMutableRawPointer?
        try Self.string(name) { try Self.check(RoGetActivationFactory($0, &iid, &result), "Load Windows Search material") }
        guard let result else { throw WindowsError.unsupported("Windows Search material factory is unavailable.") }
        return own(result.assumingMemoryBound(to: T.self))
    }
    func activate(_ name: String) throws -> UnsafeMutablePointer<IInspectable> {
        var result: UnsafeMutablePointer<IInspectable>?
        try Self.string(name) { try Self.check(RoActivateInstance($0, &result), "Create Windows Search material") }
        guard let result else { throw WindowsError.unsupported("Windows Search material is unavailable.") }
        return own(result)
    }
    static func check(_ result: HRESULT, _ operation: String) throws {
        if result < 0 { throw WindowsError.status(operation, result) }
    }
    private static func guid(_ value: String) throws -> GUID {
        var result = GUID()
        try withWideString("{" + value + "}") { try check(CLSIDFromString($0, &result), "Read Search material interface ID") }
        return result
    }
    private static func string<T>(_ value: String, _ body: (HSTRING?) throws -> T) throws -> T {
        var result: HSTRING?
        try withWideString(value) { try check(WindowsCreateString($0, UInt32(value.utf16.count), &result), "Read Search material class") }
        defer { _ = WindowsDeleteString(result) }
        return try body(result)
    }
    func close<T>(_ pointer: UnsafeMutablePointer<T>) {
        let temporary = SearchXamlReferences()
        if let closable = try? temporary.query(pointer, "30d5a829-7fa4-4026-83bb-d75bae4ea99e", as: __x_ABI_CWindows_CFoundation_CIClosable.self) {
            _ = closable.pointee.lpVtbl.pointee.Close(closable)
        }
    }
}

/// Background-only OS XAML island. All methods and destruction belong to its HWND's UI thread.
final class NativeSearchBackdrop {
    nonisolated(unsafe) private static var manager: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CHosting_CIWindowsXamlManager>?
    nonisolated(unsafe) private static var managerReferences: SearchXamlReferences?
    nonisolated(unsafe) private static var owner: DWORD = 0
    nonisolated(unsafe) private static var stopped = false
    nonisolated(unsafe) private static var initializing = false
    nonisolated(unsafe) private static var sources = 0

    let window: HWND
    private let thread: DWORD
    private let references: SearchXamlReferences
    private let source: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CHosting_CIDesktopWindowXamlSource>
    private let acrylic: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CMedia_CIAcrylicBrush>
    private let brushBase: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CMedia_CIXamlCompositionBrushBase>
    private let grid: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CControls_CIGrid2>
    private var frameSize: (Int32,Int32,UINT,Double)?
    private var closed = false

    private static func initialize() throws {
        let current = GetCurrentThreadId()
        guard !stopped, !initializing, owner == 0 || owner == current else {
            throw WindowsError.unsupported("Windows Search material is unavailable on this UI thread.")
        }
        if manager != nil { return }
        owner = current
        initializing = true
        defer { initializing = false }
        let status = RoInitialize(RO_INIT_SINGLETHREADED)
        try SearchXamlReferences.check(status, "Initialize Windows Search material")
        var successful = false
        defer {
            if !successful {
                // A partially initialized XAML framework must not be recreated on this thread.
                stopped = true
                RoUninitialize()
            }
        }
        let refs = SearchXamlReferences()
        let factory = try refs.factory("Windows.UI.Xaml.Hosting.WindowsXamlManager", "28258a12-7d82-505b-b210-712b04a58882", as: __x_ABI_CWindows_CUI_CXaml_CHosting_CIWindowsXamlManagerStatics.self)
        var result: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CHosting_CIWindowsXamlManager>?
        try SearchXamlReferences.check(factory.pointee.lpVtbl.pointee.InitializeForCurrentThread(factory, &result), "Initialize Windows XAML material")
        guard let result else { throw WindowsError.unsupported("Windows XAML material did not initialize.") }
        manager = refs.own(result)
        managerReferences = refs
        successful = true
    }

    init(parent: HWND) throws {
        guard GetWindowThreadProcessId(parent, nil) == GetCurrentThreadId() else {
            throw WindowsError.unsupported("Search material must be created on its window thread.")
        }
        try Self.initialize()
        let refs = SearchXamlReferences()
        let instance = try refs.activate("Windows.UI.Xaml.Hosting.DesktopWindowXamlSource")
        var successful = false
        defer { if !successful { refs.close(instance) } }
        let interop = try refs.query(instance, "3cbcf1bf-2f76-4e9c-96ab-e84b37972554", as: IDesktopWindowXamlSourceNative.self)
        try SearchXamlReferences.check(interop.pointee.lpVtbl.pointee.AttachToWindow(interop, parent), "Attach Search material")
        var child: HWND?
        try SearchXamlReferences.check(interop.pointee.lpVtbl.pointee.get_WindowHandle(interop, &child), "Get Search material window")
        guard let child else { throw WindowsError.unsupported("Search material child window is unavailable.") }
        // A lower sibling can paint over higher native controls unless its visible region clips them.
        let style = GetWindowLongPtrW(child, Int32(GWL_STYLE))
        SetLastError(0)
        let previous = SetWindowLongPtrW(child, Int32(GWL_STYLE), style | LONG_PTR(WS_CLIPSIBLINGS))
        if previous == 0, GetLastError() != 0 {
            throw WindowsError.api("Clip Search material around native controls", GetLastError())
        }
        guard SetWindowPos(child, nil, 0, 0, 0, 0,
            UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) else {
            throw WindowsError.api("Refresh Search material clipping", GetLastError())
        }
        let gridFactory = try refs.factory("Windows.UI.Xaml.Controls.Grid", "ae814041-c531-43b4-bf99-12f506f7b01c", as: __x_ABI_CWindows_CUI_CXaml_CControls_CIGridFactory.self)
        var root: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CControls_CIGrid>?
        var inner: UnsafeMutablePointer<IInspectable>?
        let gridStatus = gridFactory.pointee.lpVtbl.pointee.CreateInstance(gridFactory, nil, &inner, &root)
        if let inner { _ = refs.own(inner) }
        if let root { _ = refs.own(root) }
        try SearchXamlReferences.check(gridStatus, "Create Search material surface")
        guard let root else { throw WindowsError.unsupported("Search material surface is unavailable.") }
        let acrylicFactory = try refs.factory("Windows.UI.Xaml.Media.AcrylicBrush", "81a32568-f6cc-4013-8363-928ae23b7a61", as: __x_ABI_CWindows_CUI_CXaml_CMedia_CIAcrylicBrushFactory.self)
        var brush: UnsafeMutablePointer<__x_ABI_CWindows_CUI_CXaml_CMedia_CIAcrylicBrush>?
        inner = nil
        let brushStatus = acrylicFactory.pointee.lpVtbl.pointee.CreateInstance(acrylicFactory, nil, &inner, &brush)
        if let inner { _ = refs.own(inner) }
        if let brush { _ = refs.own(brush) }
        try SearchXamlReferences.check(brushStatus, "Create Search acrylic")
        guard let brush else { throw WindowsError.unsupported("Search acrylic is unavailable.") }
        try SearchXamlReferences.check(brush.pointee.lpVtbl.pointee.put_BackgroundSource(brush, __x_ABI_CWindows_CUI_CXaml_CMedia_CAcrylicBackgroundSource(rawValue: 0)), "Set Search host backdrop")
        try SearchXamlReferences.check(brush.pointee.lpVtbl.pointee.put_TintColor(brush, __x_ABI_CWindows_CUI_CColor(A: 255, R: 249, G: 250, B: 252)), "Set Search acrylic tint")
        try SearchXamlReferences.check(brush.pointee.lpVtbl.pointee.put_TintOpacity(brush, 0.78), "Set Search acrylic opacity")
        let base = try refs.query(brush, "03e432d9-b35c-4a79-811c-c5652004da0e", as: __x_ABI_CWindows_CUI_CXaml_CMedia_CIXamlCompositionBrushBase.self)
        try SearchXamlReferences.check(base.pointee.lpVtbl.pointee.put_FallbackColor(base, __x_ABI_CWindows_CUI_CColor(A: 255, R: 249, G: 250, B: 252)), "Set Search material fallback")
        let background = try refs.query(brush, "8806a321-1e06-422c-a1cc-01696559e021", as: __x_ABI_CWindows_CUI_CXaml_CMedia_CIBrush.self)
        let panel = try refs.query(root, "a50a4bbd-8361-469c-90da-e9a40c7474df", as: __x_ABI_CWindows_CUI_CXaml_CControls_CIPanel.self)
        try SearchXamlReferences.check(panel.pointee.lpVtbl.pointee.put_Background(panel, background), "Set Search material background")
        let element = try refs.query(root, "676d0be9-b65c-41c6-ba40-58cf87f201c1", as: __x_ABI_CWindows_CUI_CXaml_CIUIElement.self)
        try SearchXamlReferences.check(element.pointee.lpVtbl.pointee.put_IsHitTestVisible(element, 0), "Preserve native Search input")
        let source = try refs.query(instance, "d585bfe1-00ff-51be-ba1d-a1329956ea0a", as: __x_ABI_CWindows_CUI_CXaml_CHosting_CIDesktopWindowXamlSource.self)
        let rounded = try refs.query(root, "f76efa41-380e-45db-be87-9e1326ba4b57", as: __x_ABI_CWindows_CUI_CXaml_CControls_CIGrid2.self)
        try SearchXamlReferences.check(source.pointee.lpVtbl.pointee.put_Content(source, element), "Set Search material content")
        // XAML hit testing does not make its native child HWND transparent to mouse input.
        guard SetWindowSubclass(child, searchMaterialProcedure, 1, 0) else {
            throw WindowsError.api("Preserve native Search hit testing", GetLastError())
        }
        self.window = child
        self.thread = GetCurrentThreadId()
        self.references = refs
        self.source = source
        self.acrylic = brush
        self.brushBase = base
        self.grid = rounded
        Self.sources += 1
        successful = true
    }

    @discardableResult func resize(width: Int32, height: Int32, cornerRadius: Double, highContrast: Bool) -> Bool {
        guard !closed, !Self.stopped, thread == GetCurrentThreadId(), width > 0, height > 0,
            cornerRadius.isFinite, cornerRadius >= 0 else { return false }
        let color = GetSysColor(Int32(COLOR_WINDOW))
        let fallback = highContrast
            ? __x_ABI_CWindows_CUI_CColor(A: 255, R: UInt8(color & 255), G: UInt8((color >> 8) & 255), B: UInt8((color >> 16) & 255))
            : __x_ABI_CWindows_CUI_CColor(A: 255, R: 248, G: 250, B: 252)
        guard acrylic.pointee.lpVtbl.pointee.put_AlwaysUseFallback(acrylic, highContrast ? 1 : 0) >= 0,
            brushBase.pointee.lpVtbl.pointee.put_FallbackColor(brushBase, fallback) >= 0 else {
            ShowWindow(window,Int32(SW_HIDE)); return false
        }
        // Win32 sizes are physical pixels; XAML corner radii are device-independent pixels.
        let dpi = max(96,GetDpiForWindow(window))
        let size = (width,height,dpi,cornerRadius)
        let scale = 96.0 / Double(dpi)
        let radius = min(cornerRadius, Double(min(width, height)) / 2) * scale
        if frameSize.map({ $0 != size }) ?? true {
            frameSize = nil // A partial native update cannot leave an old geometry cache valid.
            // One readable native card, with Acrylic confined to its surrounding frame.
            let inset = min(Int32((8 / scale).rounded()),min(width,height)/4)
            let diameter = Int32(2*radius/scale)
            guard let frame = CreateRoundRectRgn(0,0,width,height,diameter,diameter) else {
                ShowWindow(window,Int32(SW_HIDE)); return false
            }
            var transferred = false
            defer { if !transferred { DeleteObject(frame) } }
            guard let content = CreateRoundRectRgn(inset,inset,width-inset,height-inset,Int32(24/scale),Int32(24/scale)) else {
                ShowWindow(window,Int32(SW_HIDE)); return false
            }
            defer { DeleteObject(content) }
            guard CombineRgn(frame,frame,content,Int32(RGN_DIFF)) != 0,
                SetWindowRgn(window,frame,true) != 0 else {
                ShowWindow(window,Int32(SW_HIDE)); return false
            }
            transferred = true // Windows owns the frame region after SetWindowRgn succeeds.
            guard grid.pointee.lpVtbl.pointee.put_CornerRadius(grid, __x_ABI_CWindows_CUI_CXaml_CCornerRadius(TopLeft: radius, TopRight: radius, BottomRight: radius, BottomLeft: radius)) >= 0 else {
                ShowWindow(window,Int32(SW_HIDE)); return false
            }
        }
        if (frameSize.map({ $0 != size }) ?? true) || GetWindowLongPtrW(window,Int32(GWL_STYLE)) & LONG_PTR(WS_VISIBLE) == 0 {
            guard SetWindowPos(window, HWND(bitPattern: 1), 0, 0, width, height, UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW)) else {
                ShowWindow(window,Int32(SW_HIDE)); return false
            }
        }
        frameSize = size
        return true
    }

    func close() {
        guard !closed else { return }
        precondition(thread == GetCurrentThreadId(), "Close Search material on its UI thread")
        closed = true
        _ = source.pointee.lpVtbl.pointee.put_Content(source, nil)
        references.close(source)
        references.release()
        Self.sources -= 1
    }
    deinit { close() }

    static func selfCheck() throws {
        func expect(_ condition: Bool, _ name: String) throws {
            guard condition else { throw WindowsError.unsupported("Search material check failed: " + name) }
        }
        var priorQuit: Int32?
        var message = MSG()
        while PeekMessageW(&message, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)) {
            if priorQuit == nil { priorQuit = Int32(truncatingIfNeeded: message.wParam) }
        }
        defer {
            shutdown()
            while PeekMessageW(&message, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)) {}
            if let priorQuit { PostQuitMessage(priorQuit) }
        }
        func settle(milliseconds: UInt64 = 200) {
            let deadline = GetTickCount64() + milliseconds
            repeat {
                var count = 0
                while count < 256, GetTickCount64() < deadline,
                    PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                    count += 1
                    if message.message == UINT(WM_QUIT) {
                        if priorQuit == nil { priorQuit = Int32(truncatingIfNeeded: message.wParam) }
                    } else { _ = TranslateMessage(&message); _ = DispatchMessageW(&message) }
                }
                _ = MsgWaitForMultipleObjectsEx(0, nil, 10, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
            } while GetTickCount64() < deadline
        }
        func children(of window: HWND) -> Set<Int> {
            var result = Set<Int>()
            withUnsafeMutablePointer(to: &result) { output in
                _ = EnumChildWindows(window, { child, data in
                    if let child, let output = UnsafeMutablePointer<Set<Int>>(bitPattern: Int(data)) {
                        output.pointee.insert(Int(bitPattern: child))
                    }
                    return true
                }, LPARAM(Int(bitPattern: output)))
            }
            return result
        }
        func resources() -> (gdi: DWORD, user: DWORD) {
            (GetGuiResources(GetCurrentProcess(), DWORD(GR_GDIOBJECTS)),
                GetGuiResources(GetCurrentProcess(), DWORD(GR_USEROBJECTS)))
        }
        func checkFrame(_ window: HWND) throws {
            guard let frame = CreateRectRgn(0,0,0,0) else { throw WindowsError.api("Read Search frame fixture",GetLastError()) }
            defer { DeleteObject(frame) }
            try expect(GetWindowRgn(window,frame) != 0 && PtInRegion(frame,320,4) &&
                !PtInRegion(frame,320,88) && !PtInRegion(frame,320,180),"continuous content excluded from Acrylic frame")
        }
        let parent = withWideString("STATIC") {
            CreateWindowExW(DWORD(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE), $0, nil, DWORD(WS_POPUP) | DWORD(WS_CLIPCHILDREN),
                0, 0, 640, 360, nil, nil, GetModuleHandleW(nil), nil)
        }
        guard let parent else { throw WindowsError.api("Create hidden Search material fixture", GetLastError()) }
        defer { _ = DestroyWindow(parent) }
        var controls: [HWND] = []
        for (kind, text, x, y, width, height) in [("EDIT", "Visible query", 20, 20, 360, 40),
            ("STATIC", "Visible status", 20, 70, 360, 30), ("LISTBOX", "Results", 20, 110, 360, 200)] {
            let control = withWideString(kind) { name in withWideString(text) {
                CreateWindowExW(0, name, $0, DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS),
                    Int32(x), Int32(y), Int32(width), Int32(height), parent, nil, GetModuleHandleW(nil), nil)
            } }
            guard let control else { throw WindowsError.api("Create overlapping Search control fixture", GetLastError()) }
            controls.append(control)
        }
        _ = withWideString("Visible result") { SendMessageW(controls[2], UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
        try expect(GetWindowTextLengthW(controls[0]) > 0 && GetWindowTextLengthW(controls[1]) > 0 &&
            SendMessageW(controls[2], UINT(LB_GETCOUNT), 0, 0) == 1, "nonempty overlapping native controls")
        let expectedChildren = Set(controls.map { Int(bitPattern: $0) })
        var warmedResources: (gdi: DWORD, user: DWORD)?
        var minimumWarmUser = DWORD.max, minimumUser = DWORD.max, maximumUser: DWORD = 0
        // USER is an OS aggregate: observed transient framework objects fluctuate by one without new HWNDs.
        // Bound that envelope for eighteen measured reopens; owned HWNDs and GDI still require exact cleanup.
        // This checks GUI resource growth, not COM references, GPU allocations or private memory.
        for cycle in 0..<20 {
            let backdrop = try NativeSearchBackdrop(parent: parent)
            try expect(backdrop.resize(width: 640, height: 360, cornerRadius: 16, highContrast: true),"high contrast material sizing")
            var fallback: boolean = 0
            try SearchXamlReferences.check(backdrop.acrylic.pointee.lpVtbl.pointee.get_AlwaysUseFallback(backdrop.acrylic, &fallback), "Read Search contrast fallback")
            try expect(fallback != 0, "high contrast fallback")
            try expect(backdrop.resize(width: 640, height: 360, cornerRadius: 16, highContrast: false),"material sizing")
            try checkFrame(backdrop.window)
            try expect(IsWindow(backdrop.window) && !IsWindowVisible(parent) && !IsWindowVisible(backdrop.window), "hidden HWND ownership")
            var bounds = RECT()
            try expect(GetClientRect(backdrop.window, &bounds) && bounds.right == 640 && bounds.bottom == 360, "native child sizing")
            try expect(GetWindowLongPtrW(backdrop.window, Int32(GWL_STYLE)) & LONG_PTR(WS_CLIPSIBLINGS) != 0 &&
                GetParent(backdrop.window) == parent && GetWindow(backdrop.window, UINT(GW_HWNDNEXT)) == nil,
                "material clips higher sibling controls at bottom z-order")
            for control in controls {
                try expect(GetParent(control) == parent && IsWindow(control) &&
                    GetWindowLongPtrW(control, Int32(GWL_STYLE)) & LONG_PTR(WS_CLIPSIBLINGS) != 0,
                    "overlapping native sibling ownership and clipping")
            }
            try expect(GetWindowLongPtrW(backdrop.window, Int32(GWL_STYLE)) & LONG_PTR(WS_TABSTOP) == 0 &&
                GetWindowLongPtrW(backdrop.window, Int32(GWL_EXSTYLE)) & LONG_PTR(WS_EX_CONTROLPARENT) == 0, "skip native tab traversal")
            try expect(SendMessageW(backdrop.window, UINT(WM_NCHITTEST), 0, LPARAM(50 | (50 << 16))) == LRESULT(HTTRANSPARENT), "transparent HWND hit testing")
            // Let lazy framework work run while a warm-up island still owns its content.
            if cycle < 2 { settle() }
            var sourceWindows = children(of: backdrop.window)
            sourceWindows.insert(Int(bitPattern: backdrop.window))
            backdrop.close(); backdrop.close()
            try expect(!IsWindow(backdrop.window), "source HWND destruction")
            let releaseDeadline = GetTickCount64() + 1500
            settle()
            var counts = resources()
            if cycle < 2 {
                let sampleDeadline = GetTickCount64() + 200
                repeat {
                    minimumWarmUser = min(minimumWarmUser, counts.user)
                    settle(milliseconds: 10); counts = resources()
                } while GetTickCount64() < sampleDeadline
            }
            func ownedWindowsReleased() -> Bool {
                sourceWindows.allSatisfy { !IsWindow(HWND(bitPattern: $0)) } &&
                    children(of: parent) == expectedChildren && sources == 0
            }
            func balanced(_ baseline: (gdi: DWORD, user: DWORD)) -> Bool {
                ownedWindowsReleased() && counts.gdi == baseline.gdi &&
                    counts.user >= DWORD(expectedChildren.count + 1) && counts.user <= baseline.user + 1
            }
            while let warmedResources, !balanced(warmedResources), GetTickCount64() < releaseDeadline {
                settle(milliseconds: 10)
                counts = resources()
            }
            try expect(ownedWindowsReleased(), "all source descendants destroyed and exact native parent child inventory restored")
            if let warmedResources {
                try expect(counts.gdi == warmedResources.gdi, "exact GDI cleanup after reopen \(cycle + 1)")
                try expect(balanced(warmedResources), "bounded USER growth after reopen \(cycle + 1) (warm minimum \(warmedResources.user), current \(counts.user), ceiling \(warmedResources.user + 1))")
                minimumUser = min(minimumUser, counts.user); maximumUser = max(maximumUser, counts.user)
            } else if cycle == 1 {
                try expect(minimumWarmUser >= DWORD(expectedChildren.count + 1) && minimumWarmUser < DWORD.max,
                    "valid warmed native resource counts")
                let baseline = (gdi: counts.gdi, user: minimumWarmUser)
                warmedResources = baseline
                var leakedChildren: [HWND] = []
                defer { for child in leakedChildren { _ = DestroyWindow(child) } }
                for _ in 0..<3 {
                    let child = withWideString("STATIC") { CreateWindowExW(0, $0, nil, DWORD(WS_CHILD),
                        0, 0, 8, 8, parent, nil, GetModuleHandleW(nil), nil) }
                    guard let child else { throw WindowsError.api("Create positive HWND leak control", GetLastError()) }
                    leakedChildren.append(child)
                }
                // Deleted regions may occupy cached GDI slots; a memory DC has an immediate counted lifetime.
                let beforeDC = resources().gdi
                guard let dc = CreateCompatibleDC(nil) else { throw WindowsError.api("Create positive GDI leak control", GetLastError()) }
                var dcOwned = true
                defer { if dcOwned { DeleteDC(dc) } }
                counts = resources()
                try expect(children(of: parent) != expectedChildren, "owned-child leak control is detected")
                try expect(counts.user > baseline.user + 1, "USER leak control exceeds the fixed envelope")
                let retainedDC = counts.gdi
                try expect(GetObjectType(dc) == DWORD(OBJ_MEMDC) && retainedDC == beforeDC + 1 && retainedDC > baseline.gdi,
                    "GDI leak control is detected (warm \(baseline.gdi), before DC \(beforeDC), retained DC \(retainedDC))")
                try expect(DeleteDC(dc), "release positive GDI leak control"); dcOwned = false
                let releasedDC = resources().gdi
                try expect(releasedDC == beforeDC,
                    "GDI control restores its exact count (before \(beforeDC), retained \(retainedDC), released \(releasedDC))")
                Console.writeLine("Search GDI leak control: before \(beforeDC), retained \(retainedDC), released \(releasedDC).")
                for child in leakedChildren { try expect(DestroyWindow(child), "release positive HWND leak control") }
                leakedChildren.removeAll()
                let controlDeadline = GetTickCount64() + 1500
                repeat {
                    counts = resources()
                    if balanced(baseline) { break }
                    settle(milliseconds: 10)
                } while GetTickCount64() < controlDeadline
                try expect(balanced(baseline), "positive leak controls restore exact ownership/GDI and bounded USER baseline")
            }
        }
        Console.writeLine("Search material stress: 20 reopens, exact owned HWND/GDI cleanup, USER aggregate \(minimumUser)...\(maximumUser) within warm minimum \(minimumWarmUser)+1; positive leak controls detected and cleaned.")
        try expect(PostThreadMessageW(GetCurrentThreadId(), UINT(WM_QUIT), 37, 0) &&
            PostThreadMessageW(GetCurrentThreadId(), UINT(WM_QUIT), 91, 0), "queue distinct quit fixture")
        shutdown(); shutdown()
        try expect(PeekMessageW(&message, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)) &&
            message.wParam == 37, "preserve first quit")
        try expect(!PeekMessageW(&message, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)), "quit only once")
        do {
            _ = try NativeSearchBackdrop(parent: parent)
        } catch { return }
        throw WindowsError.unsupported("Search material manager restarted after shutdown.")
    }

    static func shutdown() {
        guard !stopped, owner == GetCurrentThreadId(), sources == 0 else { return }
        stopped = true // Dispatched teardown messages cannot initialize another manager.
        guard let manager, let references = managerReferences else { return }
        // COM teardown can pump messages; retain the caller's exit code before entering it.
        var quit: Int32?
        var queued = MSG()
        for _ in 0..<1024 {
            guard PeekMessageW(&queued, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)) else { break }
            if quit == nil { quit = Int32(truncatingIfNeeded: queued.wParam) }
        }
        references.close(manager)
        Self.manager = nil
        managerReferences = nil
        references.release()
        // XAML teardown is asynchronous; preserve quit while draining its owning thread.
        let deadline = GetTickCount64() + 1500
        repeat {
            var message = MSG()
            var count = 0
            while count < 1024, GetTickCount64() < deadline,
                PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                count += 1
                if message.message == UINT(WM_QUIT) {
                    if quit == nil { quit = Int32(truncatingIfNeeded: message.wParam) }
                } else { _ = TranslateMessage(&message); _ = DispatchMessageW(&message) }
            }
            _ = MsgWaitForMultipleObjectsEx(0, nil, 10, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
        } while GetTickCount64() < deadline
        RoUninitialize()
        if let quit { PostQuitMessage(quit) }
    }
}
