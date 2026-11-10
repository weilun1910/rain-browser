import AppKit
import Foundation
import NaturalLanguage

/// Which model made a vector. Vectors from different models never get compared.
enum EmbedderID: String, CaseIterable, Sendable {
    /// EmbeddingGemma 2 through llama.cpp, 768 dimensions.
    case gemma = "gemma2"
    /// Apple's NLContextualEmbedding, mean-pooled, 512 dimensions. No download.
    case contextual = "nlctx"
    /// Apple's older NLEmbedding sentence vectors, 512 dimensions. What round 2 used.
    case sentence = "nlsent"

    var label: String {
        switch self {
        case .gemma: return "EmbeddingGemma 2 (on device)"
        case .contextual: return "Apple contextual embedding (built in)"
        case .sentence: return "Apple sentence embedding (built in)"
        }
    }
}

/// The on-device models behind resurfacing: an embedder for passages and queries and a
/// cross-encoder for reranking. Loads the downloaded models lazily on a background queue and
/// frees them after a few idle minutes. Falls back to Apple's built-in embedding while the
/// models download or if they fail. Thread-safe.
final class Intelligence: @unchecked Sendable {
    static let shared = Intelligence()

    private let lock = NSLock()
    private let loadQueue = DispatchQueue(label: "local.browserpoc.models", qos: .utility)
    private var gemma: LlamaModel?
    private var reranker: LlamaModel?
    private var gemmaFailed = false
    private var rerankerFailed = false
    private var lastUse = Date()
    private var idleTimer: DispatchSourceTimer?

    /// Tests and the eval pin a backend. Nil means the best one that's ready.
    var forcedEmbedder: EmbedderID?
    /// Tests turn the reranker off to check the fallback path.
    var rerankerDisabled = false

    /// Jobs using a model right now. Shutdown waits for them before freeing anything.
    private let useCondition = NSCondition()
    private var inFlight = 0
    private var stopping = false
    private var quitObserver: NSObjectProtocol?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: loadQueue)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.unloadIfIdle() }
        t.resume()
        idleTimer = t
        // The app is quitting: stop background work and free the models while everything else
        // is still alive, waiting briefly for a job in the middle of a batch.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Reembedder.shared.enabled = false
            if !Intelligence.shared.shutdown(timeout: 3) {
                // A job is still inside llama.cpp. A handler registered now runs before any of
                // llama.cpp's teardown, including tables it set up after the models loaded.
                atexit { Intelligence.lastChanceAtExit() }
            }
        }
    }

    /// Checked between texts and between batches, so a job ends moments after shutdown begins
    /// instead of running out a long batch while the app quits around it.
    private func stopRequested() -> Bool { isShuttingDown }

    /// True once shutdown has begun. Model calls return nil from then on.
    var isShuttingDown: Bool {
        useCondition.lock(); defer { useCondition.unlock() }
        return stopping
    }

    /// Runs `body` as a job that holds the models, or returns nil when shutting down.
    private func using<T>(_ body: () -> T?) -> T? {
        useCondition.lock()
        if stopping { useCondition.unlock(); return nil }
        inFlight += 1
        useCondition.unlock()
        defer {
            useCondition.lock()
            inFlight -= 1
            useCondition.broadcast()
            useCondition.unlock()
        }
        return body()
    }

    // MARK: Loading

    /// Called when a download finishes or a file is removed.
    func modelsChanged() {
        lock.lock()
        gemmaFailed = false
        rerankerFailed = false
        if !ModelFiles.isReadyCached(ModelCatalog.embedder) { gemma = nil }
        if !ModelFiles.isReadyCached(ModelCatalog.reranker) { reranker = nil }
        lock.unlock()
        NotificationCenter.default.post(name: .modelsChanged, object: nil)
        Reembedder.shared.kick()
    }

    private func loadedGemma() -> LlamaModel? {
        lock.lock(); defer { lock.unlock() }
        lastUse = Date()
        if let gemma { return gemma }
        guard !gemmaFailed, ModelFiles.isReadyCached(ModelCatalog.embedder) else { return nil }
        let m = LlamaModel(path: ModelFiles.path(ModelCatalog.embedder).path, kind: .embedding,
                           contextTokens: 2048, maxTokens: 512, sequences: 8)
        if m == nil { gemmaFailed = true; appLog.error("EmbeddingGemma failed to load") }
        if m != nil { exitHandlerAfterFirstLoad(.embedding) }
        gemma = m
        return m
    }

    private func loadedReranker() -> LlamaModel? {
        lock.lock(); defer { lock.unlock() }
        lastUse = Date()
        if let reranker { return reranker }
        guard !rerankerFailed, !rerankerDisabled, ModelFiles.isReadyCached(ModelCatalog.reranker) else { return nil }
        let m = LlamaModel(path: ModelFiles.path(ModelCatalog.reranker).path, kind: .reranker,
                           contextTokens: 4096, maxTokens: 448, sequences: 8)
        if m == nil { rerankerFailed = true; appLog.error("Reranker failed to load") }
        if m != nil { exitHandlerAfterFirstLoad(.reranker) }
        reranker = m
        return m
    }

    /// Stops new model work, waits up to `timeout` for jobs in flight to finish, then frees the
    /// models and with them llama.cpp's Metal resources. Returns false if a job was still
    /// running when time ran out, in which case nothing is freed under it.
    /// llama.cpp's Metal backend asserts if models are still alive when the process tears down
    /// its statics, so this runs on quit and again from an exit handler.
    @discardableResult
    func shutdown(timeout: TimeInterval = 5) -> Bool {
        useCondition.lock()
        stopping = true
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 && Date() < deadline { _ = useCondition.wait(until: deadline) }
        let drained = inFlight == 0
        useCondition.unlock()
        guard drained else {
            appLog.error("models still busy at shutdown; leaving them loaded")
            return false
        }
        lock.lock()
        let g = gemma, r = reranker
        gemma = nil
        reranker = nil
        lock.unlock()
        // Freed here, on this thread, before anything else can tear Metal down.
        withExtendedLifetime((g, r)) {}
        return true
    }

    /// For tests that shut down and then keep going.
    func reopenAfterShutdownForTests() {
        useCondition.lock(); stopping = false; useCondition.unlock()
    }

    var hasLoadedModels: Bool {
        lock.lock(); defer { lock.unlock() }
        return gemma != nil || reranker != nil
    }

    /// Kinds of model that have loaded once. Read and written under `lock`.
    private var loadedKinds: Set<LlamaModel.Kind> = []

    /// Registers the exit handler after llama.cpp has set up Metal and the tables a kind of model
    /// needs, so it runs before their teardown: exit handlers run newest first. Each kind sets up
    /// its own, like the reranker's tokenizer tables, so each kind's first load registers one.
    /// With only the first load's, a reranker that loaded later crashed at exit in its tokenizer.
    private func exitHandlerAfterFirstLoad(_ kind: LlamaModel.Kind) {
        guard loadedKinds.insert(kind).inserted else { return }
        atexit { Intelligence.lastChanceAtExit() }
    }

    /// Normally a no-op: quitting already shut down. If a job never finished, skip llama.cpp's
    /// static teardown rather than crash in it.
    private static func lastChanceAtExit() {
        if !Intelligence.shared.shutdown(timeout: 5) {
            fflush(nil)
            _exit(0)
        }
    }

    /// Frees about a gigabyte of model memory when nothing used it for five minutes.
    private func unloadIfIdle() {
        useCondition.lock()
        let busy = inFlight > 0 || stopping
        useCondition.unlock()
        guard !busy else { return }
        lock.lock(); defer { lock.unlock() }
        guard gemma != nil || reranker != nil, Date().timeIntervalSince(lastUse) > 300 else { return }
        gemma = nil
        reranker = nil
    }

    // MARK: Status

    /// The embedder new passages get. EmbeddingGemma when its file is ready.
    var documentEmbedder: EmbedderID {
        if let forcedEmbedder { return forcedEmbedder }
        if ModelFiles.isReadyCached(ModelCatalog.embedder) && !gemmaFailed { return .gemma }
        return .sentence
    }

    var hasReranker: Bool {
        !rerankerDisabled && !rerankerFailed && ModelFiles.isReadyCached(ModelCatalog.reranker)
    }

    // MARK: Embedding

    /// EmbeddingGemma's document prompt. The title helps short passages.
    static func documentPrompt(title: String, text: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "title: \(t.isEmpty ? "none" : String(t.prefix(120))) | text: \(text)"
    }

    static func queryPrompt(_ q: String) -> String { "task: search result | query: \(q)" }

    /// Vectors for passages, with the model that made them.
    func embedDocuments(_ items: [(title: String, text: String)], using id: EmbedderID? = nil) -> (EmbedderID, [[Float]?]) {
        let backend = id ?? documentEmbedder
        switch backend {
        case .gemma:
            if let v = using({ loadedGemma().flatMap { $0.embed(items.map { Self.documentPrompt(title: $0.title, text: $0.text) }, stop: stopRequested) } }) {
                return (.gemma, v)
            }
            return (.sentence, items.map { Self.sentenceVector($0.text) })
        case .contextual:
            return (.contextual, items.map { ContextualEmbedder.shared.vector($0.text) })
        case .sentence:
            return (.sentence, items.map { Self.sentenceVector($0.text) })
        }
    }

    /// Query vectors for one embedder. Nil entries when that embedder isn't available.
    func embedQueries(_ queries: [String], using id: EmbedderID) -> [[Float]?] {
        switch id {
        case .gemma:
            return using { loadedGemma().flatMap { $0.embed(queries.map(Self.queryPrompt), stop: stopRequested) } } ?? queries.map { _ in nil }
        case .contextual:
            return queries.map { ContextualEmbedder.shared.vector($0) }
        case .sentence:
            return queries.map { Self.sentenceVector($0) }
        }
    }

    private static func sentenceVector(_ text: String) -> [Float]? {
        Embedder.shared.vector(text)
    }

    // MARK: Reranking

    static let rerankInstruction: String = ProcessInfo.processInfo.environment["BROWSERPOC_RR_INSTRUCT"]
        ?? "Given the user's current page or note, retrieve earlier passages on the same subject that would help with it"

    /// Scores in 0...1, or nil when the reranker isn't ready.
    func rerank(query: String, documents: [String]) -> [Float]? {
        rerank(queries: Array(repeating: query, count: documents.count), documents: documents)
    }

    /// One query per document, so each candidate is judged against the part of the context it matched.
    func rerank(queries: [String], documents: [String]) -> [Float]? {
        guard !documents.isEmpty, queries.count == documents.count else { return nil }
        return using { loadedReranker().flatMap { $0.rerank(pairs: Array(zip(queries, documents)), instruction: Self.rerankInstruction, stop: stopRequested) } }
    }
}

extension Notification.Name {
    static let modelsChanged = Notification.Name("local.browserpoc.modelsChanged")
}

extension ModelFiles {
    nonisolated(unsafe) private static var readyCache: [String: (Bool, Date)] = [:]
    private static let cacheLock = NSLock()

    /// isReady, remembered for a few seconds so hot paths don't stat the file every call.
    static func isReadyCached(_ spec: ModelSpec) -> Bool {
        cacheLock.lock()
        if let (v, at) = readyCache[spec.id + dir.path], Date().timeIntervalSince(at) < 10 { cacheLock.unlock(); return v }
        cacheLock.unlock()
        let v = isReady(spec)
        cacheLock.lock()
        readyCache[spec.id + dir.path] = (v, Date())
        cacheLock.unlock()
        return v
    }

    static func clearReadyCache() {
        cacheLock.lock(); readyCache = [:]; cacheLock.unlock()
    }
}

/// Apple's built-in contextual embedding, mean-pooled into one unit vector per text.
final class ContextualEmbedder: @unchecked Sendable {
    static let shared = ContextualEmbedder()
    private let lock = NSLock()
    private var model: NLContextualEmbedding?
    private var loaded = false

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return load() != nil
    }

    private func load() -> NLContextualEmbedding? {
        if loaded { return model }
        loaded = true
        guard let m = NLContextualEmbedding(language: .english), m.hasAvailableAssets else { return nil }
        do { try m.load() } catch { return nil }
        model = m
        return m
    }

    func vector(_ text: String) -> [Float]? {
        let input = String(text.prefix(1500))
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let m = load(), let r = try? m.embeddingResult(for: input, language: .english) else { return nil }
        var sum = [Double](repeating: 0, count: m.dimension)
        var n = 0
        r.enumerateTokenVectors(in: r.string.startIndex..<r.string.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            n += 1
            return true
        }
        guard n > 0 else { return nil }
        return VectorMath.normalized(sum.map { Float($0 / Double(n)) })
    }
}
