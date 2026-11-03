import Foundation
import NaturalLanguage
import Accelerate

struct Entity: Hashable {
    let name: String      // folded, used for matching
    let display: String   // as written
    let kind: String      // person, org, place
    let count: Int
}

struct Analysis {
    var passages: [String]
    var vectors: [[Float]?]
    var entities: [Entity]
}

/// Word counts for a context, with the way each word was written.
struct TermCounts {
    var counts: [String: Double] = [:]
    var display: [String: String] = [:]
}

enum TextAnalysis {
    static let stopwords: Set<String> = {
        let words = """
        a about above after again against all almost also although always am among an and another any anyone anything \
        are around as at away back be became because become been before being below between both but by can cannot could \
        did do does doing done down during each either else enough even ever every few find first for from further get \
        gets getting given go goes going gone got had has have having he her here hers herself him himself his how however \
        i if in into is it its itself just keep last least less let like likely made make makes many may me might more \
        most much must my myself need never new next no nor not now of off often on once one only onto or other others \
        our ours ourselves out over own per perhaps put rather really same see seen she should since so some something \
        sometimes still such take than that the their theirs them themselves then there these they thing things this \
        those though through thus to too toward under until up upon us use used uses using very via want was way we well \
        were what whatever when where whether which while who whom whose why will with within without would yes yet you \
        your yours yourself yourselves able across actually add added already another anyway around ask asked based \
        best better big came come comes could day days different does doesn don done dont else end etc example far feel \
        good great hard help here high home however idea important include including inside instead isn its kind know \
        known large later little long look looking lot lots main makes means might mostly near nothing number old open \
        part people place point possible pretty probably quite read right said say says second seems set several show \
        shows side simple simply since small so sort start still sure tell than thanks think three today together top \
        two upon usually want way ways week weeks went whole will work works world year years yet youre ive thats theres \
        cookie cookies privacy policy terms service services subscribe newsletter sign login log menu share shared click \
        copyright rights reserved skip content navigation search home page pages site website account free contact \
        https http www com org net html htm php asp index amp nbsp quot related untitled
        """
        return Set(words.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }()

    static func fold(_ s: Substring) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits text into word tokens the same way FTS5's unicode61 tokenizer does (roughly).
    static func rawWords(_ s: String) -> [Substring] {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    static func isContentWord(_ key: String) -> Bool {
        if key.count < 3 || key.count > 40 { return false }
        if stopwords.contains(key) { return false }
        if key.allSatisfy({ $0.isNumber }) { return false }
        // Long runs of hex or digits are ids, not words.
        let digits = key.filter { $0.isNumber }.count
        if digits * 2 > key.count { return false }
        return true
    }

    static func termCounts(title: String, text: String) -> TermCounts {
        var tc = TermCounts()
        var rawForms: [String: [String: Int]] = [:]
        func add(_ s: String, weight: Double) {
            for w in rawWords(s) {
                let key = fold(w)
                guard isContentWord(key) else { continue }
                tc.counts[key, default: 0] += weight
                rawForms[key, default: [:]][String(w), default: 0] += 1
            }
        }
        add(title, weight: 3)
        add(String(text.prefix(20000)), weight: 1)
        for (k, forms) in rawForms {
            // WKWebExtension and CRX keep their casing. Ordinary words use lowercase when it
            // appears at all, so a capitalized first word in a title doesn't stick.
            let mixed = forms.filter { f in f.key.dropFirst().contains { $0.isUppercase } }
            if let best = mixed.max(by: { $0.value < $1.value }) {
                tc.display[k] = best.key
            } else if let lower = forms.keys.first(where: { $0 == $0.lowercased() }) {
                tc.display[k] = lower
            } else {
                tc.display[k] = forms.max(by: { $0.value < $1.value })?.key ?? k
            }
        }
        return tc
    }

    /// Splits text into passages of roughly `target` characters along paragraph and sentence lines.
    static func chunk(_ text: String, target: Int = 700, maxChunks: Int = 40) -> [String] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        for p in paragraphs {
            if p.count <= target * 2 {
                pieces.append(p)
            } else {
                var sentences: [String] = []
                p.enumerateSubstrings(in: p.startIndex..<p.endIndex, options: .bySentences) { sub, _, _, _ in
                    if let sub { sentences.append(sub.trimmingCharacters(in: .whitespaces)) }
                }
                var cur = ""
                for s in sentences {
                    if cur.count + s.count > target && !cur.isEmpty {
                        pieces.append(cur); cur = ""
                    }
                    if s.count > target * 2 {
                        // No sentence breaks; hard split.
                        var rest = Substring(s)
                        while rest.count > target {
                            let cut = rest.index(rest.startIndex, offsetBy: target)
                            pieces.append(String(rest[..<cut]))
                            rest = rest[cut...]
                        }
                        cur = String(rest)
                    } else {
                        cur += cur.isEmpty ? s : " " + s
                    }
                }
                if !cur.isEmpty { pieces.append(cur) }
            }
        }
        var chunks: [String] = []
        var cur = ""
        for piece in pieces {
            if cur.count + piece.count > target && cur.count >= target / 3 {
                chunks.append(cur); cur = ""
                if chunks.count >= maxChunks { break }
            }
            cur += cur.isEmpty ? piece : "\n" + piece
        }
        if !cur.isEmpty && chunks.count < maxChunks { chunks.append(cur) }
        return chunks
    }

    /// Words used as nouns somewhere in the text (unknown words count as nouns).
    static func nounKeys(_ text: String) -> Set<String> {
        let sample = String(text.prefix(20000))
        guard !sample.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sample
        var nouns = Set<String>()
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == nil || tag == .noun || tag == .otherWord {
                nouns.insert(fold(sample[range]))
            }
            return true
        }
        return nouns
    }

    static func entities(_ text: String, limit: Int = 30) -> [Entity] {
        let sample = String(text.prefix(20000))
        guard !sample.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sample
        let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        var counts: [String: (display: String, kind: String, n: Int)] = [:]
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            guard let tag else { return true }
            let kind: String
            switch tag {
            case .personalName: kind = "person"
            case .organizationName: kind = "org"
            case .placeName: kind = "place"
            default: return true
            }
            let display = String(sample[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fold(Substring(display)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard name.count >= 3, !stopwords.contains(name), display.first?.isUppercase == true else { return true }
            if var e = counts[name] { e.n += 1; counts[name] = e } else { counts[name] = (display, kind, 1) }
            return true
        }
        return counts
            .map { Entity(name: $0.key, display: $0.value.display, kind: $0.value.kind, count: $0.value.n) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    static func analyze(title: String, description: String, text: String) -> Analysis {
        var passages = chunk(text)
        if passages.isEmpty {
            let fallback = [title, description].filter { !$0.isEmpty }.joined(separator: ". ")
            passages = fallback.isEmpty ? [] : [fallback]
        }
        var vectors: [[Float]?] = []
        for (i, p) in passages.enumerated() {
            let input = i == 0 && !title.isEmpty && !p.hasPrefix(title) ? title + ". " + p : p
            vectors.append(Embedder.shared.vector(input))
        }
        let ents = entities([title, description, text].joined(separator: "\n"))
        return Analysis(passages: passages, vectors: vectors, entities: ents)
    }
}

final class Embedder: @unchecked Sendable {
    static let shared = Embedder()
    private let lock = NSLock()
    private let embedding: NLEmbedding?
    let dimension: Int

    private init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        dimension = embedding?.dimension ?? 0
    }

    var isAvailable: Bool { embedding != nil }

    func vector(_ text: String) -> [Float]? {
        let input = String(text.prefix(1500))
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let embedding, let v = embedding.vector(for: input) else { return nil }
        var f = v.map { Float($0) }
        var norm: Float = 0
        vDSP_svesq(f, 1, &norm, vDSP_Length(f.count))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var inv = 1 / norm
        vDSP_vsmul(f, 1, &inv, &f, 1, vDSP_Length(f.count))
        return f
    }

    static func dot(_ a: UnsafePointer<Float>, _ b: [Float], _ n: Int) -> Float {
        var r: Float = 0
        b.withUnsafeBufferPointer { bp in
            vDSP_dotpr(a, 1, bp.baseAddress!, 1, &r, vDSP_Length(n))
        }
        return r
    }

    static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}
