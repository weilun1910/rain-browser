import AppKit
import SwiftUI

/// `--motion-tour` (only with `--data-dir`): plays a fixed sequence of the app's own actions in
/// the real window, a second or so apart, so a screen recording shows every animation in turn.
/// Each step's wall-clock time goes to `<data dir>/motion-tour.log`, to line the video up with
/// the steps. The app quits at the end.
@MainActor
enum MotionTour {
    static func start(_ model: BrowserModel) {
        guard Paths.overrideRoot != nil else {
            print("--motion-tour only runs with --data-dir, so it never touches your real profile.")
            return
        }
        let log = Paths.root.appendingPathComponent("motion-tour.log")
        try? "".write(to: log, atomically: true, encoding: .utf8)
        var t = 0.0
        func step(_ gap: Double, _ label: String, _ f: @escaping @MainActor () -> Void) {
            t += gap
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                MainActor.assumeIsolated {
                    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, label)
                    if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    f()
                }
            }
        }
        let firstFolder = { model.spaceFolders.first }
        let webInFolder = { firstFolder().flatMap { model.tabs(in: $0).first { $0.kind == .web } } }
        let noteInSpace = { model.spaceTabs.first { $0.kind == .note && $0.folderID != nil } }

        step(2.4, "startup") { Startup.shared.begin() }
        step(2.2, "space next") { model.switchSpace(by: 1) }
        step(1.4, "space back") { model.switchSpace(by: -1) }
        step(1.4, "command bar open") { model.bar.open(.newTab) }
        for (i, ch) in "cold start".enumerated() {
            step(i == 0 ? 0.5 : 0.07, "type") { model.bar.query.append(ch) }
        }
        step(1.2, "command bar close") { model.bar.close() }
        var opened: Tab?
        step(1.0, "tab open") {
            opened = model.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Network_effect"), select: true)
        }
        step(1.8, "tab close") { if let o = opened { model.remove(o) } }
        step(1.2, "folder close") { if let f = firstFolder() { model.toggleFolder(f) } }
        step(1.2, "folder open") { if let f = firstFolder() { model.toggleFolder(f) } }
        step(1.4, "note with related") { if let n = noteInSpace() { model.select(n) } }
        step(2.4, "split create") { if let w = webInFolder() { model.openInSplit(w, side: .right) } }
        step(2.4, "split separate") { if let s = model.currentSplit { model.separate(s) } }
        step(1.4, "panel hide") { Settings.shared.update { $0.rightPanelOpen = false } }
        step(1.2, "panel show") { Settings.shared.update { $0.rightPanelOpen = true } }
        step(1.6, "quit") { NSApp.terminate(nil) }
    }
}
