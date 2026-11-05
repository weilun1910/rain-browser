import Foundation

/// A node as drawn: what it stands for, its colour and size.
struct LayoutNode {
    let id: String
    let kind: GraphNodeKind
    let title: String
    /// Host, project or "12 pages".
    let subtitle: String
    let docID: Int64?
    let key: String
    let url: String
    let host: String
    /// Snapshot indices folded into this node (more than one for a site group).
    let members: [Int]
    let firstSeen: Double
    var degree: Int = 0
    var radius: Float = 3
    var groupColor: SIMD4<Float>? = nil
    /// 0 to 1, the order this node joins the timelapse.
    var appear: Float = 0
}

/// A line as drawn. Several kinds of connection between the same two nodes share one line,
/// coloured by the most specific kind.
struct LayoutEdge {
    let a: Int
    let b: Int
    let type: GraphEdgeType
    let types: Set<GraphEdgeType>
    let weight: Float
    /// Snapshot links behind this line, for the hover card.
    let links: [Int]
}

struct GraphLayout {
    var nodes: [LayoutNode] = []
    var edges: [LayoutEdge] = []
    var adjacency: [[Int]] = []
    var snapshot = GraphSnapshot()
    /// The node a local graph is centred on.
    var center: Int?
    /// Distance from the centre, for a local graph.
    var depth: [Int] = []
    var hiddenBySiteGroups = 0
    var indexByID: [String: Int] = [:]

    var isEmpty: Bool { nodes.isEmpty }

    func neighbours(_ i: Int) -> Set<Int> {
        var s = Set<Int>()
        for e in adjacency[i] { let l = edges[e]; s.insert(l.a == i ? l.b : l.a) }
        return s
    }

    /// Why a node is connected, as plain lines for the hover card. With `to`, only the
    /// connections to that node (a local graph's centre).
    func reasons(for i: Int, to other: Int? = nil, limit: Int = 4) -> [String] {
        let n = nodes[i]
        if n.kind == .siteGroup {
            var lines = ["\(n.members.count) pages from \(n.host). Click to unfold."]
            lines.append(contentsOf: groupedReasons(i, other: other, limit: limit - 1))
            return lines
        }
        if n.kind == .topic {
            return ["Mentioned in \(adjacency[i].count) items"]
        }
        if n.kind == .unresolved {
            return ["A note linked by name that doesn't exist yet. Click to create it."]
        }
        return groupedReasons(i, other: other, limit: limit)
    }

    /// One line per neighbour, said from the hovered node's side, most specific kind first.
    private func groupedReasons(_ i: Int, other: Int?, limit: Int) -> [String] {
        var out: [(Int, Int, String)] = []
        let mine = Set(nodes[i].members)
        for e in adjacency[i] {
            let edge = edges[e]
            let o = edge.a == i ? edge.b : edge.a
            if let other, o != other { continue }
            let links = edge.links.map { snapshot.links[$0] }
            guard let line = Self.phrase(links, mine: mine, other: nodes[o]) else { continue }
            out.append((edge.type.rank, -nodes[o].degree, line))
        }
        let sorted = out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
        if sorted.count > limit { return Array(sorted.prefix(limit)) + ["and \(sorted.count - limit) more connections"] }
        return sorted
    }

    static func short(_ t: String) -> String { t.count > 40 ? String(t.prefix(38)) + "..." : t }

    static func phrase(_ links: [GraphLink], mine: Set<Int>, other: LayoutNode) -> String? {
        guard let primary = links.map(\.type).min(by: { $0.rank < $1.rank }) else { return nil }
        let o = short(other.title)
        let ofType = links.filter { $0.type == primary }
        let out = ofType.contains { mine.contains($0.a) }
        let inbound = ofType.contains { mine.contains($0.b) && !mine.contains($0.a) }
        let count = ofType.map(\.count).max() ?? 1
        var line: String
        switch primary {
        case .link:
            line = out && inbound ? "Linked both ways with \(o)" : (out ? "Links to \(o)" : "Linked from \(o)")
        case .navigation:
            line = out ? "Led you to \(o)" : "You came here from \(o)"
            if count > 1 { line += ", \(count) times" }
        case .research:
            line = out ? "You added \(o) to research from here" : "Added to research from \(o)"
        case .together:
            let split = ofType.contains { $0.detail == "split" }
            line = split ? "Side by side with \(o) in a split" : "Used with \(o) in \(count) sessions"
        case .similar:
            line = "Close in meaning to \(o)"
        case .topic:
            line = other.kind == .topic ? "Mentions \(o)" : "Both mention \(links.first?.detail ?? o)"
        }
        let also = Set(links.map(\.type)).subtracting([primary]).sorted { $0.rank < $1.rank }
        if !also.isEmpty {
            let words: [GraphEdgeType: String] = [.link: "linked", .navigation: "visited in a row", .research: "researched",
                                                  .together: "used together", .similar: "close in meaning", .topic: "a shared topic"]
            line += ", also " + also.compactMap { words[$0] }.joined(separator: " and ")
        }
        return line
    }
}

/// What the builder needs besides the snapshot and settings.
struct GraphBuildContext {
    /// Keys of items open, pinned or filed in the chosen space.
    var spaceKeys: Set<String>? = nil
    /// Centre a local graph (or the global graph's focus) on this node ID.
    var focusID: String? = nil
    var focusDepth = 1
    /// Sites whose pages show one by one even when grouping is on.
    var expandedSites: Set<String> = []
    var now = Date()
    var isLocal = false
}

/// Turns a snapshot plus settings into what gets drawn. Pure, so it runs off the main thread.
enum GraphBuilder {
    struct Query {
        var words: [String] = []
        var types: Set<GraphNodeKind> = []
        var sites: [String] = []
        var projects: [String] = []
        var isEmpty: Bool { words.isEmpty && types.isEmpty && sites.isEmpty && projects.isEmpty }
    }

    /// Plain words match the title, address or project. `type:`, `site:` and `project:` narrow it.
    static func parse(_ raw: String) -> Query {
        var q = Query()
        for tok in raw.split(whereSeparator: { $0.isWhitespace }) {
            let t = TextAnalysis.fold(tok)
            if t.hasPrefix("type:") {
                let v = String(t.dropFirst(5))
                if let k = GraphNodeKind.allCases.first(where: { $0.rawValue == v || $0.title.lowercased() == v || $0.singular.lowercased() == v }) { q.types.insert(k) }
            } else if t.hasPrefix("site:") {
                q.sites.append(String(t.dropFirst(5)))
            } else if t.hasPrefix("project:") {
                q.projects.append(String(t.dropFirst(8)))
            } else if !t.isEmpty {
                q.words.append(t)
            }
        }
        return q
    }

    static func matches(_ n: GraphNode, _ q: Query) -> Bool {
        if !q.types.isEmpty && !q.types.contains(n.kind) { return false }
        let host = n.host.lowercased()
        if !q.sites.isEmpty && !q.sites.contains(where: { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }) { return false }
        let project = TextAnalysis.fold(Substring(n.project ?? ""))
        if !q.projects.isEmpty && !q.projects.contains(where: { project.contains($0) }) { return false }
        if q.words.isEmpty { return true }
        let hay = TextAnalysis.fold(Substring(n.title + " " + n.url + " " + (n.project ?? "")))
        return q.words.allSatisfy { hay.contains($0) }
    }

    static func build(_ snap: GraphSnapshot, _ s: GraphSettings, _ ctx: GraphBuildContext) -> GraphLayout {
        let count = snap.nodes.count
        var keep = [Bool](repeating: false, count: count)
        let query = parse(s.search)
        let cutoff = s.timeRange.days.map { ctx.now.timeIntervalSince1970 - $0 * 86400 }

        // 1. Items that pass the filters. Topics and unresolved links come along when they touch one.
        for (i, n) in snap.nodes.enumerated() where n.docID != nil {
            if !s.nodeKinds.contains(n.kind) { continue }
            if let cutoff, max(n.firstSeen, n.lastSeen) < cutoff { continue }
            if !ctx.isLocal, !query.isEmpty, !matches(n, query) { continue }
            keep[i] = true
        }
        if let spaceKeys = ctx.spaceKeys, !ctx.isLocal {
            var inSpace = [Bool](repeating: false, count: count)
            for (i, n) in snap.nodes.enumerated() where keep[i] && spaceKeys.contains(n.key) { inSpace[i] = true }
            // The space's items and what they connect to directly.
            var next = inSpace
            for (i, on) in inSpace.enumerated() where on {
                for li in snap.adjacency[i] {
                    let l = snap.links[li]
                    let o = l.a == i ? l.b : l.a
                    if keep[o] && s.edgeTypes.contains(l.type) { next[o] = true }
                }
            }
            for i in 0..<count where snap.nodes[i].docID != nil { keep[i] = keep[i] && next[i] }
        }
        func edgeAllowed(_ l: GraphLink) -> Bool {
            guard s.edgeTypes.contains(l.type) else { return false }
            if l.type == .topic && !s.showTopics { return false }
            return true
        }
        for (i, n) in snap.nodes.enumerated() where n.docID == nil {
            if n.kind == .topic && !s.showTopics { continue }
            if n.kind == .unresolved && (s.existingOnly || !s.nodeKinds.contains(.note)) { continue }
            let touches = snap.adjacency[i].filter { li in
                let l = snap.links[li]
                let o = l.a == i ? l.b : l.a
                return keep[o] && edgeAllowed(l)
            }
            // A topic node is only worth drawing when it ties two visible items together.
            keep[i] = n.kind == .topic ? touches.count >= 2 : !touches.isEmpty
        }

        // 2. A local graph: only what's within reach of the centre.
        var depth = [Int](repeating: -1, count: count)
        var center: Int?
        if let fid = ctx.focusID, let c = snap.indexByID[fid] {
            center = c
            keep[c] = true
            depth[c] = 0
            var frontier = [c]
            for d in 1...max(1, ctx.focusDepth) {
                var next: [Int] = []
                for i in frontier {
                    for li in snap.adjacency[i] {
                        let l = snap.links[li]
                        guard edgeAllowed(l) else { continue }
                        let o = l.a == i ? l.b : l.a
                        guard keep[o] || (snap.nodes[o].kind == .topic && s.showTopics) || snap.nodes[o].kind == .unresolved && !s.existingOnly,
                              depth[o] < 0 else { continue }
                        depth[o] = d
                        next.append(o)
                    }
                }
                frontier = next
            }
            for i in 0..<count { keep[i] = depth[i] >= 0 }
        }

        // 3. Edges between kept nodes.
        var rawEdges: [(Int, Int, Int)] = [] // a, b, link index
        for (li, l) in snap.links.enumerated() where keep[l.a] && keep[l.b] && edgeAllowed(l) {
            if center != nil && !s.localNeighbourLinks && ctx.isLocal {
                // Only links that lead outward from the centre.
                if depth[l.a] == depth[l.b] { continue }
            }
            rawEdges.append((l.a, l.b, li))
        }

        // 4. Orphans.
        if !s.showOrphans && center == nil {
            var connected = [Bool](repeating: false, count: count)
            for (a, b, _) in rawEdges { connected[a] = true; connected[b] = true }
            for i in 0..<count where keep[i] && !connected[i] { keep[i] = false }
        }

        // 5. Fold a site's pages into one node when there are too many.
        let visible = (0..<count).filter { keep[$0] }
        let groupSites = center == nil && (s.siteGrouping == .always || (s.siteGrouping == .auto && visible.count > GraphSettings.autoGroupThreshold))
        var groupOf = [String?](repeating: nil, count: count)
        var hidden = 0
        if groupSites {
            var byHost: [String: [Int]] = [:]
            for i in visible where snap.nodes[i].kind == .site && !snap.nodes[i].host.isEmpty && !ctx.expandedSites.contains(snap.nodes[i].host) {
                byHost[snap.nodes[i].host, default: []].append(i)
            }
            for (host, members) in byHost where members.count >= 2 {
                for m in members { groupOf[m] = host }
                hidden += members.count - 1
            }
        }

        // 6. Layout nodes.
        var layout = GraphLayout()
        layout.snapshot = snap
        layout.hiddenBySiteGroups = hidden
        var nodeOf = [Int](repeating: -1, count: count)
        var groupIndex: [String: Int] = [:]
        var groupMembers: [String: [Int]] = [:]
        for i in visible { if let h = groupOf[i] { groupMembers[h, default: []].append(i) } }
        for i in visible {
            let n = snap.nodes[i]
            if let h = groupOf[i] {
                if let gi = groupIndex[h] { nodeOf[i] = gi; continue }
                let members = groupMembers[h] ?? [i]
                let gi = layout.nodes.count
                layout.nodes.append(LayoutNode(id: "s:\(h)", kind: .siteGroup, title: h, subtitle: "\(members.count) pages",
                                               docID: nil, key: "", url: "https://\(h)", host: h, members: members,
                                               firstSeen: members.map { snap.nodes[$0].firstSeen }.min() ?? n.firstSeen))
                groupIndex[h] = gi
                nodeOf[i] = gi
                continue
            }
            nodeOf[i] = layout.nodes.count
            let subtitle: String
            switch n.kind {
            case .note: subtitle = n.project ?? "Notes"
            case .topic: subtitle = "Topic"
            case .unresolved: subtitle = "Not created yet"
            default: subtitle = n.host
            }
            layout.nodes.append(LayoutNode(id: n.id, kind: n.kind, title: n.title, subtitle: subtitle, docID: n.docID, key: n.key,
                                           url: n.url, host: n.host, members: [i], firstSeen: n.firstSeen))
        }

        // 7. Merge parallel edges onto one line.
        var merged: [Int64: (Set<GraphEdgeType>, [Int], Float, Int, Int)] = [:]
        var order: [Int64] = []
        for (a, b, li) in rawEdges {
            let x = nodeOf[a], y = nodeOf[b]
            guard x >= 0, y >= 0, x != y else { continue }
            let l = snap.links[li]
            let k = Int64(min(x, y)) << 32 | Int64(max(x, y))
            if var m = merged[k] {
                m.0.insert(l.type); m.1.append(li); m.2 = max(m.2, Float(l.weight))
                merged[k] = m
            } else {
                merged[k] = ([l.type], [li], Float(l.weight), x, y)
                order.append(k)
            }
        }
        for k in order {
            let m = merged[k]!
            let primary = m.0.min { $0.rank < $1.rank }!
            // Orient the line along the primary link's direction.
            var a = m.3, b = m.4
            if let pl = m.1.map({ snap.links[$0] }).first(where: { $0.type == primary }) {
                let pa = nodeOf[pl.a], pb = nodeOf[pl.b]
                if pa >= 0 && pb >= 0 { a = pa; b = pb }
            }
            layout.edges.append(LayoutEdge(a: a, b: b, type: primary, types: m.0, weight: min(1, max(0.2, m.2)), links: m.1))
        }

        // 8. Sizes, colours, timelapse order.
        layout.adjacency = Array(repeating: [], count: layout.nodes.count)
        for (ei, e) in layout.edges.enumerated() { layout.adjacency[e.a].append(ei); layout.adjacency[e.b].append(ei) }
        let groups = s.groups.map { (parse($0.query), GraphTheme.hex($0.color)) }.filter { !$0.0.isEmpty }
        let theme = GraphTheme.dark
        for i in layout.nodes.indices {
            let deg = layout.adjacency[i].count
            layout.nodes[i].degree = deg
            var r = (theme.radiusBase + theme.radiusPerLink * Float(deg).squareRoot()) * Float(s.nodeSize)
            if layout.nodes[i].kind == .siteGroup { r += Float(layout.nodes[i].members.count).squareRoot() * 0.9 * Float(s.nodeSize) }
            if layout.nodes[i].kind == .topic || layout.nodes[i].kind == .unresolved { r *= 0.8 }
            layout.nodes[i].radius = r
            if !groups.isEmpty, let first = layout.nodes[i].members.first {
                let n = snap.nodes[first]
                if let g = groups.first(where: { matches(n, $0.0) }) { layout.nodes[i].groupColor = g.1 }
            }
        }
        let byTime = layout.nodes.indices.sorted { layout.nodes[$0].firstSeen < layout.nodes[$1].firstSeen }
        let denom = Float(max(1, byTime.count - 1))
        for (rank, i) in byTime.enumerated() { layout.nodes[i].appear = Float(rank) / denom }

        if let c = center { layout.center = nodeOf[c] >= 0 ? nodeOf[c] : nil }
        layout.depth = layout.nodes.map { n in n.members.map { depth[$0] }.filter { $0 >= 0 }.min() ?? -1 }
        layout.indexByID = Dictionary(layout.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return layout
    }
}
