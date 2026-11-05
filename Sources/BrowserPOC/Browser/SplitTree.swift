import Foundation

/// Which way a branch lays out its children. Row is side by side, column is stacked.
enum SplitAxis: String, Codable { case row, column }

/// Where a new pane goes relative to an existing one.
enum PaneSide: String, Codable, CaseIterable {
    case left, right, top, bottom
    var axis: SplitAxis { self == .left || self == .right ? .row : .column }
    var before: Bool { self == .left || self == .top }
}

/// The three ways to rebuild a split from its panes, like Zen's vsep, hsep and grid.
enum SplitLayout: String, Codable, CaseIterable {
    case sideBySide, stacked, grid
    var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .stacked: return "Stacked"
        case .grid: return "Grid"
        }
    }
}

/// A split is a tree. Leaves are items. Branches lay their children out in a row or a column,
/// each child taking a share of the branch (the shares add up to 1).
indirect enum SplitNode: Codable, Equatable {
    case leaf(UUID)
    case branch(SplitAxis, [SplitNode], [Double])

    static let maxPanes = 4

    /// Items in reading order.
    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .branch(_, let kids, _): return kids.flatMap { $0.leaves }
        }
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// The node at a path of child indexes.
    func node(at path: [Int]) -> SplitNode? {
        guard let first = path.first else { return self }
        guard case .branch(_, let kids, _) = self, kids.indices.contains(first) else { return nil }
        return kids[first].node(at: Array(path.dropFirst()))
    }

    /// Splits the pane holding `target`, putting `new` on one side of it. A branch that already
    /// runs the same way gets a new sibling, sharing the target's space.
    func inserting(_ new: UUID, at side: PaneSide, of target: UUID) -> SplitNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            let pair: [SplitNode] = side.before ? [.leaf(new), .leaf(id)] : [.leaf(id), .leaf(new)]
            return .branch(side.axis, pair, [0.5, 0.5])
        case .branch(let axis, var kids, var sizes):
            if axis == side.axis, let i = kids.firstIndex(where: { if case .leaf(let id) = $0 { return id == target }; return false }) {
                let half = sizes[i] / 2
                sizes[i] = half
                let at = side.before ? i : i + 1
                kids.insert(.leaf(new), at: at)
                sizes.insert(half, at: at)
                return .branch(axis, kids, sizes)
            }
            kids = kids.map { $0.contains(target) ? $0.inserting(new, at: side, of: target) : $0 }
            return .branch(axis, kids, sizes)
        }
    }

    /// Takes an item out. A branch left with one child becomes that child.
    func removing(_ id: UUID) -> SplitNode? {
        switch self {
        case .leaf(let x): return x == id ? nil : self
        case .branch(let axis, let kids, let sizes):
            var nk: [SplitNode] = []
            var ns: [Double] = []
            for (k, s) in zip(kids, sizes) {
                if let r = k.removing(id) { nk.append(r); ns.append(s) }
            }
            if nk.isEmpty { return nil }
            if nk.count == 1 { return nk[0] }
            return .branch(axis, nk, SplitNode.normalized(ns))
        }
    }

    func replacing(_ old: UUID, with new: UUID) -> SplitNode {
        switch self {
        case .leaf(let x): return .leaf(x == old ? new : x)
        case .branch(let a, let kids, let s): return .branch(a, kids.map { $0.replacing(old, with: new) }, s)
        }
    }

    func swapping(_ a: UUID, _ b: UUID) -> SplitNode {
        switch self {
        case .leaf(let x): return .leaf(x == a ? b : (x == b ? a : x))
        case .branch(let ax, let kids, let s): return .branch(ax, kids.map { $0.swapping(a, b) }, s)
        }
    }

    /// New shares for the branch at `path`.
    func settingSizes(_ new: [Double], at path: [Int]) -> SplitNode {
        guard case .branch(let axis, var kids, let sizes) = self else { return self }
        guard let first = path.first else {
            guard new.count == sizes.count else { return self }
            return .branch(axis, kids, SplitNode.normalized(new))
        }
        guard kids.indices.contains(first) else { return self }
        kids[first] = kids[first].settingSizes(new, at: Array(path.dropFirst()))
        return .branch(axis, kids, sizes)
    }

    /// Even shares everywhere.
    var evened: SplitNode {
        switch self {
        case .leaf: return self
        case .branch(let a, let kids, _): return .branch(a, kids.map { $0.evened }, Array(repeating: 1.0 / Double(kids.count), count: kids.count))
        }
    }

    /// Rebuilds the tree from its items. Grid stacks pairs in columns, with an odd one out at full
    /// height on the right. Two panes in a grid are side by side.
    static func layout(_ ids: [UUID], _ layout: SplitLayout) -> SplitNode {
        guard ids.count > 1 else { return .leaf(ids.first ?? UUID()) }
        let even = Array(repeating: 1.0 / Double(ids.count), count: ids.count)
        switch layout {
        case .sideBySide: return .branch(.row, ids.map { .leaf($0) }, even)
        case .stacked: return .branch(.column, ids.map { .leaf($0) }, even)
        case .grid:
            if ids.count == 2 { return .branch(.row, ids.map { .leaf($0) }, even) }
            var cols: [SplitNode] = []
            var i = 0
            while i + 1 < ids.count {
                cols.append(.branch(.column, [.leaf(ids[i]), .leaf(ids[i + 1])], [0.5, 0.5]))
                i += 2
            }
            if i < ids.count { cols.append(.leaf(ids[i])) }
            return .branch(.row, cols, Array(repeating: 1.0 / Double(cols.count), count: cols.count))
        }
    }

    /// The layout this tree matches, if it matches one exactly.
    var layoutKind: SplitLayout? {
        for l in SplitLayout.allCases where SplitNode.layout(leaves, l).sameShape(as: self) { return l }
        return nil
    }

    func sameShape(as other: SplitNode) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)): return a == b
        case (.branch(let a1, let k1, _), .branch(let a2, let k2, _)):
            return a1 == a2 && k1.count == k2.count && zip(k1, k2).allSatisfy { $0.sameShape(as: $1) }
        default: return false
        }
    }

    static func normalized(_ s: [Double]) -> [Double] {
        let total = s.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1.0 / Double(max(1, s.count)), count: s.count) }
        if abs(total - 1) < 1e-9 { return s }
        return s.map { $0 / total }
    }

    // A readable JSON shape: {"item": id} or {"axis": "row", "children": [...], "sizes": [...]}.
    private enum Keys: String, CodingKey { case item, axis, children, sizes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .item) { self = .leaf(id); return }
        let axis = try c.decode(SplitAxis.self, forKey: .axis)
        let kids = try c.decode([SplitNode].self, forKey: .children)
        var sizes = try c.decodeIfPresent([Double].self, forKey: .sizes) ?? []
        if sizes.count != kids.count { sizes = Array(repeating: 1.0 / Double(max(1, kids.count)), count: kids.count) }
        self = .branch(axis, kids, SplitNode.normalized(sizes))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .leaf(let id): try c.encode(id, forKey: .item)
        case .branch(let a, let kids, let s):
            try c.encode(a, forKey: .axis)
            try c.encode(kids, forKey: .children)
            try c.encode(s, forKey: .sizes)
        }
    }
}

/// Two to four items on screen together. Either kind of item can be in any pane.
struct SplitRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var root: SplitNode
    /// The pane that has focus. The address bar, Related and Cmd-W follow it.
    var focused: UUID
    var createdAt: Date = Date()
    var spaceID: UUID?
    var isPinned: Bool = false
    var order: Double = 0

    var items: [UUID] { root.leaves }
    func contains(_ id: UUID) -> Bool { root.contains(id) }
    var count: Int { items.count }

    // The two-pane view the first version used. Still handy, and older code reads it.
    var left: UUID {
        get { items.first ?? focused }
        set { root = root.replacing(left, with: newValue) }
    }
    var right: UUID {
        get { items.count > 1 ? items[1] : focused }
        set { root = root.replacing(right, with: newValue) }
    }
    var focusRight: Bool {
        get { items.count > 1 && focused == items[1] }
        set { focused = newValue ? right : left }
    }
    /// The first pane's share of the top-level branch.
    var ratio: Double {
        if case .branch(_, _, let s) = root, let first = s.first { return first }
        return 0.5
    }
    var other: UUID { items.first { $0 != focused } ?? focused }

    init(id: UUID = UUID(), root: SplitNode, focused: UUID, createdAt: Date = Date(), spaceID: UUID? = nil) {
        self.id = id
        self.root = root
        self.focused = focused
        self.createdAt = createdAt
        self.spaceID = spaceID
    }

    /// A side by side pair, as the first version made them.
    init(id: UUID = UUID(), left: UUID, right: UUID, ratio: Double = 0.5, focusRight: Bool = false,
         createdAt: Date = Date(), spaceID: UUID? = nil) {
        self.init(id: id, root: .branch(.row, [.leaf(left), .leaf(right)], [ratio, 1 - ratio]),
                  focused: focusRight ? right : left, createdAt: createdAt, spaceID: spaceID)
    }

    private enum Keys: String, CodingKey { case id, root, focused, createdAt, spaceID, isPinned, order, left, right, ratio, focusRight }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        spaceID = try c.decodeIfPresent(UUID.self, forKey: .spaceID)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        if let r = try c.decodeIfPresent(SplitNode.self, forKey: .root) {
            root = r
            focused = try c.decodeIfPresent(UUID.self, forKey: .focused) ?? r.leaves.first ?? UUID()
        } else {
            // Version one: a left and right pair with a divider ratio.
            let l = try c.decode(UUID.self, forKey: .left)
            let r = try c.decode(UUID.self, forKey: .right)
            let ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            let fr = try c.decodeIfPresent(Bool.self, forKey: .focusRight) ?? false
            root = .branch(.row, [.leaf(l), .leaf(r)], [ratio, 1 - ratio])
            focused = fr ? r : l
        }
        if !root.contains(focused) { focused = root.leaves.first ?? focused }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(root, forKey: .root)
        try c.encode(focused, forKey: .focused)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(spaceID, forKey: .spaceID)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(order, forKey: .order)
    }
}

/// Where a dragged item lands over the content area: which pane, and which edge of it.
enum DropMath {
    /// The closest edge within a quarter of the pane's width or height, like Zen. Nil in the middle.
    static func edge(at p: CGPoint, in r: CGRect) -> PaneSide? {
        let qw = r.width / 4, qh = r.height / 4
        let edges: [(PaneSide, CGFloat, CGFloat)] = [
            (.left, p.x - r.minX, qw), (.right, r.maxX - p.x, qw),
            (.top, p.y - r.minY, qh), (.bottom, r.maxY - p.y, qh),
        ]
        var best: (PaneSide, CGFloat)?
        for (side, dist, limit) in edges where dist < limit && dist < (best?.1 ?? .infinity) {
            best = (side, dist)
        }
        return best?.0
    }

    /// The part of a pane the new pane would take, for the drop preview.
    static func preview(_ side: PaneSide, in r: CGRect) -> CGRect {
        switch side {
        case .left: return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }
}
