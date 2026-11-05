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

    private init() {
        let t = DispatchSource.makeTimerSource(queue: loadQueue)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.unloadIfIdle() }
        t.resume()
        idleTimer = t
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
        reranker = m
        return m
    }

    /// Frees about a gigabyte of model memory when nothing used it for five minutes.
    private func unloadIfIdle() {
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
            if let g = loadedGemma() {
                return (.gemma, g.embed(items.map { Self.documentPrompt(title: $0.title, text: $0.text) }))
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
            guard let g = loadedGemma() else { return queries.map { _ in nil } }
            return g.embed(queries.map(Self.queryPrompt))
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

    static let rerankInstruction = "Given what the user is reading or writing right now, judge whether this earlier passage would be useful to bring back to them"

    /// Scores in 0...1, or nil when the reranker isn't ready.
    func rerank(query: String, documents: [String]) -> [Float]? {
        guard !documents.isEmpty, let r = loadedReranker() else { return nil }
        return r.rerank(query: query, instruction: Self.rerankInstruction, documents: documents)
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
