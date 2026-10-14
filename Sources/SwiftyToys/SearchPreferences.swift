// SPDX-License-Identifier: MIT
import BrightnessCore
import SearchCore
import WinSDK

struct SearchPreferences: Sendable {
    var enabled = true
    var semantic = false
    var folder = ""
    var allLocalDrives = true
    var exclusions = ""
    var modelRepository = "onnx-community/embeddinggemma-2-ONNX"
    var media = false
    var indexPaused = false
    var quickKeys = SearchQuickKeys() { didSet { quickKeysError = nil } }
    private var quickKeysError: SearchQuickKeysError?
    init(contents: String) {
        var quickKeyLines: [String] = []
        var quickKeyBytes = 0
        for line in contents.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "enabled": enabled = pair[1] == "1"
            case "semantic": semantic = pair[1] == "1"
            case "folder": folder += (folder.isEmpty ? "" : "\n") + String(pair[1])
            case "allLocalDrives": allLocalDrives = pair[1] == "1"
            case "exclude": exclusions += (exclusions.isEmpty ? "" : "\n") + String(pair[1])
            case "model": modelRepository = String(pair[1])
            case "media": media = pair[1] == "1"
            case "indexPaused": indexPaused = pair[1] == "1"
            case "quickKey":
                quickKeyBytes += pair[1].utf8.count + 1
                if quickKeyBytes <= 8_192 && quickKeyLines.count < 32 {
                    quickKeyLines.append(String(pair[1]))
                } else { quickKeysError = .limit }
            default: break
            }
        }
        if quickKeysError == nil {
            do { quickKeys = try SearchQuickKeys(serialized: quickKeyLines.joined(separator: "\n")) }
            catch let error as SearchQuickKeysError { quickKeysError = error }
            catch { quickKeysError = .syntax }
        }
    }
    init() {
        self.init(contents: (try? NativeFiles.text(NativeFiles.path("search.ini"))) ?? "enabled=1\nsemantic=0\n")
    }
    var folders: [String] { folder.split(whereSeparator: \.isNewline).map(String.init) }
    var excludedPaths: [String] { exclusions.split(whereSeparator: \.isNewline).map(String.init) }
    func permitsLibraryPath(_ path: String) -> Bool {
        let roots = folders, exclusions = excludedPaths
        let normalizedExclusions = exclusions.compactMap(NativeSearchLibraryScanner.canonical)
        guard enabled, roots.count <= 32, exclusions.count <= 64,
            normalizedExclusions.count == exclusions.count,
            let value = NativeSearchLibraryScanner.canonical(path),
            NativeSearchLibraryScanner.permitted(value, excludedPaths: normalizedExclusions) else { return false }
        return allLocalDrives || roots.compactMap(NativeSearchLibraryScanner.canonical).contains {
            value == $0 || value.hasPrefix($0.hasSuffix("\\") ? $0 : $0 + "\\")
        }
    }
    func semanticSetupMessage(folderAvailable: Bool, documentCount: Int) -> String {
        if !semantic {
            return "Optional model downloaded. Enable local semantic search and choose "
                + "a folder containing your documents."
        }
        if allLocalDrives {
            return "The selected model is downloaded. Local drives are indexed incrementally; "
                + "semantic results use the persistent library. Open Index status for progress."
        }
        if folder.isEmpty || !folderAvailable {
            return "Optional model downloaded. Choose an existing local folder "
                + "containing supported text documents."
        }
        if documentCount == 0 {
            return "No supported text files found. Add readable .txt or .md documents, "
                + "or choose another folder. The model loads when documents are available."
        }
        return "The selected model is downloaded. Your folders are indexed incrementally. "
            + "Semantic results use the persistent library."
    }
    func validate() throws {
        if let quickKeysError { throw WindowsError.unsupported(quickKeysError.description) }
        guard folders.count <= 32, excludedPaths.count <= 64,
            folder.utf8.count + exclusions.utf8.count <= 24_000,
            !folder.contains("\0"), !exclusions.contains("\0"),
            folders.allSatisfy({ path in
                guard NativeSearchLibraryScanner.canonical(path) != nil,
                    NativeSearchLibraryScanner.permitted(path), NativeSearchFiles.validFolder(path) else { return false }
                let kind = withWideString(String(path.prefix(3))) { GetDriveTypeW($0) }
                return kind == UINT(DRIVE_FIXED) || kind == UINT(DRIVE_REMOVABLE)
            }),
            excludedPaths.allSatisfy({ NativeSearchLibraryScanner.canonical($0) != nil }),
            !enabled || allLocalDrives || !folders.isEmpty,
            NativeSearchModelCatalog.validRepositoryID(modelRepository) else {
            throw WindowsError.unsupported("Select local drives or existing local folders outside system/private locations. Use full paths such as C:\\Folder, one folder or exclusion per line, and a model ID in owner/model form.")
        }
    }
    var serialized: String {
        var contents = "enabled=\(enabled ? 1 : 0)\r\nsemantic=\(semantic ? 1 : 0)\r\n"
            + "allLocalDrives=\(allLocalDrives ? 1 : 0)\r\nmodel=\(modelRepository)\r\n"
            + "media=\(media ? 1 : 0)\r\nindexPaused=\(indexPaused ? 1 : 0)\r\n"
        for path in folders { contents += "folder=\(path)\r\n" }
        for path in excludedPaths { contents += "exclude=\(path)\r\n" }
        for line in quickKeys.serialized.split(whereSeparator: \.isNewline) {
            contents += "quickKey=\(line)\r\n"
        }
        return contents
    }
    func save() throws {
        try validate()
        let contents = serialized
        try NativeFiles.write(Array(contents.utf8), to: NativeFiles.path("search.ini"))
    }
}
