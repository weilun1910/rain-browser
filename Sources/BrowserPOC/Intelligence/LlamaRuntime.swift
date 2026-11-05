import Foundation
import llama

/// A thin Swift wrapper over llama.cpp for the two jobs we run on device: turning passages into
/// vectors, and scoring (query, passage) pairs with a cross-encoder. One instance per model file.
/// Calls are serialized; run them off the main thread.
final class LlamaModel: @unchecked Sendable {
    enum Kind { case embedding, reranker }

    let kind: Kind
    let path: String
    let dimension: Int
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let nBatch: Int
    private let nSeqMax: Int
    private let lock = NSLock()
    /// Rerank prompt with {query} and {document} placeholders, read from the GGUF.
    let rerankTemplate: String?
    /// Maximum tokens per passage. Longer input is cut.
    let maxTokens: Int

    private static let backendOnce: Void = {
        llama_log_set({ level, text, _ in
            // llama.cpp is chatty at info level. Only errors reach the log.
            if level == GGML_LOG_LEVEL_ERROR, let text {
                appLog.error("llama: \(String(cString: text), privacy: .public)")
            }
        }, nil)
        llama_backend_init()
    }()

    init?(path: String, kind: Kind, contextTokens: Int = 2048, maxTokens: Int = 512, sequences: Int = 8) {
        _ = Self.backendOnce
        self.kind = kind
        self.path = path
        self.maxTokens = maxTokens
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let m = llama_model_load_from_file(path, mp) else { return nil }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = UInt32(contextTokens)
        cp.n_ubatch = UInt32(contextTokens)
        cp.n_seq_max = UInt32(sequences)
        cp.embeddings = true
        cp.pooling_type = kind == .reranker ? LLAMA_POOLING_TYPE_RANK : LLAMA_POOLING_TYPE_UNSPECIFIED
        // Background work: leave cores for the UI.
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); return nil }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nBatch = contextTokens
        nSeqMax = sequences
        if kind == .reranker {
            dimension = Int(llama_model_n_cls_out(m))
            rerankTemplate = llama_model_chat_template(m, "rerank").map { String(cString: $0) }
        } else {
            dimension = Int(llama_model_n_embd_out(m))
            rerankTemplate = nil
        }
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let bytes = Array(text.utf8CString.dropLast())
        var cap = bytes.count + 8
        var out = [llama_token](repeating: 0, count: cap)
        var n = llama_tokenize(vocab, bytes, Int32(bytes.count), &out, Int32(cap), addSpecial, parseSpecial)
        if n < 0 && n != Int32.min {
            cap = Int(-n)
            out = [llama_token](repeating: 0, count: cap)
            n = llama_tokenize(vocab, bytes, Int32(bytes.count), &out, Int32(cap), addSpecial, parseSpecial)
        }
        return n > 0 ? Array(out.prefix(Int(n))) : []
    }

    func detokenize(_ tokens: [llama_token]) -> String {
        var buf = [CChar](repeating: 0, count: tokens.count * 12 + 16)
        let n = llama_detokenize(vocab, tokens, Int32(tokens.count), &buf, Int32(buf.count), false, false)
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Cuts a token list to the limit, keeping the final token (EOS for embedders), which
    /// pooling depends on.
    private func clip(_ t: [llama_token], to limit: Int) -> [llama_token] {
        guard t.count > limit, limit > 1 else { return t }
        return Array(t.prefix(limit - 1)) + [t.last!]
    }

    /// Runs token sequences through the model in as few batches as fit, returning the pooled
    /// output for each sequence: a vector for embedders, [p(yes), p(no)] for Qwen3 rerankers.
    private func run(_ seqs: [[llama_token]]) -> [[Float]?] {
        var results = [[Float]?](repeating: nil, count: seqs.count)
        var batch = llama_batch_init(Int32(nBatch), 0, 1)
        defer { llama_batch_free(batch) }
        var i = 0
        while i < seqs.count {
            var members: [Int] = []
            var used = 0
            while i < seqs.count, members.count < nSeqMax {
                let t = seqs[i]
                if t.isEmpty || t.count > nBatch { i += 1; continue }
                if used + t.count > nBatch { break }
                members.append(i)
                used += t.count
                i += 1
            }
            if members.isEmpty { continue }
            batch.n_tokens = 0
            for (slot, idx) in members.enumerated() {
                for (pos, tok) in seqs[idx].enumerated() {
                    let k = Int(batch.n_tokens)
                    batch.token[k] = tok
                    batch.pos[k] = llama_pos(pos)
                    batch.n_seq_id[k] = 1
                    batch.seq_id[k]![0] = llama_seq_id(slot)
                    batch.logits[k] = 1
                    batch.n_tokens += 1
                }
            }
            if let mem = llama_get_memory(ctx) { llama_memory_clear(mem, true) }
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                appLog.error("llama decode failed: \(rc, privacy: .public)")
                continue
            }
            for (slot, idx) in members.enumerated() {
                guard let p = llama_get_embeddings_seq(ctx, llama_seq_id(slot)) else { continue }
                results[idx] = Array(UnsafeBufferPointer(start: p, count: dimension))
            }
        }
        return results
    }

    /// Unit-length vectors, one per text. Texts should already carry the model's prompt prefix.
    func embed(_ texts: [String]) -> [[Float]?] {
        precondition(kind == .embedding)
        lock.lock(); defer { lock.unlock() }
        let seqs = texts.map { clip(tokenize($0, addSpecial: true, parseSpecial: false), to: maxTokens) }
        return run(seqs).map { $0.flatMap(VectorMath.normalized) }
    }

    /// Relevance in 0...1 for each document against the query.
    func rerank(query: String, instruction: String, documents: [String]) -> [Float] {
        rerank(pairs: documents.map { (query, $0) }, instruction: instruction)
    }

    /// Relevance in 0...1 for each (query, document) pair.
    func rerank(pairs: [(String, String)], instruction: String) -> [Float] {
        precondition(kind == .reranker)
        lock.lock(); defer { lock.unlock() }
        let fallback = "<|im_start|>user\n<Instruct>: {instruction}\n<Query>: {query}\n<Document>: {document}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        var template = rerankTemplate ?? fallback
        template = template
            .replacingOccurrences(of: "Given a web search query, retrieve relevant passages that answer the query", with: instruction)
            .replacingOccurrences(of: "{instruction}", with: instruction)
        // Keep the query whole and cut the document so the prompt fits.
        let seqs: [[llama_token]] = pairs.map { query, d in
            let queryTokens = tokenize(query, addSpecial: false, parseSpecial: false).count
            let docBudget = max(64, maxTokens - queryTokens - 110)
            let dt = tokenize(d, addSpecial: false, parseSpecial: false)
            let doc = dt.count > docBudget ? detokenize(Array(dt.prefix(docBudget))) : d
            let prompt = template.replacingOccurrences(of: "{query}", with: query).replacingOccurrences(of: "{document}", with: doc)
            return tokenize(prompt, addSpecial: true, parseSpecial: true)
        }
        return run(seqs).map { out in
            guard let out, !out.isEmpty else { return 0 }
            if out.count >= 2 { return out[0] }  // softmax over yes and no, already applied
            return 1 / (1 + exp(-out[0]))         // single-logit cross-encoders
        }
    }
}

enum VectorMath {
    static func normalized(_ v: [Float]) -> [Float]? {
        var s: Float = 0
        for x in v { s += x * x }
        let n = s.squareRoot()
        guard n > 0, n.isFinite else { return nil }
        return v.map { $0 / n }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        let n = min(a.count, b.count)
        for i in 0..<n { r += a[i] * b[i] }
        return r
    }
}
