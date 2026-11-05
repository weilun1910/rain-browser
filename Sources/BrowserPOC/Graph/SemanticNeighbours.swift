import Accelerate
import Foundation

/// Where "similar meaning" edges come from. Today it's `IndexVectorNeighbours`, which reads the
/// sentence vectors already in the index. When the Engine agent's `semanticNeighbours(itemID, k)`
/// lands, wrap it in a small class that conforms to this and change the one line in
/// `GraphStore.makeSemanticSource`.
protocol SemanticNeighbourSource: AnyObject {
    /// Names the vectors. When it changes, every similarity edge is rebuilt.
    var signature: String { get }
    /// Loads or refreshes vectors for these items, or for everything when nil.
    func refresh(_ docIDs: [Int64]?)
    /// The items closest in meaning, best first, already above the source's own bar.
    func neighbours(of docID: Int64, k: Int) -> [(docID: Int64, score: Double)]
    /// Every item that has a vector.
    var docIDs: [Int64] { get }
}

/// Averages each item's passage vectors from the index and compares them with Accelerate.
/// Only items with real text count; a bare title embeds too poorly to say anything.
final class IndexVectorNeighbours: SemanticNeighbourSource {
    private let reader: IndexReader
    /// Cosine similarity an edge needs. Apple's sentence embedding puts unrelated English text
    /// around 0.5 to 0.7, so the bar sits well above that.
    var minScore: Float = 0.80
    private var vectors: [Int64: [Float]] = [:]
    private var dim = 0
    private var ids: [Int64] = []
    private var matrix: [Float] = []
    private var dirty = true

    init(reader: IndexReader) { self.reader = reader }

    var signature: String { "index-passages-\(dim == 0 ? reader.vectorDimension() : dim)" }
    var docIDs: [Int64] { Array(vectors.keys) }

    func refresh(_ docIDs: [Int64]?) {
        if let docIDs {
            for id in docIDs { vectors[id] = nil }
            for (id, v) in reader.meanVectors(docIDs: docIDs, dim: dim) {
                if dim == 0 { dim = v.count }
                if v.count == dim { vectors[id] = v }
            }
        } else {
            vectors = [:]
            let all = reader.meanVectors(docIDs: nil, dim: 0)
            // The most common size wins, in case the index holds vectors from two models.
            var sizes: [Int: Int] = [:]
            for (_, v) in all { sizes[v.count, default: 0] += 1 }
            dim = sizes.max { $0.value < $1.value }?.key ?? 0
            for (id, v) in all where v.count == dim { vectors[id] = v }
        }
        dirty = true
    }

    private func rebuildMatrix() {
        guard dirty else { return }
        ids = Array(vectors.keys).sorted()
        matrix = []
        matrix.reserveCapacity(ids.count * dim)
        for id in ids { matrix.append(contentsOf: vectors[id]!) }
        dirty = false
    }

    func neighbours(of docID: Int64, k: Int) -> [(docID: Int64, score: Double)] {
        guard let v = vectors[docID], dim > 0 else { return [] }
        rebuildMatrix()
        let n = ids.count
        guard n > 1 else { return [] }
        var scores = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            v.withUnsafeBufferPointer { vp in
                scores.withUnsafeMutableBufferPointer { sp in
                    // (n x dim) times (dim x 1).
                    vDSP_mmul(m.baseAddress!, 1, vp.baseAddress!, 1, sp.baseAddress!, 1,
                              vDSP_Length(n), 1, vDSP_Length(dim))
                }
            }
        }
        var best: [(Int64, Float)] = []
        for i in 0..<n where ids[i] != docID && scores[i] >= minScore {
            best.append((ids[i], scores[i]))
        }
        best.sort { $0.1 > $1.1 }
        return best.prefix(k).map { (docID: $0.0, score: Double($0.1)) }
    }
}
