import Foundation

/// The kinds of connection the graph draws. Each can be filtered and has its own colour.
enum GraphEdgeType: String, CaseIterable, Codable, Hashable {
    /// `[[wikilinks]]`, Markdown links and URLs in a note or doc that match an indexed item.
    case link
    /// Page A led to page B through a link click.
    case navigation
    /// An item added to research from the Related panel.
    case research
    /// Two items in a split, or used close together in the same session.
    case together
    /// Top neighbours by meaning.
    case similar
    /// Both items mention the same name or topic.
    case topic

    var title: String {
        switch self {
        case .link: return "Links"
        case .navigation: return "Navigation"
        case .research: return "Research"
        case .together: return "Together"
        case .similar: return "Similar meaning"
        case .topic: return "Shared topics"
        }
    }

    /// Links, navigation and research have a direction. The others don't.
    var directed: Bool { self == .link || self == .navigation || self == .research }

    /// When two items have several kinds of connection, the line takes the colour of the first one here.
    static let priority: [GraphEdgeType] = [.link, .research, .navigation, .together, .similar, .topic]
    var rank: Int { Self.priority.firstIndex(of: self) ?? 99 }
}

/// What a node stands for.
enum GraphNodeKind: String, CaseIterable, Codable, Hashable {
    case note, doc, site, meeting, topic, unresolved, siteGroup

    var title: String {
        switch self {
        case .note: return "Notes"
        case .doc: return "Docs"
        case .site: return "Sites"
        case .meeting: return "Meetings"
        case .topic: return "Topics"
        case .unresolved: return "Not created yet"
        case .siteGroup: return "Site groups"
        }
    }

    var singular: String {
        switch self {
        case .note: return "Note"
        case .doc: return "Doc"
        case .site: return "Site"
        case .meeting: return "Meeting"
        case .topic: return "Topic"
        case .unresolved: return "Note not created yet"
        case .siteGroup: return "Site"
        }
    }

    /// Kinds the filter panel offers. Site groups follow the Sites toggle.
    static let filterable: [GraphNodeKind] = [.note, .doc, .site, .meeting]
}

/// One node in a snapshot.
struct GraphNode: Hashable {
    /// Stable across rebuilds: `d:<doc id>`, `t:<topic>`, `u:<name>` or `s:<host>`.
    let id: String
    let docID: Int64?
    let kind: GraphNodeKind
    let title: String
    let key: String
    let url: String
    let host: String
    let project: String?
    let source: String
    let firstSeen: Double
    let lastSeen: Double
    let visits: Int
    let hasText: Bool
}

/// One connection between two snapshot nodes, by index.
struct GraphLink: Hashable {
    let a: Int
    let b: Int
    let type: GraphEdgeType
    let weight: Double
    let count: Int
    let detail: String
    let last: Double
}

/// Everything in the graph, resolved to node indices. Built by `GraphStore.snapshot()`.
struct GraphSnapshot {
    var nodes: [GraphNode] = []
    var links: [GraphLink] = []
    var indexByID: [String: Int] = [:]
    var indexByDoc: [Int64: Int] = [:]
    var indexByKey: [String: Int] = [:]
    /// Link indices touching each node.
    var adjacency: [[Int]] = []
    var builtAt = Date()

    mutating func finish() {
        indexByID = [:]
        indexByDoc = [:]
        indexByKey = [:]
        for (i, n) in nodes.enumerated() {
            indexByID[n.id] = i
            if let d = n.docID { indexByDoc[d] = i }
            if !n.key.isEmpty { indexByKey[n.key] = i }
        }
        adjacency = Array(repeating: [], count: nodes.count)
        for (i, l) in links.enumerated() {
            adjacency[l.a].append(i)
            if l.b != l.a { adjacency[l.b].append(i) }
        }
    }

    func degree(_ i: Int) -> Int { adjacency[i].count }
}

// MARK: - Public interface for MCP and others

struct GraphItem: Codable, Hashable {
    let itemID: Int64
    let key: String
    let title: String
    let url: String
    /// note, doc, site or meeting.
    let kind: String
    let project: String?
    let firstSeen: Double
    let lastSeen: Double
}

struct GraphEdgeInfo: Codable, Hashable {
    let from: Int64
    let to: Int64
    let type: GraphEdgeType
    let directed: Bool
    let weight: Double
    let count: Int
    /// The anchor text, the shared topic, or "split" or "session" for together edges.
    let detail: String
    /// A plain sentence saying why the two are connected.
    let why: String
}

struct GraphNeighbour: Codable, Hashable {
    let item: GraphItem
    /// 1 for direct connections, 2 for connections of connections, and so on.
    let depth: Int
    /// The edges that reach this item from the one nearer the start.
    let via: [GraphEdgeInfo]
}

struct GraphStats: Codable {
    let items: Int
    let topics: Int
    let edges: [String: Int]
}
