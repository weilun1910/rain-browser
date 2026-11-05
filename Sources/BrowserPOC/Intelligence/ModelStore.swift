import CryptoKit
import Foundation

/// A model file the app can download and run on device.
struct ModelSpec: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case embedding, reranker }
    let id: String
    let name: String
    let role: Role
    let file: String
    let url: URL
    let bytes: Int64
    let sha256: String
    let licence: String
    let summary: String
}

enum ModelCatalog {
    static let embedder = ModelSpec(
        id: "embeddinggemma-2-q8",
        name: "EmbeddingGemma 2",
        role: .embedding,
        file: "embeddinggemma-2-Q8_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/embeddinggemma-2-Q8_0.gguf")!,
        bytes: 309_855_456,
        sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
        licence: "Apache 2.0",
        summary: "Turns every passage into a vector, so related things match by meaning.")

    static let reranker = ModelSpec(
        id: "qwen3-reranker-0.6b-q4km",
        name: "Qwen3 Reranker 0.6B",
        role: .reranker,
        file: "Qwen3-Reranker-0.6B.Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/giladgd/Qwen3-Reranker-0.6B-GGUF/resolve/main/Qwen3-Reranker-0.6B.Q4_K_M.gguf")!,
        bytes: 396_476_320,
        sha256: "046ccc0b4cb9be503b3320bfaa4e6b809ca871db2d7eb1ab6f9fd3f84170aede",
        licence: "Apache 2.0",
        summary: "Reads what you have open next to each candidate and scores how well they fit.")

    static let all = [embedder, reranker]

    static var totalBytes: Int64 { all.reduce(0) { $0 + $1.bytes } }
}

/// Where model files live. Under the support folder, so --data-dir keeps them separate.
enum ModelFiles {
    /// Set by tests and the eval to point at an existing folder of models.
    nonisolated(unsafe) static var overrideDir: URL?

    static var dir: URL {
        if let overrideDir { return overrideDir }
        // Lets the smoke test run with models from another throwaway folder.
        if let env = ProcessInfo.processInfo.environment["BROWSERPOC_MODELS_DIR"], !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        return Paths.root.appendingPathComponent("Models", isDirectory: true)
    }
    static func path(_ spec: ModelSpec) -> URL { dir.appendingPathComponent(spec.file) }
    static func partial(_ spec: ModelSpec) -> URL { dir.appendingPathComponent(spec.file + ".part") }
    static func marker(_ spec: ModelSpec) -> URL { dir.appendingPathComponent(spec.file + ".verified") }

    /// True when the file is there at full size and was checked once. Checksums are read
    /// from a marker so 700 MB isn't hashed on every launch.
    static func isReady(_ spec: ModelSpec) -> Bool {
        let p = path(spec)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: p.path))?[.size] as? NSNumber,
              size.int64Value == spec.bytes else { return false }
        if let m = try? String(contentsOf: marker(spec), encoding: .utf8), m.trimmingCharacters(in: .whitespacesAndNewlines) == spec.sha256 {
            return true
        }
        // Files placed by hand (or by the eval) are checked once, then marked.
        guard let sum = try? sha256(of: p), sum == spec.sha256 else { return false }
        try? Data(spec.sha256.utf8).write(to: marker(spec))
        return true
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streams a file to disk with HTTP Range resume. The transport is injectable so the self test
/// can check resume and checksum handling without the network.
final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case http(Int), checksum, size(Int64), cancelled, io(String)
        var description: String {
            switch self {
            case .http(let c): return "The server answered \(c)."
            case .checksum: return "The file didn't match its checksum, so it was deleted."
            case .size(let n): return "The file was \(n) bytes, not the expected size."
            case .cancelled: return "Stopped."
            case .io(let s): return s
            }
        }
    }

    typealias Progress = @Sendable (Int64, Int64) -> Void

    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var progress: Progress?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private let lock = NSLock()
    private var lastReport = Date.distantPast

    /// Downloads `spec` into ModelFiles.dir, resuming a partial file if one is there.
    func download(_ spec: ModelSpec, progress: @escaping Progress) async throws {
        Paths.ensure(ModelFiles.dir)
        let part = ModelFiles.partial(spec)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let existing = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if existing < spec.bytes {
            try await fetch(spec.url, into: part, from: existing, expected: spec.bytes, progress: progress)
        }
        try Self.finish(spec)
    }

    /// `--download-models`: fetches both models into the support folder, printing progress.
    /// Stopping it and running it again resumes where it left off.
    static func commandLine() -> Int32 {
        print("Models folder: \(ModelFiles.dir.path)")
        var code: Int32 = 0
        for spec in ModelCatalog.all {
            if ModelFiles.isReady(spec) { print("\(spec.name): ready"); continue }
            let part = ModelFiles.partial(spec)
            let start = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
            print("\(spec.name): \(start > 0 ? "resuming at \(start) bytes" : "starting"), \(spec.bytes) bytes in all")
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failure: Error?
            nonisolated(unsafe) var lastTenth = -1
            Task.detached {
                do {
                    try await ModelDownloader().download(spec) { done, total in
                        let tenth = Int(Double(done) / Double(max(total, 1)) * 10)
                        if tenth != lastTenth { lastTenth = tenth; print("  \(tenth * 10)%") }
                    }
                } catch { failure = error }
                sem.signal()
            }
            sem.wait()
            if let failure { print("  failed: \(failure)"); code = 1 } else { print("  verified and ready") }
        }
        return code
    }

    /// Checks the partial file's size and checksum, then moves it into place.
    static func finish(_ spec: ModelSpec) throws {
        let part = ModelFiles.partial(spec)
        let size = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size == spec.bytes else {
            if size > spec.bytes { try? FileManager.default.removeItem(at: part) }
            throw Failure.size(size)
        }
        guard (try? ModelFiles.sha256(of: part)) == spec.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw Failure.checksum
        }
        let dest = ModelFiles.path(spec)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: part, to: dest) } catch { throw Failure.io("\(error)") }
        try? Data(spec.sha256.utf8).write(to: ModelFiles.marker(spec))
    }

    private func fetch(_ url: URL, into file: URL, from offset: Int64, expected: Int64, progress: @escaping Progress) async throws {
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        lock.lock()
        handle = h
        written = offset
        total = expected
        self.progress = progress
        lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 60
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.start(c, session: s, request: req)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ c: CheckedContinuation<Void, Error>, session s: URLSession, request: URLRequest) {
        lock.lock()
        continuation = c
        session = s
        let t = s.dataTask(with: request)
        task = t
        lock.unlock()
        t.resume()
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        lock.lock()
        // A 200 to a Range request means the server sent the whole file again: start over.
        if code == 200 && written > 0 {
            try? handle?.truncate(atOffset: 0)
            written = 0
        }
        lock.unlock()
        if code == 200 || code == 206 { completionHandler(.allow) } else {
            completionHandler(.cancel)
            resume(throwing: Failure.http(code))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do { try handle?.write(contentsOf: data) } catch {
            lock.unlock()
            dataTask.cancel()
            resume(throwing: Failure.io("Couldn't write the model file: \(error.localizedDescription)"))
            return
        }
        written += Int64(data.count)
        let w = written, t = total, p = progress
        let now = Date()
        let report = now.timeIntervalSince(lastReport) > 0.25
        if report { lastReport = now }
        lock.unlock()
        if report { p?(w, t) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let w = written, t = total, p = progress
        lock.unlock()
        p?(w, t)
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            resume(throwing: cancelled ? Failure.cancelled : Failure.io(error.localizedDescription))
        } else {
            resume(throwing: nil)
        }
        session.finishTasksAndInvalidate()
    }

    private func resume(throwing error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}

/// Download state for Settings, and the switch that loads models once they're ready.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case missing
        case partial(Int64)
        case downloading(Int64, Int64)
        case verifying
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            default: return false
            }
        }
    }

    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var downloaders: [String: ModelDownloader] = [:]

    init() { refresh() }

    func state(_ spec: ModelSpec) -> State { states[spec.id] ?? .missing }

    var allReady: Bool { ModelCatalog.all.allSatisfy { state($0) == .ready } }
    var anyBusy: Bool { ModelCatalog.all.contains { state($0).isBusy } }

    func refresh() {
        for spec in ModelCatalog.all where !(states[spec.id]?.isBusy ?? false) {
            let spec = spec
            Task.detached(priority: .utility) {
                let ready = ModelFiles.isReady(spec)
                let partSize = ((try? FileManager.default.attributesOfItem(atPath: ModelFiles.partial(spec).path))?[.size] as? NSNumber)?.int64Value ?? 0
                await MainActor.run {
                    if self.states[spec.id]?.isBusy == true { return }
                    self.states[spec.id] = ready ? .ready : (partSize > 0 ? .partial(partSize) : .missing)
                    if ready { Intelligence.shared.modelsChanged() }
                }
            }
        }
    }

    func downloadAll() {
        try? FileManager.default.removeItem(at: ModelFiles.dir.appendingPathComponent(".paused"))
        for spec in ModelCatalog.all where state(spec) != .ready { download(spec) }
    }

    /// The first launch of a profile starts the download on its own, and a download cut off by
    /// quitting resumes on the next launch. One Felix paused stays paused until he resumes it.
    func autoStart() {
        guard !SourceSync.isTestRun else { return }
        let dir = ModelFiles.dir
        let flag = dir.appendingPathComponent(".auto-started")
        let paused = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".paused").path)
        Task.detached(priority: .utility) {
            let missing = ModelCatalog.all.filter { !ModelFiles.isReady($0) }
            guard !missing.isEmpty else { return }
            let first = !FileManager.default.fileExists(atPath: flag.path)
            guard first || !paused else { return }
            Paths.ensure(dir)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            await MainActor.run { for s in missing { self.download(s) } }
        }
    }

    /// Fraction done across both files, for the Related panel's status line. Nil when idle.
    var overallProgress: Double? {
        guard anyBusy else { return nil }
        var done: Int64 = 0
        for s in ModelCatalog.all {
            switch state(s) {
            case .ready, .verifying: done += s.bytes
            case .downloading(let d, _): done += d
            case .partial(let d): done += d
            default: break
            }
        }
        return Double(done) / Double(ModelCatalog.totalBytes)
    }

    func download(_ spec: ModelSpec) {
        guard !state(spec).isBusy else { return }
        let d = ModelDownloader()
        downloaders[spec.id] = d
        states[spec.id] = .downloading(0, spec.bytes)
        tasks[spec.id] = Task.detached(priority: .utility) { [weak self] in
            do {
                try await d.download(spec) { done, total in
                    Task { @MainActor in
                        guard let self, self.states[spec.id]?.isBusy == true else { return }
                        self.states[spec.id] = done >= total ? .verifying : .downloading(done, total)
                    }
                }
                await MainActor.run {
                    self?.states[spec.id] = .ready
                    Intelligence.shared.modelsChanged()
                }
            } catch ModelDownloader.Failure.cancelled {
                await MainActor.run { self?.refreshOne(spec) }
            } catch {
                await MainActor.run { self?.states[spec.id] = .failed(String(describing: error)) }
            }
        }
    }

    private func refreshOne(_ spec: ModelSpec) {
        let partSize = ((try? FileManager.default.attributesOfItem(atPath: ModelFiles.partial(spec).path))?[.size] as? NSNumber)?.int64Value ?? 0
        states[spec.id] = partSize > 0 ? .partial(partSize) : .missing
    }

    /// Felix's pause. Remembered so the next launch doesn't resume on its own.
    func pause() {
        Paths.ensure(ModelFiles.dir)
        FileManager.default.createFile(atPath: ModelFiles.dir.appendingPathComponent(".paused").path, contents: Data())
        cancelAll()
    }

    func cancelAll() {
        for (_, d) in downloaders { d.cancel() }
        for (_, t) in tasks { t.cancel() }
        downloaders = [:]
        tasks = [:]
    }

    /// Deletes downloaded files. The app falls back to Apple's built-in embedding.
    func remove(_ spec: ModelSpec) {
        cancelAll()
        for u in [ModelFiles.path(spec), ModelFiles.partial(spec), ModelFiles.marker(spec)] {
            try? FileManager.default.removeItem(at: u)
        }
        states[spec.id] = .missing
        Intelligence.shared.modelsChanged()
    }
}
