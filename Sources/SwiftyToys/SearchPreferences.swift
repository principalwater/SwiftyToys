// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

struct SearchPreferences: Sendable {
    var enabled = true
    var semantic = false
    var folder = ""
    init(contents: String) {
        for line in contents.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "enabled": enabled = pair[1] == "1"
            case "semantic": semantic = pair[1] == "1"
            case "folder": folder = String(pair[1])
            default: break
            }
        }
    }
    init() {
        self.init(contents: (try? NativeFiles.text(NativeFiles.path("search.ini"))) ?? "enabled=1\nsemantic=0\n")
    }
    func semanticSetupMessage(folderAvailable: Bool, documentCount: Int) -> String {
        if !semantic {
            return "Optional model downloaded. Enable local semantic search and choose "
                + "a folder containing your documents."
        }
        if folder.isEmpty || !folderAvailable {
            return "Optional model downloaded. Choose an existing local folder "
                + "containing supported text documents."
        }
        if documentCount == 0 {
            return "No supported text files found. Add readable .txt or .md documents, "
                + "or choose another folder. The model loads when documents are available."
        }
        return "Optional model downloaded. Semantic search is enabled for up to 64 "
            + "supported text files; the model loads only when used."
    }
    func save() throws {
        guard folder.utf16.count < 32700, !folder.contains(where: { $0.isNewline || $0 == "\0" }),
            !semantic || (!folder.isEmpty && NativeSearchFiles.validFolder(folder)) else {
            throw WindowsError.unsupported("Choose an existing local folder for semantic search. Network shares and linked folders are excluded.")
        }
        try NativeFiles.write(Array("enabled=\(enabled ? 1 : 0)\r\nsemantic=\(semantic ? 1 : 0)\r\nfolder=\(folder)\r\n".utf8), to: NativeFiles.path("search.ini"))
    }
}
