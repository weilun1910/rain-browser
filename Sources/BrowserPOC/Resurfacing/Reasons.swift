import Foundation
import FoundationModels

enum Reasons {
    /// Up to two shared topics, people and organisations first.
    static func topics(_ m: Match) -> [String] {
        var out: [String] = []
        for t in m.sharedEntities + m.topicTerms {
            let lower = t.lowercased()
            if out.contains(where: { $0.lowercased() == lower || $0.lowercased().contains(lower) || lower.contains($0.lowercased()) }) { continue }
            out.append(t)
            if out.count == 2 { break }
        }
        return out
    }

    static func history(_ m: Match) -> String {
        let d = m.doc
        switch d.source {
        case .web:
            var s = "You read this \(Fmt.onDay(Date(timeIntervalSince1970: d.lastSeen)))"
            if d.visitCount > 1 { s += ", \(d.visitCount) visits" }
            return s + "."
        case .chrome:
            var s = "From your Chrome history, last visited \(Fmt.day(Date(timeIntervalSince1970: d.lastSeen)))"
            if d.visitCount > 1 { s += ", \(d.visitCount) visits" }
            return s + "."
        case .note:
            return "Your note, last edited \(Fmt.day(Date(timeIntervalSince1970: d.mtime)))."
        case .markdown:
            return "Your notes file, last edited \(Fmt.day(Date(timeIntervalSince1970: d.mtime)))."
        }
    }

    static func template(_ m: Match) -> String {
        let t = topics(m)
        let tail: String
        switch t.count {
        case 2: tail = "Both cover \(t[0]) and \(t[1])."
        case 1: tail = "Both mention \(t[0])."
        default: tail = "Close in topic to what you have open."
        }
        return Fmt.clean(history(m) + " " + tail)
    }

    /// Keeps a model-written line short and within Felix's punctuation rules.
    static func tidy(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        for prefix in ["Reason:", "reason:", "Line:", "Card:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}*"))
        t = Fmt.clean(t)
        t = t.replacingOccurrences(of: " - ", with: ", ")
        var words = t.split(separator: " ").map(String.init)
        if words.count > 20 {
            words = Array(words.prefix(20))
            t = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            if !t.hasSuffix(".") { t += "." }
        }
        guard words.count >= 4 else { return nil }
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }
}

/// Writes short reasons with Apple's on-device model when it's there. One at a time.
@MainActor
final class ReasonWriter {
    static let shared = ReasonWriter()

    struct Job {
        let docID: Int64
        let contextKey: String
        let prompt: String
        let done: (String) -> Void
    }

    private var jobs: [Job] = []
    private var running = false

    nonisolated static var availabilityText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        }
    }

    nonisolated static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    nonisolated static let instructions = """
    You write one short line for a card in a browser sidebar. The card shows an item the user read or wrote earlier. \
    Say why it is useful for what they have open now by naming the specific topic both share. \
    Describe what the earlier item covers. Never claim the user did anything beyond reading or writing it. \
    One sentence, at most 18 words, plain words. No quotes, no dashes, no emoji, no preamble. \
    Example: Covers how Nook converts CRX files, which this page says you need before loading extensions.
    """

    static func prompt(contextTitle: String, contextPassage: String, match m: Match) -> String {
        let source: String
        switch m.doc.source {
        case .web: source = "a web page they read in this browser"
        case .chrome: source = "a page from their Chrome history"
        case .note: source = "one of their notes"
        case .markdown: source = "one of their Markdown notes files"
        }
        return """
        Open now: \(contextTitle)
        \(contextPassage.prefix(600))

        Earlier item, \(source). \(Reasons.history(m))
        Title: \(m.doc.title)
        \(m.passage.prefix(600))

        Shared terms: \((m.sharedEntities + m.sharedTerms).prefix(6).joined(separator: ", "))

        Write the line.
        """
    }

    func request(_ job: Job) {
        guard Self.isAvailable else { return }
        jobs.removeAll { $0.docID == job.docID && $0.contextKey == job.contextKey }
        jobs.append(job)
        pump()
    }

    func cancelAll(except contextKey: String) {
        jobs.removeAll { $0.contextKey != contextKey }
    }

    private func pump() {
        guard !running, !jobs.isEmpty else { return }
        running = true
        let job = jobs.removeFirst()
        Task {
            let text = await Self.generate(job.prompt)
            if let text {
                IndexStore.shared.saveReason(docID: job.docID, contextKey: job.contextKey, text: text)
                job.done(text)
            }
            self.running = false
            self.pump()
        }
    }

    nonisolated static func generate(_ prompt: String) async -> String? {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 60))
            return Reasons.tidy(r.content)
        } catch {
            appLog.notice("reason generation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
