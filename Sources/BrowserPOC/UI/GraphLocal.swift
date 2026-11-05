import AppKit
import SwiftUI

/// The local graph at the bottom of the right panel: the focused item and what it connects to,
/// with a depth control and a way into the full graph.
struct LocalGraphSlot: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var controller = GraphController.local
    @ObservedObject var store = GraphSettingsStore.shared
    @ObservedObject var resurfacer: Resurfacer

    static let canvasHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if store.value.localExpanded {
                ZStack {
                    GraphCanvas(controller: controller)
                    if controller.hasLoaded && controller.liveCount <= 1 && !controller.isBuilding {
                        Text(emptyText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.top, controller.liveCount == 1 ? 70 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: Self.canvasHeight)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                caption
            }
        }
        .onAppear {
            controller.model = model
            GraphController.global.model = model
            follow()
        }
        // @Published fires before the value changes, so read it on the next turn.
        .onReceive(model.$selection) { _ in DispatchQueue.main.async { follow() } }
        .onReceive(resurfacer.objectWillChange) { _ in DispatchQueue.main.async { follow() } }
    }

    /// The focused item, or with the graph focused in a split, the item next to it.
    private var followed: Tab? {
        if model.currentTab?.kind == .graph { return model.visibleTabs.first { $0.kind != .graph } }
        return model.currentTab
    }

    private func follow() {
        controller.follow(key: followed.flatMap(GraphRecorder.key))
    }

    private var emptyText: String {
        if followed == nil { return "Open a page or a note to see what it connects to." }
        if controller.liveCount == 0 { return "This isn't in the graph yet. Pages join once they've been open a few seconds." }
        return "No connections yet."
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                store.value.localExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(store.value.localExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text("Graph")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if store.value.localExpanded {
                HStack(spacing: 0) {
                    ForEach(1...3, id: \.self) { d in
                        Button { store.value.localDepth = d } label: {
                            Text("\(d)")
                                .font(.system(size: 10.5, weight: store.value.localDepth == d ? .semibold : .regular).monospacedDigit())
                                .frame(width: 18, height: 18)
                                .foregroundStyle(store.value.localDepth == d ? Color.primary : Color.secondary)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(store.value.localDepth == d ? 0.09 : 0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .help("How many steps out from this item")
                SmallIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open the full graph") {
                    if let id = controller.layout.center.map({ controller.layout.nodes[$0].id }) {
                        model.openGraph(focusID: id)
                    } else {
                        model.openGraph()
                    }
                }
            }
        }
        .frame(height: 22)
        .padding(.leading, 2)
    }

    /// Under the canvas: the hovered item and why it's connected, or a count.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let h = controller.hover {
                Text(h.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(h.reasons.first ?? h.kind).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else if controller.liveCount > 1 {
                let n = controller.liveCount - 1
                Text(n == 1 ? "1 connection" : "\(n) connections")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 30, alignment: .topLeading)
        .padding(.leading, 2)
    }
}
