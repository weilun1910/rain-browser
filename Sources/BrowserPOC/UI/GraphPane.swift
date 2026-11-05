import AppKit
import SwiftUI

/// The global graph, shown when the Graph item is open: the canvas, a search field, the
/// settings panel, a legend and a hover card.
struct GraphPane: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var controller = GraphController.global
    @ObservedObject var store = GraphSettingsStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                GraphCanvas(controller: controller)
                if controller.hasLoaded && controller.layout.isEmpty && !controller.isBuilding {
                    emptyState.frame(width: g.size.width, height: g.size.height)
                }
                VStack(alignment: .leading, spacing: 0) {
                    toolbar
                    Spacer(minLength: 0)
                    // The card sits in the corner, so it never covers the neighbours it describes.
                    if let h = controller.hover {
                        GraphHoverCard(hover: h)
                            .padding(.leading, 12)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    GraphLegend(kinds: legendKinds)
                        .padding(12)
                }
                if store.value.panelOpen {
                    HStack {
                        Spacer()
                        GraphSettingsPanel(store: store, controller: controller)
                            .frame(width: 272)
                            .frame(maxHeight: g.size.height - 56)
                            .padding(.top, 46)
                            .padding(.trailing, 10)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: controller.hover)
            .animation(.easeOut(duration: 0.2), value: store.value.panelOpen)
        }
        .onAppear {
            controller.model = model
            updateYouAreHere()
        }
        // @Published fires before the value changes, so read it on the next turn.
        .onReceive(model.$selection) { _ in DispatchQueue.main.async { updateYouAreHere() } }
    }

    /// In a split, the item next to the graph gets the "you are here" ring.
    private func updateYouAreHere() {
        controller.youAreHereKey = model.visibleTabs.first { $0.kind != .graph }.flatMap(GraphRecorder.key)
    }

    private var legendKinds: [GraphNodeKind] {
        let present = Set(controller.layout.nodes.map(\.kind))
        return [.note, .doc, .site, .meeting, .topic, .siteGroup, .unresolved].filter { present.contains($0) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            GraphSearchField(text: $store.value.search)
                .frame(width: 250)
            if controller.focusID != nil {
                Button {
                    controller.focusID = nil
                } label: {
                    HStack(spacing: 5) {
                        Text("Focused on \(focusTitle)").lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(GraphQuietButton())
                .help("Show everything again (Esc)")
            }
            Text(countText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                if controller.timelapse != nil { controller.stopTimelapse() } else { controller.startTimelapse() }
            } label: {
                Image(systemName: controller.timelapse != nil ? "stop.fill" : "play.fill").font(.system(size: 10))
            }
            .buttonStyle(GraphIconButton())
            .help(controller.timelapse != nil ? "Stop the timelapse" : "Play a timelapse in the order things were first seen")
            Button { controller.fit() } label: {
                Image(systemName: "viewfinder").font(.system(size: 12))
            }
            .buttonStyle(GraphIconButton())
            .help("Fit everything in view (0)")
            Button { store.value.panelOpen.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12))
            }
            .buttonStyle(GraphIconButton(active: store.value.panelOpen))
            .help("Filters, groups, display and forces")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var focusTitle: String {
        guard let id = controller.focusID, let i = controller.layout.indexByID[id] else { return "one item" }
        let t = controller.layout.nodes[i].title
        return t.count > 32 ? String(t.prefix(30)) + "..." : t
    }

    private var countText: String {
        let l = controller.layout
        let items = l.nodes.filter { $0.kind != .topic && $0.kind != .unresolved }.reduce(0) { $0 + max(1, $1.members.count) }
        var s = "\(items.formatted()) items   \(l.edges.count.formatted()) connections"
        if l.hiddenBySiteGroups > 0 { s += "   pages grouped by site" }
        return s
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(store.value.search.isEmpty ? "Nothing in the graph yet" : "Nothing matches that search")
                .font(.system(size: 15, weight: .medium))
            Text(store.value.search.isEmpty
                 ? "Pages you read and notes you write show up here as they're indexed, with lines for links, the paths you took between pages, and things you used together."
                 : "Try fewer words, or check the filters.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }
}

enum GraphTab {
    static let icon = "point.3.connected.trianglepath.dotted"
}

/// The Graph item's right-click menu in the sidebar.
struct GraphTabMenu: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button("Open in split view") { model.openInSplit(tab, side: .right) }
            .disabled(model.currentTab?.id == tab.id && model.currentSplit == nil)
        Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab) }
        MoveToSpaceMenu { id in model.move(tab, toSpace: id) }
        Divider()
        Button("Close") { model.remove(tab) }
    }
}

/// Title, kind and why it's connected, next to the hovered node.
struct GraphHoverCard: View {
    let hover: GraphHover

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(hover.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(hover.subtitle.isEmpty || hover.subtitle == hover.title ? hover.kind : "\(hover.kind)  |  \(hover.subtitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !hover.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hover.reasons, id: \.self) { r in
                        Text(r).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

struct GraphLegend: View {
    let kinds: [GraphNodeKind]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(kinds, id: \.self) { k in
                HStack(spacing: 5) {
                    if k == .unresolved {
                        Circle().strokeBorder(k.swatch(scheme), lineWidth: 1).frame(width: 7, height: 7)
                    } else {
                        Circle().fill(k.swatch(scheme)).frame(width: 7, height: 7)
                    }
                    Text(k.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct GraphSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Search the graph", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(focused ? 0.22 : 0.1), lineWidth: 0.5))
        .help("Words match titles, addresses and projects. type:note, site:github.com and project:Browser narrow it.")
    }
}

struct GraphIconButton: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)
                .opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(active ? 0.25 : 0.1), lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

struct GraphQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial).opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// Obsidian's four folding sections: Filters, Groups, Display and Forces.
struct GraphSettingsPanel: View {
    @ObservedObject var store: GraphSettingsStore
    @ObservedObject var controller: GraphController
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme

    private var s: Binding<GraphSettings> { $store.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section("Filters") { filters }
                section("Groups") { groups }
                section("Display") { display }
                section("Forces") { forces }
                HStack {
                    Spacer()
                    Button("Restore defaults") {
                        var d = GraphSettings()
                        d.panelOpen = true
                        d.openSections = store.value.openSections
                        store.value = d
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.top, 6)
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .controlSize(.small)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        let open = store.value.openSections.contains(title)
        Button {
            if open { store.value.openSections.remove(title) } else { store.value.openSections.insert(title) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            VStack(alignment: .leading, spacing: 7) { content() }
                .padding(.leading, 16)
                .padding(.bottom, 8)
        }
    }

    private func kindBinding(_ k: GraphNodeKind) -> Binding<Bool> {
        Binding(get: { store.value.nodeKinds.contains(k) },
                set: { on in if on { store.value.nodeKinds.insert(k) } else { store.value.nodeKinds.remove(k) } })
    }

    private func edgeBinding(_ t: GraphEdgeType) -> Binding<Bool> {
        Binding(get: { store.value.edgeTypes.contains(t) },
                set: { on in if on { store.value.edgeTypes.insert(t) } else { store.value.edgeTypes.remove(t) } })
    }

    @ViewBuilder private var filters: some View {
        caption("Show")
        ForEach(GraphNodeKind.filterable, id: \.self) { k in
            Toggle(isOn: kindBinding(k)) {
                HStack(spacing: 6) {
                    Circle().fill(k.swatch(scheme)).frame(width: 7, height: 7)
                    Text(k.title)
                }
            }
        }
        Toggle("Topics", isOn: s.showTopics)
        Toggle("Existing notes only", isOn: s.existingOnly)
        Toggle("Orphans", isOn: s.showOrphans)
        caption("Connections").padding(.top, 4)
        ForEach(GraphEdgeType.allCases, id: \.self) { t in
            Toggle(isOn: edgeBinding(t)) {
                HStack(spacing: 6) {
                    Capsule().fill(t.swatch(scheme)).frame(width: 14, height: 2)
                    Text(t.title)
                }
            }
            .disabled(t == .topic && !store.value.showTopics)
        }
        caption("Range").padding(.top, 4)
        Picker("Time", selection: s.timeRange) {
            ForEach(GraphTimeRange.allCases) { Text($0.title).tag($0) }
        }
        Picker("Space", selection: s.spaceID) {
            Text("Every space").tag(UUID?.none)
            ForEach(model.spaces) { sp in Text(sp.name).tag(UUID?.some(sp.id)) }
        }
        Picker("Group pages by site", selection: s.siteGrouping) {
            ForEach(SiteGrouping.allCases) { Text($0.title).tag($0) }
        }
        if !controller.expandedSites.isEmpty {
            Button("Fold unfolded sites again") {
                controller.expandedSites = []
                controller.reload()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    @ViewBuilder private var groups: some View {
        ForEach(store.value.groups.indices, id: \.self) { i in
            HStack(spacing: 6) {
                Menu {
                    ForEach(GraphTheme.groupPalette, id: \.self) { hex in
                        Button { store.value.groups[i].color = hex } label: { Text(hex) }
                    }
                } label: {
                    Circle().fill(Color(hex: store.value.groups[i].color)).frame(width: 10, height: 10)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                TextField("Query", text: Binding(get: { store.value.groups[i].query },
                                                 set: { store.value.groups[i].query = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.value.groups.remove(at: i)
                } label: { Image(systemName: "minus.circle").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        Button("New group") {
            let used = Set(store.value.groups.map(\.color))
            let color = GraphTheme.groupPalette.first { !used.contains($0) } ?? GraphTheme.groupPalette[0]
            store.value.groups.append(GraphGroup(query: "", color: color))
        }
        .buttonStyle(.link)
        .font(.system(size: 11.5))
        Text("Items matching a query take its colour. Same words as search, like project:Browser or site:notion.so.")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var display: some View {
        Toggle("Arrows", isOn: s.arrows)
        slider("Text fade threshold", s.textFade, 0...1)
        slider("Node size", s.nodeSize, 0.4...2.5)
        slider("Link thickness", s.linkThickness, 0.3...3)
        Button(controller.timelapse != nil ? "Stop timelapse" : "Animate") {
            if controller.timelapse != nil { controller.stopTimelapse() } else { controller.startTimelapse() }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var forces: some View {
        slider("Center force", s.centerForce, 0...1)
        slider("Repel force", s.repelForce, 0...20)
        slider("Link force", s.linkForce, 0...1)
        slider("Link distance", s.linkDistance, 10...200)
    }

    private func caption(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11.5))
            Slider(value: value, in: range)
        }
    }
}
