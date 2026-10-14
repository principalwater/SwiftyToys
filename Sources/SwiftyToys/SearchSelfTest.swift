// SPDX-License-Identifier: MIT
import BrightnessCore
import KeyboardCore
import SearchCore
import WinSDK

func testNativeSearchPolicy() throws {
    func expect(_ value: Bool, _ detail: String) throws { guard value else { throw WindowsError.unsupported("Search policy check failed: " + detail) } }
    let configuration = try KeyboardConfiguration(contents:nil)
    let source = try KeyChord("Win+Space")
    try expect(try configuration.routingSearch(enabled:true).rules.first { $0.source == source }?.action == "open search","Mac shortcut routes to local search")
    try expect(try configuration.routingSearch(enabled:false).rules == configuration.rules,"disabled search preserves native preset")
    var customized = configuration
    customized.rules.removeAll { $0.source == source }
    customized.rules.append(try RemapRule(from:"Win+Space",to:"Ctrl+F"))
    try expect(try customized.routingSearch(enabled:true).rules.first { $0.source == source }?.target == KeyChord("Ctrl+F"),"custom shortcut preserved")
    let explicit = try KeyboardConfiguration(contents:"# macPresetVersion=1\n# searchRule\tWin+Space\tOpen search\t\n")
    try expect(explicit.rules.count == 1 && explicit.rules[0].action == "open search","rollback-compatible action parses")
    try expect(!SearchPreferences(contents:"enabled=0\nsemantic=0\n").enabled,"feature switch")
    try expect(!SearchPreferences(contents:"").semantic,"model is opt-in")
    let defaults = SearchPreferences(contents: "")
    try expect(defaults.allLocalDrives && !defaults.media && !defaults.indexPaused,
        "local scope is automatic; media download and pause remain explicit")
    try expect(defaults.quickKeys.match("calc") == nil, "Quick Keys are opt-in")
    var commandPreferences = defaults
    commandPreferences.quickKeys = try SearchQuickKeys(editorText:
        "calc = Calculator\nзвук = Sound settings\nsleep = Sleep")
    let commandRoundTrip = SearchPreferences(contents: commandPreferences.serialized)
    try expect(commandRoundTrip.quickKeys == commandPreferences.quickKeys
        && commandRoundTrip.quickKeys.match("CALC")?.id == "action:calculator"
        && commandRoundTrip.quickKeys.match("sleep")?.id == "action:sleep"
        && commandRoundTrip.quickKeys.match("cal") == nil,
        "bounded Quick Keys round-trip without executing commands or writing preferences")
    try commandRoundTrip.validate()
    for invalid in ["quickKey=calc|action:unknown\n", "quickKey=calc|cmd.exe\n",
        "quickKey=calc|action:calculator\nquickKey=CALC|action:sleep\n"] {
        let preferences = SearchPreferences(contents: invalid)
        var rejected = false
        do { try preferences.validate() } catch { rejected = true }
        try expect(rejected && preferences.quickKeys.match("calc") == nil,
            "invalid saved Quick Keys fail closed before preference writes")
    }
    let oversizedKeys = (0..<33).map { "quickKey=key\($0)|action:calculator\n" }.joined()
    var repaired = SearchPreferences(contents: oversizedKeys)
    var rejected = false
    do { try repaired.validate() } catch { rejected = true }
    try expect(rejected && repaired.quickKeys.match("key0") == nil,
        "more than 32 persisted Quick Keys reject the complete alias set")
    repaired.quickKeys = SearchQuickKeys()
    try repaired.validate()
    var savedGUIValues: [String] = []
    let editor = try SettingsWindow(brightness: 70, keyboard: configuration, preview: true) { id, values in
        if id == 810 { savedGUIValues = values }
        return "Read-only settings check"
    }
    guard let settingsWindow = editor.window else {
        throw WindowsError.unsupported("Search Quick Keys settings window is unavailable.")
    }
    defer { DestroyWindow(settingsWindow) }
    SendMessageW(settingsWindow, UINT(WM_COMMAND), 129, 0)
    let viewport = withWideString("SwiftyToys.SettingsViewport") {
        FindWindowExW(settingsWindow, nil, $0, nil)
    }
    guard let viewport, let field = GetDlgItem(viewport, 846) else {
        throw WindowsError.unsupported("Search Quick Keys editor is unavailable.")
    }
    _ = withWideString("calc = Calculator\r\nзвук = Sound settings") { SetWindowTextW(field, $0) }
    SendMessageW(settingsWindow, UINT(WM_COMMAND), 100, 0)
    SendMessageW(settingsWindow, UINT(WM_COMMAND), 129, 0)
    SendMessageW(settingsWindow, UINT(WM_COMMAND), 810, 0)
    try expect(savedGUIValues.count == 8, "Search settings saves the complete eight-field contract")
    let savedGUIKeys = try SearchQuickKeys(serialized: savedGUIValues[7])
    try expect(savedGUIKeys.match("calc")?.id == "action:calculator"
        && savedGUIKeys.match("ЗВУК")?.id == "action:sound",
        "native Quick Keys editor retains drafts across Overview and serializes safe commands")
    let saved = SearchPreferences(contents: "allLocalDrives=0\nfolder=C:\\First\nfolder=D:\\Second\nexclude=C:\\Excluded\nmodel=sentence-transformers/all-MiniLM-L6-v2\nmedia=1\nindexPaused=1\n")
    try expect(saved.folders == ["C:\\First", "D:\\Second"] && saved.excludedPaths == ["C:\\Excluded"]
        && saved.media && saved.indexPaused && !saved.allLocalDrives
        && saved.modelRepository == NativeSearchModelDescriptor.miniLM.repositoryID,
        "search library/model settings preserve repeated locations and opt-ins")
    for invalid in ["exclude=relative-folder\n", "exclude=C:\\..\\Outside\n", "folder=C:\\Windows\n"] {
        var rejected = false
        do { try SearchPreferences(contents: invalid).validate() } catch { rejected = true }
        try expect(rejected, "invalid library scope rejected before preferences are written")
    }
    var scoped = saved
    scoped.exclusions = "C:\\First\\Private"
    try expect(scoped.permitsLibraryPath("c:\\FIRST\\sample.swift")
        && scoped.permitsLibraryPath("D:\\Second\\recording.wav")
        && scoped.permitsLibraryPath("C:\\First\\Private-archive\\note.txt")
        && !scoped.permitsLibraryPath("C:\\First\\Private\\note.txt")
        && !scoped.permitsLibraryPath("C:\\First-other\\note.txt")
        && !scoped.permitsLibraryPath("\\\\example.invalid\\share\\note.txt"),
        "current paused scope gates stale library results without filesystem work")
    try expect(!defaults.permitsLibraryPath("C:\\Example\\.agent-private\\note.txt")
        && !SearchPreferences(contents: "enabled=0\n").permitsLibraryPath("C:\\Example\\note.txt"),
        "private and disabled library scope reject stored matches")
    try expect(!NativeSearchFiles.validFolder("\\\\example.invalid\\share"),"network scope rejected")
    try expect(!NativeSearchFiles.validFolder("C:\\Example\\..\\Outside"),"traversal scope rejected")
    try expect(!NativeSearchFiles.validFolder("C:\\Example\\.agent-private"),"private workspace excluded")
    try expect(NativeSearchFiles.decodeSnippet([97,0xF0,0x9F,0x8C]) == "a","partial UTF-8 scalar trimmed")
    try expect(NativeSearchFiles.decodeSnippet([255,254,97,0]) == "a","UTF-16LE text")
    try expect(NativeSearchFiles.decodeSnippet([254,255,0,97]) == "a","UTF-16BE text")
    try expect(NativeSearchFiles.decodeSnippet([97,0]) == nil,"binary NUL rejected")
    try expect(NativeSearchClock.quick("time in utc")?.value.count == 5,"native world clock")
    let item = SearchItem(id:"x",title:"Unicode — файл",subtitle:"tab\tnewline\n",path:"C:\\Example\\file.txt",kind:"File")
    try expect(try SearchWire.decode(SearchWire.encode([item])).items == [item],"IPC data roundtrip")
    Console.writeLine("PASS: Mac search routing, customized shortcuts, rollback-compatible actions, model opt-in, local scope, native Quick Keys editor and bounded IPC")
}
