// SPDX-License-Identifier: MIT
import SearchCore
import Testing

struct SearchQuickKeysTests {
  @Test func catalogPreservesBuiltInCommands() {
    #expect(SearchCommands.items.count == 9)
    #expect(Set(SearchCommands.items.map(\.id)).count == 9)
    #expect(SearchCommands.items.map(\.id) == ["action:settings", "action:windows-settings",
      "action:calculator", "action:explorer", "action:lock", "action:sleep", "action:bluetooth",
      "action:sound", "action:display"])
    #expect(SearchCommands.items.allSatisfy { $0.path.isEmpty && $0.kind == "Action" })
    #expect(SearchCommands.items.first { $0.id == "action:sleep" }?.title == "Sleep")
  }

  @Test func emptyDefaultsAndExactMatching() throws {
    #expect(SearchQuickKeys().match("Calculator") == nil)
    let keys = try SearchQuickKeys(editorText: "calc = Calculator\nbt = Bluetooth settings")
    #expect(keys.match(" CALC ")?.id == "action:calculator")
    #expect(keys.match("bt")?.id == "action:bluetooth")
    #expect(keys.match("cal") == nil)
    #expect(keys.match("calc files") == nil)
    #expect(keys.match("app:calc") == nil)
    #expect(keys.match("calc\0") == nil)
    #expect(keys.match(String(repeating: "c", count: 129)) == nil)
  }

  @Test func internationalAliasesAndStableRoundTrip() throws {
    let keys = try SearchQuickKeys(editorText:
      "睡眠 = Sleep\nзвук = Sound settings\ncafé = Calculator\nwin_settings = Windows Settings")
    #expect(keys.match("ЗВУК")?.id == "action:sound")
    #expect(keys.match("CAFE\u{301}")?.id == "action:calculator")
    #expect(keys.match("睡眠")?.id == "action:sleep")
    #expect(try SearchQuickKeys(serialized: keys.serialized) == keys)
    #expect(try SearchQuickKeys(editorText: keys.editorText) == keys)
    #expect(!keys.editorText.contains("action:"))
  }

  @Test func everyAliasSelectsAnExistingItemWithoutExecutingIt() throws {
    let source = SearchCommands.items.enumerated().map { "key\($0.offset) = \($0.element.title)" }
      .joined(separator: "\n")
    let keys = try SearchQuickKeys(editorText: source)
    for (index, item) in SearchCommands.items.enumerated() {
      #expect(keys.match("key\(index)") == item)
    }
  }

  @Test func rejectsMalformedOrExecutableDestinations() {
    for text in ["calc", "=Calculator", "calc=", "calc=Calculator=Sleep", "cal c=Calculator",
      "calc: = Calculator", "calc\0=Calculator", "calc=action:calculator", "calc=https://example.invalid",
      "calc=cmd.exe", "calc=Calculator\nCALC=Sleep", "café=Calculator\ncafe\u{301}=Sleep",
      "12345678901234567=Calculator", String(repeating: " ", count: 8_193)] {
      #expect(throws: SearchQuickKeysError.self) { try SearchQuickKeys(editorText: text) }
    }
    for text in ["calc|action:arbitrary", "calc|cmd.exe", "calc|action:calculator|action:sleep",
      "calc|action:calculator\nCALC|action:sleep", "calc|action:calculator\0"] {
      #expect(throws: SearchQuickKeysError.self) { try SearchQuickKeys(serialized: text) }
    }
  }

  @Test func boundedAliasCount() throws {
    let source = (0..<32).map { "key\($0) = Calculator" }.joined(separator: "\n")
    #expect(try SearchQuickKeys(editorText: source).match("key31")?.id == "action:calculator")
    #expect(throws: SearchQuickKeysError.self) {
      try SearchQuickKeys(editorText: source + "\nkey32 = Calculator")
    }
  }
}
