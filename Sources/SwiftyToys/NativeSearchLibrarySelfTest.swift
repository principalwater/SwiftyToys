// SPDX-License-Identifier: MIT
import BrightnessCore
import WinSDK

extension NativeSearchLibraryStore {
    static func selfCheck() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw WindowsError.unsupported("Library fixture failed: " + message) }
        }
        let parent = try NativeSearchFiles.knownFolder(FOLDERID_Profile)
        let directory = parent + "\\SwiftyToys-Library-Fixture-\(GetCurrentProcessId())-\(GetTickCount64())"
        let corpus = directory + "\\corpus"
        let databasePath = directory + "\\library.sqlite3"
        let budgetDatabase = directory + "\\budget.sqlite3"
        let fileKindDatabase = directory + "\\file-kind.sqlite3"
        try NativeFiles.createDirectory(directory)
        try NativeFiles.createDirectory(corpus)
        var paths: [String] = []
        defer {
            for path in paths { try? NativeFiles.remove(path) }
            for suffix in ["", "-journal", "-wal", "-shm"] { try? NativeFiles.remove(databasePath + suffix) }
            for suffix in ["", "-journal", "-wal", "-shm"] { try? NativeFiles.remove(budgetDatabase + suffix) }
            for suffix in ["", "-journal", "-wal", "-shm"] { try? NativeFiles.remove(fileKindDatabase + suffix) }
            _ = withWideString(corpus + "\\.git") { RemoveDirectoryW($0) }
            _ = withWideString(corpus + "\\git") { RemoveDirectoryW($0) }
            _ = withWideString(corpus) { RemoveDirectoryW($0) }
            _ = withWideString(directory) { RemoveDirectoryW($0) }
        }
        for index in 0..<80 {
            let path = corpus + "\\note\(index)" + (index == 0 ? ".swift" : ".txt")
            try NativeFiles.write(Array("fixture text \(index)".utf8), to: path)
            paths.append(path)
        }
        try NativeFiles.createDirectory(corpus + "\\git")
        try NativeFiles.createDirectory(corpus + "\\.git")
        for path in [corpus + "\\git\\source.swift", corpus + "\\.git\\config",
            corpus + "\\AGENTS.md", corpus + "\\secret.pem"] {
            try NativeFiles.write(Array("fixture".utf8), to: path)
            paths.append(path)
        }
        try expect(NativeSearchLibraryScanner.permitted("C:\\Example\\git\\Repo\\source.swift"),
            "repository container accepted")
        try expect(parsedQuery("CODE: sample ").kind == "code" &&
            parsedQuery("CODE: sample ").text == "sample" &&
            parsedQuery("C:\\Example\\note.txt").kind == nil &&
            parsedQuery("unknown: sample").text == "unknown: sample", "shared type prefix parser")
        for path in ["\\\\server\\share", "C:\\Example\\..\\Other", "C:\\Example\\.git\\config",
            "C:\\Example\\.ssh\\key", "C:\\Example\\AGENTS.md", "C:\\Example\\secret.pem"] {
            try expect(!NativeSearchLibraryScanner.permitted(path), "excluded scope rejected")
        }
        for (path, canonical) in [
            ("C:\\", "c:\\"), ("C:\\Example\\\\", "c:\\example"),
            ("C:\\Example\\Résumé\\文書.swift", "c:\\example\\résumé\\文書.swift"),
            ("C:\\Example\\\u{301}Résumé.swift", "c:\\example\\\u{301}résumé.swift"),
            ("C:\\\u{301}Example\\e\u{301}.swift", "c:\\\u{301}example\\e\u{301}.swift"),
        ] {
            try expect(NativeSearchLibraryScanner.canonical(path) == canonical &&
                NativeSearchLibraryScanner.permitted(path), "Unicode and root canonicalization")
        }
        for path in ["C:\\Example\\x*\u{301}.swift", "C:\\Example\\x?\u{301}.swift",
            "C:\\Example\\x:\u{301}stream", "C:\\Example/\u{301}file.swift",
            "C:\\Example\\\0\u{301}file.swift", "C:\\Example\\folder.\\file.swift",
            "C:\\Example\\folder \\file.swift"] {
            try expect(NativeSearchLibraryScanner.canonical(path) == nil &&
                !NativeSearchLibraryScanner.permitted(path), "ASCII path protections near combining marks")
        }
        let longest = "C:\\" + String(repeating: "文", count: 32756)
        try expect(longest.utf16.count == 32759 &&
            NativeSearchLibraryScanner.canonical(longest) != nil &&
            NativeSearchLibraryScanner.canonical(longest + "文") == nil,
            "UTF-16 native path limit retained")
        let excluded = ["c:\\example\\résumé"]
        try expect(!NativeSearchLibraryScanner.permitted("C:\\Example\\Résumé\\文書.swift",
            excludedPaths: excluded) && NativeSearchLibraryScanner.permitted(
                "C:\\Example\\RésuméElsewhere\\文書.swift", excludedPaths: excluded) &&
            !NativeSearchLibraryScanner.permitted("C:\\Example\\文書\\.SSH\\secret") &&
            !NativeSearchLibraryScanner.permitted("C:\\Example\\\u{301}name\\.git\\config"),
            "nested and explicit scope exclusions retained")
        func finish(_ scanner: NativeSearchLibraryScanner) throws {
            for _ in 0..<1000 {
                if scanner.finished { return }
                _ = try scanner.scanSlice(maximumEntries: 16, milliseconds: 100, cancelled: { false })
            }
            throw WindowsError.unsupported("Library fixture traversal failed to finish.")
        }
        var firstID: Int64 = 0
        do {
            let store = try NativeSearchLibraryStore(databasePath: databasePath)
            let sourcePath = corpus + "\\note0.swift"
            let sourceMetadata = try NativeSearchLibraryScanner.metadata(path: sourcePath)
            try store.observe(path: sourcePath, parent: corpus, size: sourceMetadata.size,
                modified: sourceMetadata.modified, generation: "fixture")
            let scanner = try NativeSearchLibraryScanner(store: store, roots: [corpus])
            _ = try scanner.scanSlice(maximumEntries: 16, milliseconds: 100, cancelled: { false })
            let status = try store.status()
            try expect(status.files > 0 && status.files < 81 && status.directories > 0,
                "partial directory progress committed before restart")
        }
        do {
            let store = try NativeSearchLibraryStore(databasePath: databasePath)
            try store.configure(namespace: "fixture-model-adapter-context-v1", dimensions: 4)
            let scanner = try NativeSearchLibraryScanner(store: store, roots: [corpus], resume: true)
            try expect(try scanner.scanSlice(cancelled: { true }) == 0, "cancelled slice does no work")
            try expect(try store.status().files < 81, "cancellation retains partial state")
            try finish(scanner)
            try expect(try store.status().files == 81, "more than 64 files and repository code indexed")
            guard let file = try store.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture has no pending file.")
            }
            firstID = file.id
            try store.appendFragments(file: file, fragments: [NativeSearchLibraryFragment(
                text: "invoice INV-123 searchable fixture\nnext fixture line", kind: "code", location: "Line 1 · text")],
                continuation: 1000)
            guard let pending = try store.pendingFragments(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture has no pending fragment.")
            }
            try store.commitVector(fragmentID: pending.id, namespace: "fixture-model-adapter-context-v1",
                vector: [1, 0, 0, 0])
            try expect(try store.status().vectors == 1, "vector committed")
            try store.setPaused(true)
            try expect(try scanner.scanSlice(cancelled: { false }) == 0, "pause avoids traversal")
        }
        do {
            let reader = try NativeSearchLibraryStore(databasePath: databasePath, readOnly: true)
            try expect(try reader.status().vectors == 1, "read-only process sees persistent vectors")
        }
        do {
            let store = try NativeSearchLibraryStore(databasePath: databasePath)
            try expect(try store.status().vectors == 1 && store.paused, "restart retains vectors and pause")
            try store.setPaused(false)
            let scanner = try NativeSearchLibraryScanner(store: store, roots: [corpus])
            try finish(scanner)
            try expect(try store.status().vectors == 1, "unchanged file does not erase vector")
            let watcher = try NativeSearchLibraryWatcher(roots: [corpus])
            try expect(watcher.unavailableRoots == 0, "native fixture watcher opened")
            let watchedPath = corpus + "\\watch-fixture.txt"
            paths.append(watchedPath)
            func applyChanges() throws {
                let deadline = GetTickCount64() + 2000
                while GetTickCount64() < deadline {
                    let directories = watcher.pollChangedDirectories()
                    if !directories.isEmpty {
                        for directory in directories { try scanner.enqueueDirectory(directory) }
                        try finish(scanner)
                        return
                    }
                    Sleep(20)
                }
                throw WindowsError.unsupported("Native fixture change notification timed out.")
            }
            try NativeFiles.write(Array("native watcher fixture".utf8), to: watchedPath)
            try applyChanges()
            try expect(try store.status().files == 82, "native change event queues new file parent")
            try NativeFiles.remove(watchedPath)
            try applyChanges()
            try expect(try store.status().files == 81, "native removal event prunes file")
            try expect(watcher.stop() && watcher.finishStopped() && watcher.stop(),
                "cancelled native watcher drains I/O and retirement is idempotent")
            let resumed = try NativeSearchLibraryScanner(store: store, roots: [corpus], resume: true)
            try expect(resumed.finished && store.status().directories == 0,
                "normal worker restart does not queue a full completed-root scan")
            guard let file = try store.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture lost its extraction continuation.")
            }
            try expect(file.id == firstID && file.continuation == 1000, "extraction cursor survives restart")
            try expect(file.matchesCurrent(), "metadata fingerprint matches native file")
            try store.appendFragments(file: file, fragments: [NativeSearchLibraryFragment(
                text: "continuation content", kind: "code", location: "lines 6–10")], continuation: nil)
            try store.setFileStatus(file: file, status: "finished", partial: true)
            guard let waiting = try store.pendingFragments(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture missing pending vector.")
            }
            try store.skipVector(fragmentID: waiting.id, reason: "fixture unavailable modality")
            try expect(try store.pendingFragments().isEmpty && store.status().skippedVectors == 1 &&
                store.status().partialFiles == 1, "skipped vectors leave queue and partial coverage persists")
            try store.setFileStatus(file: file, status: "pending", partial: true)
            guard let refreshedFile = try store.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture missing refreshed file cursor.")
            }
            try store.appendFragments(file: refreshedFile, fragments: [NativeSearchLibraryFragment(
                text: "", kind: "pdf", location: "Page 2 · media")], continuation: nil)
            guard let pendingMedia = try store.pendingFragments(fileID: file.id).first else {
                throw WindowsError.unsupported("Library fixture missing visual media vector.")
            }
            try store.waitForMedia(fragmentID: pendingMedia.id)
            try expect(try store.pendingFragments(fileID: file.id).isEmpty &&
                store.status().pendingVectors == 1, "waiting media stays counted without processing retries")
            try store.retryWaitingMedia()
            try expect(try store.pendingFragments(fileID: file.id).count == 1 &&
                store.status().fragments == 3 && store.status().skippedVectors == 1,
                "media availability retries only waiting vector and preserves extracted text")
            guard let mediaWaiting = try store.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("Library fixture missing media retry file.")
            }
            try store.appendFragments(file: mediaWaiting, fragments: [NativeSearchLibraryFragment(
                text: "", kind: "pdf", location: "page 1")], continuation: nil)
            try store.setFileStatus(file: mediaWaiting, status: "waiting-media", partial: true)
            try expect(try store.pendingFragments(fileID: mediaWaiting.id).count == 1,
                "empty visual PDF locator persists")
            try store.retryWaitingMedia()
            try expect(try store.pendingFragments(fileID: mediaWaiting.id).isEmpty &&
                store.status().failedFiles == 0, "media availability requeues without changing namespace")
            try expect(try store.searchText("code: INV-123", cancelled: { false }).count == 1,
                "exact content and source-file type filter")
            try expect(try store.searchText("pdf: INV-123", cancelled: { false }).isEmpty,
                "file type excludes incompatible files")
            try expect(try store.searchVector([1, 0, 0, 0], namespace: "fixture-model-adapter-context-v1",
                cancelled: { false }).count == 1, "persisted vector retrieval")
            let extensionFilter = NativeSearchContent.fileExtension(file.path)
            try expect(try store.searchText("files: ext:" + extensionFilter + " INV-123",
                cancelled: { false }).count == 1 && store.searchText("ext:pdf INV-123",
                cancelled: { false }).isEmpty, "extension filters content before result limits")
            try expect(try store.searchText("files: ext:swift", cancelled: { false }).count == 2 &&
                store.searchText("files: ext:txt", cancelled: { false }).count == 32,
                "bounded extension browsing includes metadata without extracted fragments")
            try expect(try store.searchText("kind:unknown INV-123", cancelled: { false }).isEmpty,
                "invalid recognized filter cannot broaden library search")
            try expect(try store.searchVector([1, 0, 0, 0], namespace: "fixture-model-adapter-context-v1",
                fileExtension: extensionFilter, cancelled: { false }).count == 1 &&
                store.searchVector([1, 0, 0, 0], namespace: "fixture-model-adapter-context-v1",
                fileExtension: "pdf", cancelled: { false }).isEmpty,
                "extension filters vectors before result limits")
            try store.configure(namespace: "fixture-model-adapter-context-v2", dimensions: 4)
            try expect(try store.status().vectors == 0 && store.status().fragments == 3,
                "model invalidation retains extracted text")
            try expect(try store.status().skippedVectors == 0 && store.pendingFragments().count == 3,
                "model revision requeues skipped vectors")
            guard let longText = try store.pendingFragments(fileID: file.id).first else {
                throw WindowsError.unsupported("Library fixture missing text-window source.")
            }
            try store.deferBudgetVector(fragmentID: longText.id, requiredFragments: 3)
            try expect(try store.status().pendingVectors == 3 &&
                !store.pendingFragments(limit: 256).contains { $0.id == longText.id },
                "capacity-blocked semantic windows do not starve other pending vectors")
            try store.retryWaitingBudget()
            try expect(try store.pendingFragments(limit: 256).contains { $0.id == longText.id },
                "semantic windows resume when enough capacity is available")
            try expect(try store.splitPendingFragment(fragmentID: longText.id,
                texts: ["invoice INV-", "123 searchable fixture\n", "next fixture line"]), "semantic windows created atomically")
            try expect(try store.status().fragments == 6 && store.status().pendingVectors == 5 &&
                store.searchText("INV-123", cancelled: { false }).count == 1,
                "exact identifiers across windows remain searchable in original text")
            let windows = try store.pendingFragments(limit: 256, fileID: file.id)
            try expect(windows.contains { $0.fragment.text == "next fixture line" &&
                $0.fragment.location == "Line 2 · text" }, "semantic windows retain accurate source lines")
            try store.configure(namespace: "fixture-model-adapter-context-v3", dimensions: 4)
            try expect(try store.status().fragments == 3 && store.pendingFragments().count == 3,
                "new tokenizer drops derived windows and preserves original extracted text")
            try NativeFiles.remove(file.path)
            try scanner.beginRefresh(roots: [corpus])
            try finish(scanner)
            try expect(try store.status().files == 80 && store.status().fragments == 0,
                "completed directory prunes removed file and fragments")
            try NativeFiles.remove(corpus + "\\git\\source.swift")
            guard withWideString(corpus + "\\git", { RemoveDirectoryW($0) }) else {
                throw WindowsError.api("Remove fixture subdirectory", GetLastError())
            }
            try scanner.beginRefresh(roots: [corpus])
            try finish(scanner)
            try expect(try store.status().files == 79, "completed parent prunes vanished subtree")
            try store.reset()
            try expect(try store.status().files == 0, "reset clears the index")
            try store.configure(namespace: "fixture-performance-v1", dimensions: 128)
            let prepared = GetTickCount64()
            try store.transaction {
                for index in 0..<10_000 {
                    try store.observe(path: corpus + "\\synthetic\(index).swift", parent: corpus,
                        size: 100, modified: "fixture", generation: "fixture")
                }
                while let first = try store.pendingFiles(limit: 32).first {
                    let batch = try store.pendingFiles(limit: 32)
                    guard first.id == batch.first?.id else {
                        throw WindowsError.unsupported("Library benchmark pending cursor changed.")
                    }
                    for file in batch {
                        try store.replaceFragments(file: file, fragments: [NativeSearchLibraryFragment(
                            text: "Synthetic searchable benchmark token with no real user text.",
                            kind: "code", location: "fixture")])
                    }
                    for fragment in try store.pendingFragments(limit: 32) {
                        try store.commitVector(fragmentID: fragment.id, namespace: "fixture-performance-v1",
                            vector: [Float](repeating: 1, count: 128))
                    }
                }
            }
            let preparationMilliseconds = GetTickCount64() - prepared
            let lexicalStart = GetTickCount64()
            var lexicalLimited = false
            let lexical = try store.searchText("code: searchable benchmark", milliseconds: 2000,
                progress: { _, limited in lexicalLimited = limited }, cancelled: { false })
            let lexicalMilliseconds = GetTickCount64() - lexicalStart
            let vectorStart = GetTickCount64()
            var vectorLimited = false
            let semantic = try store.searchVector([Float](repeating: 1, count: 128),
                namespace: "fixture-performance-v1", milliseconds: 2000,
                progress: { _, limited in vectorLimited = limited }, cancelled: { false })
            let vectorMilliseconds = GetTickCount64() - vectorStart
            try expect(try store.status().vectors == 10_000 && lexical.count == 32 && semantic.count == 32,
                "10,000-row persisted-vector fixture bounds")
            var queryCancelled = false
            do {
                _ = try store.searchText("benchmark", cancelled: { true })
            } catch let error as WindowsError {
                queryCancelled = error.description.containsText("cancelled")
            }
            try expect(queryCancelled, "query cancellation surfaced")
            var limited = false
            _ = try store.searchVector([Float](repeating: 1, count: 128),
                namespace: "fixture-performance-v1", milliseconds: 1,
                progress: { _, partial in
                    limited = partial
                    if partial { Sleep(20) }
                }, cancelled: { false })
            try expect(limited, "elapsed query budget reports partial coverage")
            Console.writeLine("Library synthetic 10,000-row/128-dimensional fixture: prepare=\(preparationMilliseconds)ms, text=\(lexicalMilliseconds)ms (partial=\(lexicalLimited)), vector=\(vectorMilliseconds)ms (partial=\(vectorLimited)), FTS5=\(try store.status().fullTextAvailable). Synthetic data, no inference or hardware performance guarantee.")
        }
        do {
            let watcher = try NativeSearchLibraryWatcher(roots: [corpus])
            defer { _ = watcher.stop() }
            do {
                let store = try NativeSearchLibraryStore(databasePath: databasePath)
                try store.reset()
                try store.setPaused(false)
                try finish(NativeSearchLibraryScanner(store: store, roots: [corpus]))
            }
            let gapFile = corpus + "\\worker-gap-fixture.txt"
            paths.append(gapFile)
            // Metadata watching survives while the indexing connection/child is absent.
            try NativeFiles.write(Array("fixture saved between index workers".utf8), to: gapFile)
            do {
                let store = try NativeSearchLibraryStore(databasePath: databasePath)
                let scanner = try NativeSearchLibraryScanner(store: store, roots: [corpus], resume: true)
                try expect(scanner.finished, "replacement worker resumes without scanning all roots")
                let deadline = GetTickCount64() + 2000
                var changed: [String] = []
                while changed.isEmpty && GetTickCount64() < deadline {
                    changed = watcher.pollChangedDirectories()
                    if changed.isEmpty { Sleep(20) }
                }
                try expect(!changed.isEmpty, "surviving watcher records a change between index workers")
                for directory in changed { try scanner.enqueueDirectory(directory) }
                try finish(scanner)
                try expect(try store.status().files == 80,
                    "replacement worker indexes the gap file through one queued parent")
            }
            try expect(watcher.stop() && watcher.finishStopped(), "surviving watcher drains at shutdown")
        }
        try checkStorageBudgetRecovery(databasePath: budgetDatabase)
        try checkFileKindFiltering(databasePath: fileKindDatabase)
        Console.writeLine("PASS: native persistent library, 81-file traversal, exclusions, cancellation, pause, unchanged skip, restart cursor, exact/type/vector retrieval, model invalidation and pruning")
    }

    private static func checkFileKindFiltering(databasePath: String) throws {
        let store = try NativeSearchLibraryStore(databasePath: databasePath)
        let namespace = "fixture-file-kinds-v1"
        try store.configure(namespace: namespace, dimensions: 2)
        let video = databasePath + "-aaa-video.mp4"
        let audio = databasePath + "-zzz-audio.mp3"
        let pdf = databasePath + "-document.pdf"
        for (path, kind) in [(video, "audio"), (audio, "audio"), (pdf, "image")] {
            try store.observe(path: path, parent: "fixture", size: 10,
                modified: "fixture", generation: "fixture")
            guard let file = try store.pendingFiles(limit: 1).first else {
                throw WindowsError.unsupported("File-kind fixture has no pending file.")
            }
            try store.replaceFragments(file: file, fragments: [.init(
                text: "seaside fixture", kind: kind, location: "fixture")])
        }
        for fragment in try store.pendingFragments(limit: 32) {
            try store.commitVector(fragmentID: fragment.id, namespace: namespace,
                vector: fragment.file.path == audio ? [0.9, 0.1] : [1, 0])
        }
        guard try store.searchText("audio: seaside", limit: 1,
            cancelled: { false }).first?.path == audio,
            try store.searchText("video: seaside", limit: 1,
                cancelled: { false }).first?.path == video,
            try store.searchVector([1, 0], namespace: namespace, limit: 1, kind: "audio",
                cancelled: { false }).first?.path == audio,
            try store.searchVector([1, 0], namespace: namespace, limit: 1, kind: "video",
                cancelled: { false }).first?.path == video,
            try store.searchVector([1, 0], namespace: namespace, limit: 1, kind: "document",
                cancelled: { false }).first?.path == pdf else {
            throw WindowsError.unsupported("File-kind filtering must precede limits and retain matching-file modalities.")
        }
    }
}
