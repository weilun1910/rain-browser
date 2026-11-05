import SwiftUI

/// Settings for the Arc and Zen behaviour. They live in `browser.json`.
struct BrowsingSettings: View {
    @ObservedObject var prefs = BrowserPrefs.shared

    func bind<T>(_ key: WritableKeyPath<BrowserPrefsValue, T>) -> Binding<T> {
        Binding(get: { prefs.value[keyPath: key] }, set: { v in prefs.update { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section {
                Picker("Archive idle tabs after", selection: bind(\.archiveAfterHours)) {
                    ForEach(BrowserPrefsValue.archiveChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                Text("Tabs you haven't looked at for this long move to the Archive, so Tabs stays short. Pinned tabs, Essentials, filed tabs and anything playing stay.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Links to other sites from pinned tabs open in Peek", isOn: bind(\.peekForPinnedLinks))
                Toggle("Links from other apps open in a small window", isOn: bind(\.littleArc))
                Toggle("Picture in picture when you leave a playing video", isOn: bind(\.autoPictureInPicture))
            }
            Section("Sidebar") {
                Toggle("Hide the sidebar until the pointer reaches the edge (Cmd-S)", isOn: bind(\.sidebarHidden))
                Toggle("Sidebar on the right", isOn: bind(\.sidebarOnRight))
            }
            Section {
                Button("Forget which actions I use") { prefs.update { $0.actionScores = [:] } }
                    .disabled(prefs.value.actionScores.isEmpty)
                Text("The command bar moves actions you pick often to the top.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
