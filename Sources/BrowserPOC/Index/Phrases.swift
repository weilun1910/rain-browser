import Foundation
import NaturalLanguage

/// Short noun phrases ("fill rate", "dense neighbourhood", "multi-homing evidence") for reason
/// lines. Names, dates and numbers are left out: a reason should name the idea two items share.
enum Phrases {
    static let timeWords: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "today", "tomorrow", "yesterday", "week", "weeks", "month", "months", "year", "years",
        "time", "minute", "minutes", "hour", "hours", "morning", "evening", "night",
    ]

    struct Phrase {
        let key: String
        let display: String
        let words: Int
    }

    static func key(_ words: [String]) -> String {
        var w = words.map { TextAnalysis.fold(Substring($0)) }
        if let last = w.last, last.count > 4, last.hasSuffix("s"), !last.hasSuffix("ss") { w[w.count - 1] = String(last.dropLast()) }
        return w.joined(separator: " ")
    }

    static func isPlainWord(_ w: String) -> Bool { w == w.lowercased() }

    /// Phrases in order of first appearance, with how often each occurs.
    static func extract(_ text: String, limit: Int = 12000) -> [(Phrase, Int)] {
        let sample = String(text.prefix(limit))
        guard !sample.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sample
        // Words with their tags. Hyphenated compounds like two-sided or multi-homing are joined
        // into one word that takes the tag of its last part.
        var toks: [(word: String, tag: NLTag?, gap: Substring)] = []
        var lastEnd = sample.startIndex
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinContractions]) { tag, range in
            let gap = sample[lastEnd..<range.lowerBound]
            lastEnd = range.upperBound
            let w = String(sample[range])
            if gap == "-", let prev = toks.last {
                toks[toks.count - 1] = (prev.word + "-" + w, tag, prev.gap)
            } else {
                toks.append((w, tag, gap))
            }
            return true
        }
        var runs: [[(String, NLTag)]] = []
        var cur: [(String, NLTag)] = []
        for t in toks {
            let joinable = t.gap.allSatisfy { $0 == " " }
            if let tag = t.tag, tag == .noun || tag == .adjective, t.word.count >= 2, t.word.first?.isLetter == true {
                if !joinable && !cur.isEmpty { runs.append(cur); cur = [] }
                cur.append((t.word, tag))
            } else if !cur.isEmpty {
                runs.append(cur)
                cur = []
            }
        }
        if !cur.isEmpty { runs.append(cur) }

        var order: [String] = []
        var found: [String: (Phrase, Int)] = [:]
        var lowerForm: [String: String] = [:]
        for run in runs {
            for n in [3, 2] where run.count >= n {
                for i in 0...(run.count - n) {
                    let words = run[i..<(i + n)].map { $0.0 }
                    guard run[i + n - 1].1 == .noun else { continue }
                    let folded = words.map { TextAnalysis.fold(Substring($0)) }
                    let bad = folded.contains { f in
                        f.count < 3 || TextAnalysis.stopwords.contains(f) || timeWords.contains(f) || f.contains(where: { $0.isNumber })
                    }
                    if bad { continue }
                    // At least one ordinary lowercase word, so "Branford College" doesn't count as an idea.
                    guard words.contains(where: isPlainWord) else { continue }
                    let k = key(words)
                    let display = words.joined(separator: " ")
                    if display == display.lowercased() { lowerForm[k] = display }
                    if let e = found[k] {
                        found[k] = (e.0, e.1 + 1)
                    } else {
                        found[k] = (Phrase(key: k, display: display, words: n), 1)
                        order.append(k)
                    }
                }
            }
        }
        // A phrase that opens a sentence is written in lowercase when its first word also appears in
        // lowercase somewhere, so "Campus marketplaces" becomes "campus marketplaces" but
        // "Facebook groups" keeps its capital.
        let lowerWords = Set(toks.map { $0.word }.filter { $0 == $0.lowercased() })
        return order.compactMap { k in
            guard let (p, n) = found[k] else { return nil }
            var display = lowerForm[k] ?? p.display
            let parts = display.split(separator: " ").map(String.init)
            if lowerForm[k] == nil, let first = parts.first, lowerWords.contains(first.lowercased()),
               parts.dropFirst().allSatisfy({ $0 == $0.lowercased() }) {
                display = ([first.lowercased()] + parts.dropFirst()).joined(separator: " ")
            }
            return (Phrase(key: k, display: display, words: p.words), n)
        }
    }

    static func titleText(_ titles: [String]) -> String {
        titles.map { TextAnalysis.fold(Substring($0)) }.joined(separator: " | ")
    }

    /// Up to two phrases both texts use, longest and most repeated first, without overlaps.
    /// Phrases from either title are left out: "Both cover Japan flights" only repeats the title.
    static func shared(_ context: [(Phrase, Int)], _ item: [(Phrase, Int)], titles: [String] = [], max: Int = 2) -> [String] {
        let ctx = Dictionary(context.map { ($0.0.key, $0.1) }, uniquingKeysWith: { a, _ in a })
        let ctxDisplay = Dictionary(context.map { ($0.0.key, $0.0.display) }, uniquingKeysWith: { a, _ in a })
        let tt = titleText(titles)
        let both = item.filter { ctx[$0.0.key] != nil && !tt.contains($0.0.key) }.sorted { a, b in
            if a.0.words != b.0.words { return a.0.words > b.0.words }
            let ca = a.1 + (ctx[a.0.key] ?? 0), cb = b.1 + (ctx[b.0.key] ?? 0)
            return ca != cb ? ca > cb : a.0.key < b.0.key
        }
        var out: [Phrase] = []
        for (p, _) in both where out.count < max {
            if out.contains(where: { $0.key.contains(p.key) || p.key.contains($0.key) }) { continue }
            out.append(p)
        }
        // Whichever text writes the phrase in plain lowercase wins, so a phrase that happens to
        // open a sentence in one of them doesn't keep its capital.
        return out.map { p in
            if let c = ctxDisplay[p.key], c.first?.isLowercase == true { return c }
            return p.display
        }
    }

    /// Distinctive single words for the reason line: lowercase in the text, five letters or more,
    /// not a date, not part of a name, not a word from either title, and not a fragment like
    /// "sided" from two-sided.
    static func ideaWords(_ terms: [String], titles: [String], names: [String], context: String) -> [String] {
        let titleWords = Set(titles.flatMap { TextAnalysis.rawWords($0).map(TextAnalysis.fold) })
        let nameWords = Set(names.flatMap { TextAnalysis.rawWords($0).map(TextAnalysis.fold) })
        let lowerContext = context.lowercased()
        var out: [String] = []
        for t in terms {
            let f = TextAnalysis.fold(Substring(t))
            guard t == t.lowercased(), f.count >= 5, !timeWords.contains(f), !TextAnalysis.stopwords.contains(f),
                  !f.contains(where: { $0.isNumber }), !titleWords.contains(f), !nameWords.contains(f) else { continue }
            // Skip words that only show up as the second half of a hyphenated compound.
            if lowerContext.contains("-" + f) && !lowerContext.contains(" " + f) { continue }
            // "textbooks and books" says one thing twice.
            if out.contains(where: { let o = TextAnalysis.fold(Substring($0)); return o.contains(f) || f.contains(o) }) { continue }
            out.append(t)
        }
        return out
    }

    /// The item's own most repeated plain phrases, for when the two share none word for word.
    static func top(_ item: [(Phrase, Int)], titles: [String] = [], max: Int = 1) -> [String] {
        let tt = titleText(titles)
        return item.filter { $0.0.display == $0.0.display.lowercased() && !tt.contains($0.0.key) }
            .sorted { a, b in a.1 != b.1 ? a.1 > b.1 : (a.0.words != b.0.words ? a.0.words > b.0.words : a.0.key < b.0.key) }
            .prefix(max).map { $0.0.display }
    }
}
