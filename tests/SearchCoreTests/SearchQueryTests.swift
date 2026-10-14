// SPDX-License-Identifier: MIT
import Testing
@testable import SearchCore

struct SearchQueryTests {
  @Test func scopesAndFiltersHaveOneSharedGrammar() {
    let parsed = SearchQuery(" Files: kind:PHOTO ext:JPG holiday ")
    #expect(parsed.isValid && parsed.category == .files)
    #expect(parsed.contentKind == "image" && parsed.fileExtension == "jpg")
    #expect(parsed.text == "holiday" && parsed.indexedQuery == "holiday")
    #expect(parsed.libraryQuery == "files: kind:image ext:jpg holiday")
    #expect(SearchQuery(parsed.libraryQuery).libraryQuery == parsed.libraryQuery)
    #expect(SearchQuery("apps: calculator").category == .applications)
    #expect(SearchQuery("actions: lock").category == .actions)
    #expect(SearchQuery("PDF: invoice").contentKind == "pdf")
    #expect(SearchQuery("files:").libraryQuery == "files:")
    #expect(SearchCategory.allCases.map(\.prefix) == ["", "apps:", "files:", "actions:"])
  }

  @Test func pathsAndUnknownPrefixesStayLiteral() {
    for raw in ["C:\\Example\\report.pdf", "unknown: invoice", "https://example.invalid",
      "invoice ext:pdf", "kind of report"] {
      let query = SearchQuery(raw)
      #expect(query.isValid && query.category == .all && query.text == raw)
      #expect(query.contentKind == nil && query.fileExtension == nil)
    }
  }

  @Test func recognizedInvalidFiltersFailClosed() {
    for raw in ["kind:unknown notes", "ext: notes", "ext:pdf' OR 1=1", "ext:../pdf notes",
      "ext:🥹", "ext:" + String(repeating: "a", count: 17), "ext:pdf ext:txt report",
      "kind:pdf kind:video report", "apps: ext:exe calc", "actions: pdf: report",
      "files: apps: calc", "files:\0report", String(repeating: "a", count: 4097)] {
      #expect(!SearchQuery(raw).isValid)
    }
    #expect(SearchQuery(String(repeating: "a", count: 4096)).isValid)
    #expect(SearchQuery("ext:7z archive").isValid)
  }

  @Test func everyProviderCanFilterBeforeRanking() {
    let pdf = item("C:\\Example\\report.PDF", kind: "File")
    let jpg = item("C:\\Example\\photo.jpg", kind: "File")
    let app = item("C:\\Example\\report.pdf", kind: "Application")
    let folder = item("C:\\Example\\report.pdf", kind: "Folder")
    let action = item("", kind: "Action")
    let website = item("https://example.invalid/report.pdf", kind: "Website")
    #expect(SearchQuery("files:").accepts(pdf))
    #expect(SearchQuery("files:").accepts(folder))
    #expect(!SearchQuery("files:").accepts(app))
    #expect(!SearchQuery("files:").accepts(website))
    #expect(SearchQuery("pdf:").accepts(pdf))
    #expect(!SearchQuery("pdf:").accepts(jpg))
    #expect(!SearchQuery("pdf:").accepts(folder))
    #expect(!SearchQuery("ext:pdf").accepts(folder))
    #expect(SearchQuery("files: kind:document ext:PDF").accepts(pdf))
    #expect(SearchQuery("image:").accepts(jpg))
    #expect(SearchQuery("apps:").accepts(app))
    #expect(!SearchQuery("apps:").accepts(action))
    #expect(SearchQuery("actions:").accepts(action))
    #expect(!SearchQuery("ext:???").accepts(pdf))
    #expect(!SearchQuery("ext:pdf").accepts(item("C:\\Example\\.pdf", kind: "File")))
  }

  private func item(_ path: String, kind: String) -> SearchItem {
    SearchItem(id: path, title: "fixture", subtitle: "", path: path, kind: kind)
  }
}
