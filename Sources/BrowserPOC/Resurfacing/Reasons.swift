import Foundation
import FoundationModels

/// Card reasons. The first sentence is always history from the index: when Felix saw the item
/// and what he was doing then. The second says what it covers, from the on-device model's
/// judgment when it ran, or from shared names and words when it didn't.
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

    static func day(_ t: Double) -> String { Fmt.onDay(Date(timeIntervalSince1970: t)) }

    /// "while writing Thesis outline", from the visit closest to the item's last sighting.
    static func during(_ visits: [Visit]) -> String? {
        guard let v = visits.first(where: { ($0.during ?? "").isEmpty == false }), let d = v.during else { return nil }
        return d
    }

    static func docKind(_ url: String) -> String {
        guard let u = URL(string: url), let d = WritingKey.googleDoc(u) else { return "Google Doc" }
        switch d.type {
        case "spreadsheets": return "Google Sheet"
        case "presentation": return "Google Slides deck"
        default: return "Google Doc"
        }
    }

    /// When and in what context Felix saw it. Never vague: every part comes from stored history.
    static func history(_ d: DocMeta, visits: [Visit] = []) -> String {
        let latestVisit = visits.first
        let ctx = during(visits).map { " while \($0)" } ?? ""
        switch d.source {
        case .web:
            let when = day(latestVisit?.at ?? d.lastSeen)
            var s = "You read this \(when)\(ctx)"
            if ctx.isEmpty && d.visitCount > 1 { s += ", \(d.visitCount) visits" }
            return s + "."
        case .chrome:
            var s = "From your Chrome history, last visited \(Fmt.day(Date(timeIntervalSince1970: d.lastSeen)))"
            if d.visitCount > 1 { s += ", \(d.visitCount) visits" }
            return s + "."
        case .note, .markdown:
            let where_ = d.project.flatMap { $0 == "Notes" ? nil : " in \($0)" } ?? ""
            return "Your note\(where_), last edited \(Fmt.day(Date(timeIntervalSince1970: d.mtime)))."
        case .notion:
            return "Your Notion page, last opened \(Fmt.day(Date(timeIntervalSince1970: d.lastSeen)))\(ctx)."
        case .gdocs:
            return "Your \(docKind(d.url)), last opened \(Fmt.day(Date(timeIntervalSince1970: d.lastSeen)))\(ctx)."
        case .granola:
            return "From your meeting \(day(d.firstSeen))."
        }
    }

    /// The covers-what sentence without a model.
    static func coverage(_ m: Match) -> String {
        let t = topics(m)
        switch t.count {
        case 2: return "Both cover \(t[0]) and \(t[1])."
        case 1: return "Both mention \(t[0])."
        default:
            if let first = m.sharedTerms.first { return "It also covers \(first)." }
            return "It matches what you have open by meaning."
        }
    }

    static func template(_ m: Match, visits: [Visit] = []) -> String {
        Fmt.clean(history(m.doc, visits: visits) + " " + coverage(m))
    }

    /// A card shows two lines, so the whole reason stays within about 20 words.
    static let maxWords = 17

    static func withJudgment(_ m: Match, visits: [Visit], judgment: Judgment) -> String {
        guard judgment.helpful, !judgment.reason.isEmpty else { return template(m, visits: visits) }
        let h = history(m.doc, visits: visits)
        let room = max(6, maxWords - h.split(separator: " ").count)
        // A sentence cut short reads badly, so a long one gives way to the plain line.
        guard let covers = tidy(judgment.reason), covers.split(separator: " ").count <= room + 2 else {
            return template(m, visits: visits)
        }
        return Fmt.clean(h + " " + covers)
    }

    /// Keeps a model-written line short and within Felix's punctuation rules.
    static func tidy(_ raw: String, maxWords: Int = 24) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        for prefix in ["Reason:", "reason:", "Line:", "Card:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}*"))
        t = Fmt.clean(t)
        t = t.replacingOccurrences(of: " - ", with: ", ")
        var words = t.split(separator: " ").map(String.init)
        if words.count > maxWords {
            words = Array(words.prefix(maxWords))
            t = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            if !t.hasSuffix(".") { t += "." }
        }
        guard words.count >= 4 else { return nil }
        if let last = t.last, !".!?".contains(last) { t += "." }
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t
    }
}

/// Foundation Models availability, for logs and Settings.
enum ReasonWriter {
    static var availabilityText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        }
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }
}

/// What Felix is writing or where he is, so captures can record the context they happened in.
/// Written on the main thread by the Resurfacer, read by the indexer.
final class ActivityTracker: @unchecked Sendable {
    static let shared = ActivityTracker()
    private let lock = NSLock()
    private var writing: (title: String, key: String, at: Date)?
    private var space: String?
    private var spaceCount = 1

    func noteWriting(title: String, key: String) {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Long titles would crowd the card's reason line.
        let words = t.split(separator: " ")
        if words.count > 5 { t = words.prefix(5).joined(separator: " ") }
        lock.lock(); writing = (String(t.prefix(60)), key, Date()); lock.unlock()
    }

    func noteSpace(_ name: String?, count: Int) {
        lock.lock(); space = name; spaceCount = count; lock.unlock()
    }

    /// "writing Thesis outline" when Felix wrote in something during the last 20 minutes,
    /// else "in your Research space" when he has more than one space. Nil otherwise.
    func current(excluding key: String? = nil, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let w = writing, now.timeIntervalSince(w.at) < 1200, w.key != key { return "writing \(w.title)" }
        if spaceCount > 1, let s = space, !s.isEmpty { return "in your \(s) space" }
        return nil
    }

    func reset() {
        lock.lock(); writing = nil; space = nil; spaceCount = 1; lock.unlock()
    }
}
