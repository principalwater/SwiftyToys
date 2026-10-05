// SPDX-License-Identifier: MIT
import BrightnessCore
import KeyboardCore
import WinSDK
import WindowsDisplayABI

private func settingsProcedure(_ window: HWND?, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
    guard let window else { return DefWindowProcW(window, message, value, data) }
    if message == UINT(WM_NCCREATE), let creation = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(data)),
        let context = creation.pointee.lpCreateParams
    {
        SetWindowLongPtrW(window, Int32(GWLP_USERDATA), LONG_PTR(Int(bitPattern: context)))
    }
    if let context = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(window, Int32(GWLP_USERDATA)))) {
        return Unmanaged<SettingsWindow>.fromOpaque(context).takeUnretainedValue().handle(window, message, value, data)
    }
    return DefWindowProcW(window, message, value, data)
}

/// Native accessible child controls, with a small painted shell. All state belongs to the UI thread.
final class SettingsWindow {
    private(set) var window: HWND?
    private var controls: [Int: HWND] = [:]
    private var content: [HWND] = []
    private var fonts: [HFONT] = []
    private var layout: [(HWND, Int, Int, Int, Int)] = []
    private var page = 0
    private var scrollOffset: Int32 = 0
    private var keyboard: KeyboardConfiguration
    private var distributions: [LinuxDistribution] = []
    private var displays: [DisplayOutput] = []
    private var languages: [UInt16] = []
    private var level: Int
    private var selectedRule: Int?
    private let preview: Bool
    private let command: (Int, [String]) throws -> String
    private let snapshot: () -> String
    private let background = CreateSolidBrush(0x00F8_F7F4)
    private let white = CreateSolidBrush(0x00FF_FFFF)
    private let dark = CreateSolidBrush(0x0033_2920)
    private let titles = [
        "Обзор", "Яркость", "Клавиатура", "Языки ввода", "Рабочий стол", "Мышь", "Homebrew", "О SwiftyToys",
    ]
    init(
        brightness: Int, keyboard: KeyboardConfiguration, preview: Bool = false,
        command: @escaping (Int, [String]) throws -> String, snapshot: @escaping () -> String
    ) throws {
        self.level = brightness
        self.keyboard = keyboard
        self.preview = preview
        self.command = command
        self.snapshot = snapshot
        var common = INITCOMMONCONTROLSEX()
        common.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        common.dwICC = DWORD(ICC_BAR_CLASSES)
        InitCommonControlsEx(&common)
        var type = WNDCLASSEXW()
        type.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        type.lpfnWndProc = settingsProcedure
        type.hInstance = GetModuleHandleW(nil)
        type.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        _ = withWideString("SwiftyToys.Settings") {
            type.lpszClassName = $0
            return RegisterClassExW(&type)
        }
        window = withWideString("SwiftyToys.Settings") { name in
            withWideString("SwiftyToys") {
                CreateWindowExW(
                    DWORD(WS_EX_CONTROLPARENT), name, $0,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN | WS_VSCROLL), Int32(CW_USEDEFAULT),
                    Int32(CW_USEDEFAULT), 1080, 790, nil, nil, GetModuleHandleW(nil),
                    Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard window != nil else { throw WindowsError.api("Create settings window", GetLastError()) }
        if let window {
            var monitor = MONITORINFO()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            if GetMonitorInfoW(MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) {
                let area = monitor.rcWork
                let width = min(area.right - area.left, Int32(1080 * scale))
                let height = min(area.bottom - area.top, Int32(790 * scale))
                SetWindowPos(
                    window, nil, area.left + (area.right - area.left - width) / 2,
                    area.top + (area.bottom - area.top - height) / 2, width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE)
                )
            }
        }
        makeFonts()
        label("SwiftyToys", 10, 25, 26, 190, 40, large: true, sidebar: true)
        label("Привычки Mac. Возможности Windows.", 11, 25, 78, 188, 50, sidebar: true)
        for index in titles.indices { button(titles[index], 100 + index, 18, 154 + index * 49, 206, 42, sidebar: true) }
        label("SWIFT • NATIVE • OPEN SOURCE", 12, 25, 610, 184, 40, sidebar: true)
        renderPage()
    }
    func show() {
        guard let window else { return }
        ShowWindow(window, Int32(SW_SHOW))
        ShowWindow(window, Int32(SW_RESTORE))
        SetForegroundWindow(window)
    }
    func dialogMessage(_ message: inout MSG) -> Bool {
        guard let window, IsWindowVisible(window) else { return false }
        let handled=IsDialogMessageW(window, &message)
        if handled, let focus=GetFocus(), content.contains(focus) {
            var area=RECT(); var client=RECT(); GetWindowRect(focus,&area); GetClientRect(window,&client)
            _ = withUnsafeMutablePointer(to:&area) { $0.withMemoryRebound(to:POINT.self,capacity:2) { MapWindowPoints(nil,window,$0,2) } }
            if area.top < 0 { scrollOffset=max(0,scrollOffset+area.top) }
            else if area.bottom > client.bottom { scrollOffset += area.bottom-client.bottom+8 }
            arrange(); InvalidateRect(window,nil,true)
        }
        return handled
    }
    func update(brightness: Int) {
        level = brightness
        if let label = controls[210] { setText(label, "\(brightness)%") }
        if page == 0, let label = controls[24] { setText(label, snapshot()) }
    }
    /// Tests this application's own native controls without sending desktop input.
    func validateLayout() throws {
        guard let window else { throw WindowsError.unsupported("Missing settings window.") }
        var client = RECT()
        GetClientRect(window, &client)
        for index in titles.indices {
            page = index
            renderPage()
            for id in 100...107 {
                guard let navigation = controls[id], IsWindow(navigation), !text(id).isEmpty else {
                    throw WindowsError.unsupported("Missing native navigation control.")
                }
            }
            for handle in content {
                var area = RECT()
                guard GetWindowRect(handle, &area) else {
                    throw WindowsError.api("Read own control bounds", GetLastError())
                }
                _ = withUnsafeMutablePointer(to: &area) {
                    $0.withMemoryRebound(to: POINT.self, capacity: 2) { MapWindowPoints(nil, window, $0, 2) }
                }
                guard area.left >= 0, area.top >= 0, area.right <= client.right,
                    area.bottom <= max(client.bottom, Int32(720 * scale))
                else {
                    throw WindowsError.unsupported(
                        "Settings control clipped on page \(page): \(area.left),\(area.top),\(area.right),\(area.bottom); client \(client.right)×\(client.bottom), scale \(scale)."
                    )
                }
            }
        }
        page = 0
        renderPage()
    }
    private var scale: Double { window.map { Double(GetDpiForWindow($0)) / 96 } ?? 1 }
    private func makeFonts() {
        for font in fonts { DeleteObject(font) }
        fonts.removeAll()
        for (size, weight) in [(15, 400), (27, 600), (18, 600)] {
            let font = withWideString("Segoe UI") {
                CreateFontW(
                    -Int32(Double(size) * scale), 0, 0, 0, Int32(weight), 0, 0, 0, DWORD(DEFAULT_CHARSET),
                    DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), $0)
            }
            if let font { fonts.append(font) }
        }
    }
    @discardableResult private func control(
        _ type: String, _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int, style: DWORD = 0,
        sidebar: Bool = false, font: Int = 0
    ) -> HWND? {
        guard let window else { return nil }
        let handle = withWideString(type) { name in
            withWideString(text) {
                CreateWindowExW(
                    type == "EDIT" || type == "LISTBOX" ? DWORD(WS_EX_CLIENTEDGE) : 0, name, $0,
                    DWORD(WS_CHILD | WS_VISIBLE) | style, 0, 0, 1, 1, window, HMENU(bitPattern: id),
                    GetModuleHandleW(nil), nil)
            }
        }
        if let handle {
            controls[id] = handle
            layout.append((handle, x, y, width, height))
            if !sidebar { content.append(handle) }
            if font < fonts.count { SendMessageW(handle, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[font])), 1) }
            if type == "EDIT" { SendMessageW(handle, UINT(EM_SETLIMITTEXT), 512, 0) }
        }
        return handle
    }
    private func label(
        _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int, large: Bool = false,
        sidebar: Bool = false
    ) { _ = control("STATIC", text, id, x, y, width, height, sidebar: sidebar, font: large ? 1 : 0) }
    private func button(
        _ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int = 36, sidebar: Bool = false
    ) {
        _ = control("BUTTON", text, id, x, y, width, height, style: DWORD(WS_TABSTOP | BS_OWNERDRAW), sidebar: sidebar)
    }
    private func edit(_ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int) {
        _ = control("EDIT", text, id, x, y, width, 32, style: DWORD(WS_TABSTOP | ES_AUTOHSCROLL))
    }
    private func check(_ text: String, _ id: Int, _ x: Int, _ y: Int, _ width: Int, on: Bool) {
        if let handle = control("BUTTON", text, id, x, y, width, 30, style: DWORD(WS_TABSTOP | BS_AUTOCHECKBOX)) {
            SendMessageW(handle, UINT(BM_SETCHECK), on ? WPARAM(BST_CHECKED) : WPARAM(BST_UNCHECKED), 0)
        }
    }
    private func combo(_ items: [String], _ id: Int, _ x: Int, _ y: Int, _ width: Int, editable: Bool = false) {
        if let handle = control(
            "COMBOBOX", "", id, x, y, width, 220,
            style: DWORD(WS_TABSTOP | WS_VSCROLL) | DWORD(editable ? CBS_DROPDOWN : CBS_DROPDOWNLIST))
        {
            for item in items {
                _ = withWideString(item) { SendMessageW(handle, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
            }
            SendMessageW(handle, UINT(CB_SETCURSEL), 0, 0)
        }
    }
    private func text(_ id: Int) -> String {
        guard let handle = controls[id] else { return "" }
        let capacity=min(8192,max(0,Int(GetWindowTextLengthW(handle))))+1
        var buffer = Array(repeating: WCHAR(0), count: capacity)
        let count = GetWindowTextW(handle, &buffer, Int32(capacity))
        return String(decoding: buffer.prefix(Int(max(0, count))), as: UTF16.self)
    }
    private func checked(_ id: Int) -> Bool {
        controls[id].map { SendMessageW($0, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) } ?? false
    }
    private func setText(_ handle: HWND, _ text: String) { _ = withWideString(text) { SetWindowTextW(handle, $0) } }
    private func status(_ text: String) { if let handle = controls[99] { setText(handle, text) } }
    private func renderPage() {
        guard let window else { return }
        scrollOffset = 0
        for handle in content { DestroyWindow(handle) }
        layout.removeAll { content.contains($0.0) }
        controls = controls.filter { !content.contains($0.value) }
        content.removeAll()
        label(titles[page], 20, 276, 30, 720, 48, large: true)
        let subtitles = [
            "Небольшие инструменты для удобной работы каждый день.",
            "Точный контроль выбранного экрана — с сохранением калибровки.",
            "Настройте клавиши, сочетания и действия под свои привычки.",
            "Переключайте раскладки и настройте Caps Lock как на Mac.",
            "Оставьте важное окно на виду и управляйте режимом сна.", "Привычное направление прокрутки — как на Mac.",
            "Знакомый менеджер пакетов — в Linux внутри Windows.",
            "Создано для пользователей Mac и тех, кто перешёл на Windows.",
        ]
        label(subtitles[page], 21, 278, 88, 718, 45)
        switch page {
        case 0:
            label("Ваш Mac-профиль", 22, 300, 170, 640, 32, large: true)
            label(
                "Ctrl + Space     переключение языка\n⌘ + Tab             переключение окон\n⌘ + C / V / Z     привычные команды редактирования",
                23, 300, 222, 650, 104)
            label(snapshot(), 24, 300, 352, 650, 60)
            button("Настроить клавиатуру", 901, 300, 442, 248)
            button("Настроить яркость", 902, 568, 442, 222)
            label("Всё локально. Нативный интерфейс. Открытый исходный код.", 25, 300, 535, 650, 50)
        case 1:
            label("Яркость экрана", 210, 300, 172, 300, 40, large: true)
            setText(controls[210]!, "\(level)%")
            if let slider = control(
                "msctls_trackbar32", "Яркость", 211, 300, 229, 650, 40, style: DWORD(WS_TABSTOP | TBS_AUTOTICKS))
            {
                SendMessageW(slider, UINT(TBM_SETRANGEMIN), 0, 0)
                SendMessageW(slider, UINT(TBM_SETRANGEMAX), 0, 100)
                SendMessageW(slider, UINT(TBM_SETPOS), 1, LPARAM(level))
            }
            displays = ((try? discoverDisplays()) ?? []).filter { $0.isPhysical && !$0.isCloned && !$0.isHDR }
            label("Экран", 212, 300, 294, 200, 25)
            combo(displays.map(\.name), 213, 300, 324, 444)
            button("Выбрать", 214, 764, 322, 170)
            label("Индикатор яркости", 215, 300, 378, 250, 25)
            combo(["SwiftyToys", "Windows"], 216, 300, 410, 210)
            label("Шаг, %", 217, 538, 378, 100, 25)
            edit("5", 218, 538, 410, 90)
            check("F1 / F2 без Fn", 219, 660, 410, 274, on: (try? Settings().grabFunctionKeys) ?? false)
            check(
                "Держать физическую яркость на 100% (DDC)", 244, 300, 442, 630,
                on: (try? Settings().hardwareMaximum) ?? true)
            let hotkeys =
                (try? Settings().hotkeys) ?? ["Ctrl+Alt+Up", "Ctrl+Alt+Down", "Ctrl+Alt+PageUp", "Ctrl+Alt+PageDown"]
            for index in 0..<4 {
                label(
                    ["Увеличить", "Уменьшить", "Максимум", "Минимум"][index], 220 + index, 300 + index * 166, 472, 156,
                    25)
                edit(hotkeys[index], 230 + index, 300 + index * 166, 504, 156)
            }
            button("Сохранить настройки", 240, 300, 559, 242)
            button("Переподключить экран", 241, 566, 559, 250)
        case 2:
            check("Включить переназначения", 315, 300, 152, 350, on: keyboard.enabled)
            if let list = control(
                "LISTBOX", "Правила переназначений", 301, 300, 198, 664, 207,
                style: DWORD(WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT))
            {
                for rule in keyboard.rules {
                    let row =
                        "\(rule.source.description)   →   \(rule.destination)\(rule.application.isEmpty ? "" : "   [\(rule.application)]")"
                    _ = withWideString(row) { SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
                }
            }
            label("Исходные клавиши", 302, 300, 422, 210, 25)
            edit("", 303, 300, 452, 202)
            label("Новое сочетание или действие", 304, 520, 422, 280, 25)
            combo(
                ["Switch language", "Pin window", "Disable key", "Ctrl+C", "Alt+Tab"], 305, 520, 452, 238,
                editable: true)
            label("Приложение (пусто = все)", 306, 777, 422, 220, 25)
            edit("", 307, 777, 452, 187)
            button("Добавить / изменить", 310, 300, 502, 230)
            button("Новое", 311, 545, 502, 112)
            button("Удалить", 312, 672, 502, 122)
            label("Исключить приложения (через запятую)", 316, 300, 552, 500, 25)
            edit(keyboard.excluded.joined(separator: ","), 317, 300, 582, 390)
            if let handle=controls[317] { SendMessageW(handle,UINT(EM_SETLIMITTEXT),8192,0) }
            button("Сохранить", 313, 710, 581, 122)
            button("Профиль Mac", 314, 847, 581, 117)
            selectedRule = nil
        case 3:
            label("Как переключать язык", 340, 300, 170, 630, 38, large: true)
            combo(["По кругу", "Латинская ↔ нелатинская", "Выбранная пара"], 341, 300, 226, 390)
            if let mode = controls[341] {
                SendMessageW(
                    mode, UINT(CB_SETCURSEL),
                    WPARAM(keyboard.languageMode == "latin" ? 1 : keyboard.languageMode == "pair" ? 2 : 0), 0)
            }
            var seen = Set<UInt16>()
            languages = configuredLayouts().map { UInt16(truncatingIfNeeded: UInt(bitPattern: $0)) }.filter {
                seen.insert($0).inserted
            }
            label("Первая раскладка пары", 342, 300, 288, 290, 25)
            combo(languages.map(languageName), 343, 300, 320, 290)
            label("Вторая раскладка пары", 344, 620, 288, 320, 25)
            combo(languages.map(languageName), 345, 620, 320, 324)
            for (offset, id) in [343, 345].enumerated() {
                let language =
                    keyboard.languagePair.indices.contains(offset)
                    ? keyboard.languagePair[offset] : languages.indices.contains(offset) ? languages[offset] : 0
                if let index = languages.firstIndex(of: language), let combo = controls[id] {
                    SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
                }
            }
            check("Caps Lock: короткое нажатие / удержание", 346, 300, 392, 640, on: keyboard.smartCaps)
            label("Короткое нажатие", 347, 300, 448, 300, 25)
            combo(["Switch language", "Pin window", "Disable key", "Ctrl+Space"], 348, 300, 480, 300, editable: true)
            if let combo = controls[348] { setText(combo, keyboard.capsAction) }
            label("Удержание, мс (150–800)", 349, 636, 448, 320, 25)
            edit(String(keyboard.capsThreshold), 351, 636, 480, 130)
            label(
                "Удержание включает Caps Lock. Когда Caps уже включён, тап выключает его.\nShift + Caps Lock сохраняет обычное поведение. CJK IME не перехватывается.\nСочетание Ctrl + Space меняется в разделе «Клавиатура».",
                352, 300, 537, 650, 82)
            button("Сохранить переключение", 350, 300, 611, 288)
        case 4:
            label("Поверх остальных", 400, 300, 172, 550, 36, large: true)
            label(
                "⌘ + Ctrl + T закрепляет активное окно.\nПовторное нажатие возвращает обычный порядок окон.", 401, 300,
                226, 620, 62)
            label("Не засыпать", 402, 300, 344, 500, 36, large: true)
            label("Временный режим: системные параметры питания сохраняются.", 403, 300, 397, 620, 48)
            combo(["30 минут", "1 час", "2 часа", "8 часов"], 404, 300, 466, 200)
            check("Оставить экран включённым", 405, 526, 466, 380, on: false)
            button("Включить", 410, 300, 526, 180)
            button("Отключить", 411, 500, 526, 180)
        case 5:
            label("Естественная прокрутка", 420, 300, 176, 640, 40, large: true)
            label(
                "Измените направление колёсика обычной мыши.\nВертикальная и горизонтальная прокрутка настраиваются отдельно.",
                421, 300, 234, 640, 64)
            check("Инвертировать вертикальное колесо", 422, 300, 338, 640, on: keyboard.reverseVertical)
            check("Инвертировать горизонтальное колесо", 423, 300, 392, 640, on: keyboard.reverseHorizontal)
            label(
                "Настройка общая для всех устройств, которые отправляют wheel-события.\nТачпад может иметь собственную настройку направления в Windows.\nCtrl / Shift / Alt / Command + колесо сохраняют поведение приложения.\nИсключения приложений общие с разделом «Клавиатура».",
                424, 300, 460, 640, 112)
            button("Сохранить направление", 430, 300, 591, 260)
            button("Настройки мыши Windows", 431, 580, 591, 320)
        case 6:
            distributions = LinuxDistribution.installed()
            label(
                distributions.isEmpty ? "Сначала установите WSL 2" : "Выберите Linux-дистрибутив", 500, 300, 170, 660,
                40, large: true)
            label(
                "Homebrew устанавливается внутри WSL 2.\nWindows-приложения устанавливаются отдельно, например через winget.",
                501, 300, 228, 650, 74)
            combo(distributions.map { "\($0.name) (WSL \($0.version))" }, 502, 300, 326, 450)
            button("Обновить список", 503, 772, 324, 192)
            button("Установить WSL + Ubuntu", 510, 300, 393, 282)
            button("Установить Homebrew", 511, 604, 393, 278)
            label(
                "WSL может потребовать права администратора и перезагрузку.\nПосле первого запуска Ubuntu создайте пользователя Linux.\nHomebrew откроет терминал: вы увидите шаги и сами введёте пароль sudo.\nЗатем появятся brew и настройка PATH для Bash.",
                504, 300, 468, 650, 120)
            button("Официальная инструкция", 512, 300, 609, 282)
        default:
            label("SwiftyToys  \(AppVersion.string)", 600, 300, 170, 650, 40, large: true)
            label(
                "Swift + нативные Windows API. Локальные настройки, без телеметрии.\n\nУправление яркостью основано на BrightnessCtl.\nИнтерфейс и идея набора инструментов вдохновлены Microsoft PowerToys.\nSwiftyToys дополняет PowerToys функциями для привычек Mac.\n\nMIT License. Независимый проект; не связан с Microsoft или Apple.",
                601, 300, 234, 650, 210)
            button("Microsoft PowerToys", 610, 300, 488, 254)
            button("BrightnessCtl", 611, 579, 488, 232)
        }
        label(preview ? "Предпросмотр интерфейса — изменения отключены." : "", 99, 278, 668, 700, 46)
        arrange()
        InvalidateRect(window, nil, true)
    }
    private func arrange() {
        guard let window else { return }
        var area = RECT()
        GetClientRect(window, &area)
        var scroll = SCROLLINFO()
        scroll.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        scroll.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS)
        scroll.nMin = 0
        scroll.nMax = Int32(720 * scale)
        scroll.nPage = UINT(max(0, area.bottom))
        scroll.nPos = scrollOffset
        SetScrollInfo(window, Int32(SB_VERT), &scroll, true)
        scrollOffset = GetScrollPos(window, Int32(SB_VERT))
        let extra = max(0, Int(Double(area.right) / scale) - 1030)
        for (handle, x, y, width, height) in layout {
            let top = Int32(Double(y) * scale) - (x >= 276 ? scrollOffset : 0)
            let footer = handle == controls[12] ? min(top, area.bottom - Int32(50 * scale)) : top
            MoveWindow(
                handle, Int32(Double(x) * scale), footer,
                Int32(Double(width + (x >= 276 && width >= 600 ? extra : 0)) * scale), Int32(Double(height) * scale),
                true)
        }
    }
    fileprivate func handle(_ window: HWND, _ message: UINT, _ value: WPARAM, _ data: LPARAM) -> LRESULT {
        switch message {
        case UINT(WM_CLOSE):
            ShowWindow(window, Int32(SW_HIDE))
            if preview {
                DestroyWindow(window)
                PostQuitMessage(0)
            }
            return 0
        case UINT(WM_SIZE):
            arrange()
            return 0
        case UINT(WM_GETMINMAXINFO):
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(data)) {
                info.pointee.ptMinTrackSize = POINT(x: Int32(1048 * scale), y: Int32(620 * scale))
            }
            return 0
        case UINT(WM_VSCROLL):
            var info = SCROLLINFO()
            info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
            info.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS)
            GetScrollInfo(window, Int32(SB_VERT), &info)
            switch Int(value & 0xFFFF) {
            case Int(SB_LINEUP): scrollOffset -= Int32(32 * scale)
            case Int(SB_LINEDOWN): scrollOffset += Int32(32 * scale)
            case Int(SB_PAGEUP): scrollOffset -= Int32(info.nPage)
            case Int(SB_PAGEDOWN): scrollOffset += Int32(info.nPage)
            case Int(SB_THUMBTRACK): scrollOffset = info.nTrackPos
            default: break
            }
            scrollOffset = max(0, min(scrollOffset, info.nMax - Int32(info.nPage) + 1))
            arrange()
            InvalidateRect(window, nil, true)
            return 0
        case UINT(WM_MOUSEWHEEL):
            let delta=Int32(Int16(bitPattern:UInt16(truncatingIfNeeded:value >> 16)))
            scrollOffset=max(0,scrollOffset-delta*Int32(40*scale)/120); arrange(); InvalidateRect(window,nil,true); return 0
        case UINT(WM_DPICHANGED):
            if let area = UnsafePointer<RECT>(bitPattern: Int(data))?.pointee {
                SetWindowPos(
                    window, nil, area.left, area.top, area.right - area.left, area.bottom - area.top,
                    UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            makeFonts()
            for handle in controls.values {
                if !fonts.isEmpty { SendMessageW(handle, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: fonts[0])), 1) }
            }
            renderPage()
            return 0
        case UINT(WM_COMMAND):
            let id = Int(value & 0xFFFF)
            let notification = Int((value >> 16) & 0xFFFF)
            if (100...107).contains(id), notification == Int(BN_CLICKED) {
                page = id - 100
                renderPage()
                return 0
            }
            if id == 901 || id == 902 {
                page = id == 901 ? 2 : 1
                renderPage()
                return 0
            }
            if id == 301, notification == Int(LBN_SELCHANGE), let list = controls[301] {
                let index = Int(SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
                if keyboard.rules.indices.contains(index) {
                    selectedRule = index
                    let rule = keyboard.rules[index]
                    if let from = controls[303] { setText(from, rule.source.description) }
                    if let to = controls[305] { setText(to, rule.destination) }
                    if let app = controls[307] { setText(app, rule.application) }
                }
                return 0
            }
            guard notification == Int(BN_CLICKED) else { break }
            do {
                if id == 311 {
                    selectedRule = nil
                    if let handle = controls[303] {
                        setText(handle, "")
                        SetFocus(handle)
                    }
                    return 0
                }
                if id == 310 {
                    let rule = try RemapRule(from: text(303), to: text(305), application: text(307))
                    if let index = selectedRule {
                        keyboard.rules[index] = rule
                    } else {
                        guard keyboard.rules.count < 64 else { throw WindowsError.unsupported("Maximum 64 rules.") }
                        keyboard.rules.append(rule)
                    }
                    renderPage()
                    return 0
                }
                if id == 312, let index = selectedRule {
                    keyboard.rules.remove(at: index)
                    renderPage()
                    return 0
                }
                if id == 314 {
                    keyboard.rules = RemapRule.macPreset
                    renderPage()
                    status("Профиль восстановлен. Нажмите «Сохранить».")
                    return 0
                }
                if id == 503 {
                    renderPage()
                    return 0
                }
                if id == 512 {
                    try shellOpen("https://docs.brew.sh/Installation")
                    return 0
                }
                if id == 610 || id == 611 {
                    try shellOpen(
                        id == 610
                            ? "https://github.com/microsoft/PowerToys"
                            : "https://github.com/principalwater/BrightnessCtl")
                    return 0
                }
                guard !preview else {
                    status("Предпросмотр: запустите обычную версию для применения.")
                    return 0
                }
                if id == 313 {
                    keyboard.enabled = checked(315)
                    keyboard.excluded = text(317).split(separator: ",").map { $0.trimmingWhitespace().lowercased() }
                    try keyboard.save()
                    status(try command(id, []))
                } else if id == 510 {
                    try shellOpen("wsl.exe", arguments: "--install -d Ubuntu", elevated: true, owner: window)
                    status("Завершите установку и первый запуск Ubuntu, затем обновите список.")
                } else if id == 511 {
                    let index = controls[502].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    guard distributions.indices.contains(index) else {
                        throw WindowsError.unsupported("Install and initialize a WSL 2 distribution first.")
                    }
                    try distributions[index].openHomebrewInstaller()
                    status("Официальный установщик открыт в терминале Linux.")
                } else if id == 214 {
                    let index = controls[213].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    guard displays.indices.contains(index) else {
                        throw WindowsError.unsupported("No eligible physical SDR display.")
                    }
                    status(try command(id, [displays[index].id]))
                } else if id == 240 {
                    status(
                        try command(
                            id,
                            [text(216), text(218), checked(219) ? "1" : "0"] + (230...233).map { text($0) } + [
                                checked(244) ? "1" : "0"
                            ]))
                } else if id == 410 {
                    status(try command(id, [text(404), checked(405) ? "1" : "0"]))
                } else if id == 430 {
                    keyboard.reverseVertical = checked(422)
                    keyboard.reverseHorizontal = checked(423)
                    status(
                        try command(id, [keyboard.reverseVertical ? "1" : "0", keyboard.reverseHorizontal ? "1" : "0"]))
                } else if id == 431 {
                    try shellOpen("ms-settings:mousetouchpad")
                } else if id == 350 {
                    let mode = controls[341].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? 0
                    let first = controls[343].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    let second = controls[345].map { Int(SendMessageW($0, UINT(CB_GETCURSEL), 0, 0)) } ?? -1
                    let pair =
                        languages.indices.contains(first) && languages.indices.contains(second)
                        ? [languages[first], languages[second]] : []
                    keyboard.smartCaps = checked(346)
                    keyboard.capsThreshold = Int(text(351)) ?? 0
                    keyboard.capsAction = text(348)
                    keyboard.languageMode = mode == 1 ? "latin" : mode == 2 ? "pair" : "cycle"
                    keyboard.languagePair = pair
                    status(
                        try command(
                            id,
                            [
                                keyboard.smartCaps ? "1" : "0", String(keyboard.capsThreshold), keyboard.capsAction,
                                keyboard.languageMode, pair.map(String.init).joined(separator: ","),
                            ]))
                } else {
                    status(try command(id, []))
                }
            } catch { status(String(describing: error)) }
            return 0
        case UINT(WM_HSCROLL):
            if let slider = controls[211] {
                level = Int(SendMessageW(slider, UINT(TBM_GETPOS), 0, 0))
                if let label = controls[210] { setText(label, "\(level)%") }
                SetTimer(window, 24, 120, nil)
            }
            return 0
        case UINT(WM_TIMER):
            if value == 24 {
                KillTimer(window, 24)
                if !preview {
                    do { status(try command(211, [String(level)])) } catch { status(String(describing: error)) }
                }
            }
            return 0
        case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
            let dc = HDC(bitPattern: UInt(value))
            SetBkMode(dc, Int32(TRANSPARENT))
            let child = HWND(bitPattern: Int(data))
            let sidebar = controls.filter { $0.key < 20 }.values.contains { $0 == child }
            SetTextColor(dc, sidebar ? 0x00C9_C8C3 : 0x0036_2B24)
            SetBkColor(dc, sidebar ? 0x0033_2920 : 0x00FF_FFFF)
            return LRESULT(Int(bitPattern: sidebar ? dark : white))
        case UINT(WM_DRAWITEM):
            if let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: Int(data))?.pointee { drawButton(item) }
            return 1
        case UINT(WM_ERASEBKGND): return 1
        case UINT(WM_PAINT):
            paint(window)
            return 0
        default: break
        }
        return DefWindowProcW(window, message, value, data)
    }
    private func paint(_ window: HWND) {
        var paint = PAINTSTRUCT()
        guard let dc = BeginPaint(window, &paint) else { return }
        defer { EndPaint(window, &paint) }
        var area = RECT()
        GetClientRect(window, &area)
        FillRect(dc, &area, background)
        let brush = CreateSolidBrush(0x0033_2920)
        defer { DeleteObject(brush) }
        var sidebar = area
        sidebar.right = Int32(242 * scale)
        FillRect(dc, &sidebar, brush)
        let previous = SelectObject(dc, white)
        let pen = CreatePen(Int32(PS_SOLID), 1, 0x00EA_E6E0)
        let oldPen = SelectObject(dc, pen)
        RoundRect(
            dc, Int32(278 * scale), Int32(142 * scale) - scrollOffset, area.right - Int32(30 * scale),
            Int32(649 * scale) - scrollOffset, Int32(16 * scale), Int32(16 * scale))
        SelectObject(dc, previous)
        SelectObject(dc, oldPen)
        DeleteObject(pen)
    }
    private func drawButton(_ item: DRAWITEMSTRUCT) {
        guard let dc = item.hDC else { return }
        let id = Int(item.CtlID)
        let nav = (100...107).contains(id)
        let selected = nav && id == page + 100
        let pressed = item.itemState & UINT(ODS_SELECTED) != 0
        let color: COLORREF = nav ? (selected ? 0x0056_4434 : 0x0033_2920) : (pressed ? 0x00D9_CAB9 : 0x00F0_E9E1)
        let brush = CreateSolidBrush(color)
        let oldBrush = SelectObject(dc, brush)
        let pen = CreatePen(Int32(PS_SOLID), 1, color)
        let oldPen = SelectObject(dc, pen)
        RoundRect(
            dc, item.rcItem.left, item.rcItem.top, item.rcItem.right, item.rcItem.bottom, Int32(10 * scale),
            Int32(10 * scale))
        SelectObject(dc, oldBrush)
        SelectObject(dc, oldPen)
        DeleteObject(brush)
        DeleteObject(pen)
        SetBkMode(dc, Int32(TRANSPARENT))
        SetTextColor(dc, nav ? 0x00FF_FFFF : 0x0036_2B24)
        let font = fonts.first.map { SelectObject(dc, $0) }
        defer { if let font { SelectObject(dc, font) } }
        var rect = item.rcItem
        if nav { rect.left += Int32(16 * scale) }
        _ = withWideString(text(id)) {
            DrawTextW(dc, $0, -1, &rect, UINT(DT_SINGLELINE | DT_VCENTER) | UINT(nav ? DT_LEFT : DT_CENTER))
        }
        if item.itemState & UINT(ODS_FOCUS) != 0 {
            var focus = item.rcItem
            InflateRect(&focus, -4, -4)
            DrawFocusRect(dc, &focus)
        }
    }
    deinit {
        if let window, IsWindow(window) { DestroyWindow(window) }
        for font in fonts { DeleteObject(font) }
        DeleteObject(background)
        DeleteObject(white)
        DeleteObject(dark)
    }
}
