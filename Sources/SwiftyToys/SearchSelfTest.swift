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
    Console.writeLine("PASS: Mac search routing, customized shortcuts, rollback-compatible actions, model opt-in, local scope and bounded IPC")
}
