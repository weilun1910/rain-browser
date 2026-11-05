import AppKit
import SwiftUI

/// Peek: the page floats over the current one, which dims and settles back a little, like Zen's
/// Glance. Expand, Split and Close sit at the top right.
struct PeekOverlay: View {
    let peek: PeekState
    @EnvironmentObject var model: BrowserModel
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.opacity(shown ? 0.22 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePeek() }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        PeekTitle(tab: peek.tab)
                        Spacer()
                        PeekButton(symbol: "rectangle.split.2x1", help: "Open in split view") { model.splitPeek() }
                        PeekButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open as a tab (Cmd-O)") { model.expandPeek() }
                        PeekButton(symbol: "xmark", help: "Close (Esc)") { model.closePeek() }
                    }
                    .padding(.horizontal, 4)
                    WebArea(tab: peek.tab)
                        .paneCard()
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                }
                .frame(width: g.size.width * 0.84, height: g.size.height * 0.9)
                .scaleEffect(shown ? 1 : 0.94)
                .opacity(shown ? 1 : 0)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { shown = true } }
    }
}

struct PeekTitle: View {
    @ObservedObject var tab: Tab
    var body: some View {
        HStack(spacing: 6) {
            ItemIcon(tab: tab, size: 13)
            Text(tab.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white)
            if let h = tab.url?.host { Text(h).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
        }
    }
}

struct PeekButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .help(help)
    }
}

/// Find in page, at the top right of the focused pane.
struct FindBar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            FindField(text: Binding(get: { model.find.query }, set: { model.setFindQuery($0) }), focusToken: model.find.focusToken,
                      onNext: { model.findNext(backwards: $0) }, onClose: { model.closeFind() })
                .frame(width: 180, height: 20)
            Text(countText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 54, alignment: .trailing)
            SmallIconButton(symbol: "chevron.up", help: "Previous (Shift-Cmd-G)") { model.findNext(backwards: true) }
            SmallIconButton(symbol: "chevron.down", help: "Next (Cmd-G)") { model.findNext() }
            SmallIconButton(symbol: "xmark", help: "Done (Esc)") { model.closeFind() }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    var countText: String {
        guard !model.find.query.isEmpty, let n = model.find.matches else { return "" }
        return n == 0 ? "No matches" : "\(model.find.index) of \(n)"
    }
}

struct FindField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onNext: (Bool) -> Void
    let onClose: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var lastToken = -1
        init(_ p: FindField) { parent = p }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSTextField { parent.text = f.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onNext(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onClose(); return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = "Find in page"
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async { f.window?.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
        }
    }
}

/// A short message at the bottom of the content area, sometimes with Undo.
struct ToastView: View {
    let toast: ToastState
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message).font(.system(size: 12))
            if let a = toast.actionTitle {
                Button(a) { model.runToastAction() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

/// Ctrl-Tab: recent items while Ctrl is held. Release Ctrl to go there.
struct SwitcherOverlay: View {
    let state: SwitcherState
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(state.items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    switcherIcon(s)
                    Text(model.title(for: s)).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(i == state.index ? Color.accentColor.opacity(0.25) : .clear))
            }
        }
        .padding(8)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
    }

    @ViewBuilder func switcherIcon(_ s: Selection) -> some View {
        switch s {
        case .tab(let id): ItemIcon(tab: model.tab(id), size: 14)
        case .split: Image(systemName: "rectangle.split.2x1").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
        }
    }
}
