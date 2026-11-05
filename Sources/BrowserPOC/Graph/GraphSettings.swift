import Foundation
import SwiftUI

/// A colour group, like Obsidian's: items matching the query take the colour.
struct GraphGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var query: String
    var color: String
}

enum GraphTimeRange: String, Codable, CaseIterable, Identifiable {
    case week, month, quarter, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .quarter: return "Last 90 days"
        case .all: return "All time"
        }
    }
    var days: Double? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }
}

enum SiteGrouping: String, Codable, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// Everything the graph's settings panel controls. Saved to `graph.json` in the support folder.
struct GraphSettings: Codable, Equatable {
    // Filters
    var search = ""
    var nodeKinds: Set<GraphNodeKind> = Set(GraphNodeKind.filterable)
    var edgeTypes: Set<GraphEdgeType> = Set(GraphEdgeType.allCases)
    var showTopics = false
    var existingOnly = false
    var showOrphans = true
    var timeRange: GraphTimeRange = .all
    var spaceID: UUID? = nil
    var siteGrouping: SiteGrouping = .auto
    // Groups
    var groups: [GraphGroup] = []
    // Display
    var arrows = false
    /// 0 shows names early, 1 only when zoomed right in.
    var textFade: Double = 0.45
    var nodeSize: Double = 1
    var linkThickness: Double = 1
    // Forces
    var centerForce: Double = 0.45
    var repelForce: Double = 10
    var linkForce: Double = 1
    var linkDistance: Double = 40
    // Local graph
    var localDepth = 1
    var localExpanded = true
    var localNeighbourLinks = true
    // Panel
    var panelOpen = false
    var openSections: Set<String> = ["Filters"]

    /// Above this many items, Auto folds a site's pages into one node.
    static let autoGroupThreshold = 1500

    init() {}

    init(from decoder: Decoder) throws {
        // Every field is optional on disk, so older files and new fields both load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        search = v(.search, d.search)
        nodeKinds = v(.nodeKinds, d.nodeKinds)
        edgeTypes = v(.edgeTypes, d.edgeTypes)
        showTopics = v(.showTopics, d.showTopics)
        existingOnly = v(.existingOnly, d.existingOnly)
        showOrphans = v(.showOrphans, d.showOrphans)
        timeRange = v(.timeRange, d.timeRange)
        spaceID = v(.spaceID, d.spaceID)
        siteGrouping = v(.siteGrouping, d.siteGrouping)
        groups = v(.groups, d.groups)
        arrows = v(.arrows, d.arrows)
        textFade = v(.textFade, d.textFade)
        nodeSize = v(.nodeSize, d.nodeSize)
        linkThickness = v(.linkThickness, d.linkThickness)
        centerForce = v(.centerForce, d.centerForce)
        repelForce = v(.repelForce, d.repelForce)
        linkForce = v(.linkForce, d.linkForce)
        linkDistance = v(.linkDistance, d.linkDistance)
        localDepth = v(.localDepth, d.localDepth)
        localExpanded = v(.localExpanded, d.localExpanded)
        localNeighbourLinks = v(.localNeighbourLinks, d.localNeighbourLinks)
        panelOpen = v(.panelOpen, d.panelOpen)
        openSections = v(.openSections, d.openSections)
    }

    /// The settings that change which nodes and edges exist, as opposed to how they look or move.
    var structureKey: String {
        [search, nodeKinds.map(\.rawValue).sorted().joined(separator: ","), edgeTypes.map(\.rawValue).sorted().joined(separator: ","),
         "\(showTopics)", "\(existingOnly)", "\(showOrphans)", timeRange.rawValue, spaceID?.uuidString ?? "",
         siteGrouping.rawValue, groups.map { $0.query + $0.color }.joined(separator: "|"), "\(localDepth)", "\(localNeighbourLinks)"]
            .joined(separator: ";")
    }
}

/// Holds the graph settings and saves them when they change.
@MainActor
final class GraphSettingsStore: ObservableObject {
    static let shared = GraphSettingsStore()

    @Published var value: GraphSettings {
        didSet { if value != oldValue { scheduleSave() } }
    }
    private var saveWork: DispatchWorkItem?

    static var file: URL { Paths.root.appendingPathComponent("graph.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(GraphSettings.self, from: data) {
            value = s
        } else {
            value = GraphSettings()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = value
        let w = DispatchWorkItem {
            Paths.ensure(Paths.root)
            if let data = try? JSONEncoder.pretty.encode(snapshot) { try? data.write(to: Self.file, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}
