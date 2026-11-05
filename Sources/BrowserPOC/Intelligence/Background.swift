import Foundation
import FoundationModels

/// Background upkeep that makes the index better on its own: re-embedding passages with the
/// best model that's ready, and tagging items with topics. Runs at utility priority in small
/// batches, slows down on battery saver or when the Mac runs hot, and never touches the UI.
final class Reembedder: @unchecked Sendable {
    static let shared = Reembedder()
    private let queue = DispatchQueue(label: "local.browserpoc.reembed", qos: .utility)
    private let lock = NSLock()
    private var running = false
    /// Tests run batches by hand.
    var enabled = true

    static var pause: TimeInterval {
        let p = ProcessInfo.processInfo
        if p.isLowPowerModeEnabled { return 3 }
        switch p.thermalState {
        case .serious, .critical: return 5
        case .fair: return 0.8
        default: return 0.15
        }
    }

    func kick() {
        lock.lock()
        guard enabled, !running, IndexStore.shared != nil else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { self.loop() }
    }

    private func loop() {
        defer { lock.lock(); running = false; lock.unlock() }
        var total = 0
        while enabled, !Intelligence.shared.isShuttingDown {
            let n = runBatch()
            if n == 0 { break }
            total += n
            Thread.sleep(forTimeInterval: Self.pause)
        }
        if total > 0 {
            appLog.notice("re-embedded \(total, privacy: .public) passages")
            DispatchQueue.main.async { NotificationCenter.default.post(name: .indexChanged, object: nil) }
        }
    }

    /// Embeds one batch of passages that don't have a vector from the current model yet.
    /// Returns how many it did.
    @discardableResult
    func runBatch(size: Int = 32) -> Int {
        guard let store = IndexStore.shared, !Intelligence.shared.isShuttingDown else { return 0 }
        let target = Intelligence.shared.documentEmbedder
        let rows = store.passagesNeedingVectors(model: target, limit: size)
        guard !rows.isEmpty else { return 0 }
        let (model, vecs) = Intelligence.shared.embedDocuments(rows.map { ($0.title, $0.text) }, using: target)
        guard model == target else { return 0 }
        var out: [(Int64, Int64, [Float])] = []
        for (i, r) in rows.enumerated() { if let v = vecs[i] { out.append((r.pid, r.did, v)) } }
        store.setVectors(out, model: model, failed: rows.filter { r in !out.contains { $0.0 == r.pid } }.map { $0.pid })
        return rows.count
    }
}

/// Topics per item from Foundation Models' content-tagging model. Only items with text, newest
/// first, a limited number per session, so it doesn't run the model for hours on battery.
final class TopicTagger: @unchecked Sendable {
    static let shared = TopicTagger()
    private let lock = NSLock()
    private var running = false
    private var doneThisSession = 0
    static let perSession = 150

    @Generable
    struct Tags {
        @Guide(description: "The main topics of the text, each a short noun phrase of one to four words", .maximumCount(5))
        var topics: [String]
    }

    static var isAvailable: Bool {
        SystemLanguageModel(useCase: .contentTagging).isAvailable
    }

    func kick() {
        lock.lock()
        guard !running, doneThisSession < Self.perSession, Self.isAvailable, IndexStore.shared != nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { lock.unlock(); return }
        running = true
        lock.unlock()
        Task.detached(priority: .background) {
            await self.loop()
            self.finished()
        }
    }

    private func finished() { lock.lock(); running = false; lock.unlock() }

    private func loop() async {
        guard let store = IndexStore.shared else { return }
        while doneThisSession < Self.perSession {
            let batch = store.docsNeedingTopics(limit: 8)
            if batch.isEmpty { break }
            for (id, title, text) in batch {
                let topics = await Self.tag(title: title, text: text)
                store.setTopics(docID: id, topics: topics ?? [], source: "model")
                doneThisSession += 1
                try? await Task.sleep(nanoseconds: UInt64(Reembedder.pause * 2_000_000_000))
            }
        }
    }

    static func tag(title: String, text: String) async -> [String]? {
        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .contentTagging),
                                           instructions: "List the main topics of the text.")
        let input = "Title: \(title)\n\(text.prefix(2400))"
        do {
            let r = try await session.respond(to: input, generating: Tags.self, options: GenerationOptions(sampling: .greedy))
            return r.content.topics.map { Fmt.clean($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
        } catch {
            return nil
        }
    }
}
