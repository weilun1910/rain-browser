import Foundation

/// The MCP server's `connections` tool, served from the graph's own edges: links, navigation,
/// research, together, similar meaning and shared topics, each with its plain why sentence.
/// Opened read-only, since the running app keeps the tables current.
struct GraphStoreSource: MCPGraphSource {
    let store: GraphStore
    var name: String { "graph" }

    func edges(itemID: Int64, types: Set<String>?, limit: Int) -> [MCPEdge] {
        let t = types.map { Set($0.compactMap(GraphEdgeType.init(rawValue:))) }
        return store.edges(itemID: itemID, types: t).prefix(limit).map {
            MCPEdge(from: $0.from, to: $0.to, type: $0.type.rawValue, directed: $0.directed,
                    weight: $0.weight, detail: $0.detail, why: $0.why)
        }
    }

    /// The graph's store for this index, if the app has built its edges. Nil means use the
    /// index's own edges instead.
    static func open(indexURL: URL) -> GraphStoreSource? {
        guard let s = try? GraphStore(indexURL: indexURL, readOnly: true), s.edgeCount > 0 else { return nil }
        return GraphStoreSource(store: s)
    }
}
