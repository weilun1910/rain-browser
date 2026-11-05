import AppKit
import Foundation

/// `--quit-check <app|exit> --models-dir <dir>`: loads both models, starts re-embedding and
/// reranking on background threads, then quits in the middle of it, the way the app does
/// (`app` posts the will-terminate notification first) or with a bare `exit` (`exit`). The self
/// test runs this in a child process and checks it exits cleanly instead of crashing in
/// llama.cpp's Metal teardown.
enum EngineQuitCheck {
    static let marker = "quit-check: quitting mid-re-embed"

    static func run(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let mode = arg("--quit-check") ?? "exit"
        guard let m = arg("--models-dir") else { print("Usage: --quit-check <app|exit> --models-dir <dir>"); return 2 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-quit-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(dir)
        Paths.overrideRoot = dir
        ModelFiles.overrideDir = URL(fileURLWithPath: m, isDirectory: true)
        ModelFiles.clearReadyCache()
        guard ModelFiles.isReady(ModelCatalog.embedder), ModelFiles.isReady(ModelCatalog.reranker) else { print("models not found in \(m)"); return 3 }
        guard let store = try? IndexStore(url: dir.appendingPathComponent("index.sqlite")) else { return 1 }
        IndexStore.shared = store
        // Passages without vectors, so the re-embed job has a long queue.
        let words = ["browser", "webkit", "extension", "starter", "marathon", "thesis", "memory", "meeting", "notes", "graph", "model", "design"]
        var docs: [(DocUpsert, Analysis)] = []
        for i in 0..<300 {
            var text: [String] = []
            for j in 0..<4 {
                var w: [String] = []
                for k in 0..<60 { w.append(words[(i * 7 + j * 3 + k) % words.count]) }
                text.append(w.joined(separator: " "))
            }
            docs.append((DocUpsert(key: "https://quit.test/\(i)", source: .chrome, url: "https://quit.test/\(i)", title: "Page \(i)", firstSeen: 1, lastSeen: 1),
                         Analysis(passages: text, vectors: Array(repeating: nil, count: text.count), entities: [])))
        }
        _ = store.importChrome(docs)
        Reembedder.shared.kick()
        // The reranker busy on another thread at the same time.
        let docTexts = (0..<16).map { "Title: Page \($0)\n" + String(repeating: "a browser on webkit with extensions and notes. ", count: 12) }
        Thread.detachNewThread {
            while !Intelligence.shared.isShuttingDown {
                _ = Intelligence.shared.rerank(query: "browser extensions on webkit", documents: docTexts)
            }
        }
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            if (store.vectorCounts()[.gemma] ?? 0) > 0 && Intelligence.shared.hasLoadedModels { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let done = store.vectorCounts()[.gemma] ?? 0
        print("\(marker) (\(done) of \(store.passageCount()) passages re-embedded, mode \(mode))")
        fflush(stdout)
        if mode == "app" {
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        }
        try? FileManager.default.removeItem(at: dir)
        exit(0)
    }
}
