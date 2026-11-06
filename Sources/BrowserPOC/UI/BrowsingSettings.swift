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
            Section("Passwords") {
                Toggle("Offer logins and codes from the Passwords app", isOn: bind(\.offerPasswords))
                Text("When a login or code field gets focus, Rain offers the Passwords app. You pick a login with Touch ID, or a code from Messages or Mail, and Rain fills it in. Rain doesn't keep passwords, and it can't save new ones to Passwords yet. Edit, then Fill from Passwords (Cmd-\\) does the same for the page you're on.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Tabs") {
                Picker("Show tabs in", selection: Binding(get: { prefs.value.tabLayout }, set: { TabLayoutSwitch.set($0) })) {
                    ForEach(TabLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The tab bar runs along the top, like Safari. Spaces switch from the menu at its left, Essentials show three at a time and open into a grid when you hover them, and pinned tabs sit before a line. Option-Cmd-S switches back and forth. The sidebar settings below only apply to the sidebar.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Sidebar") {
                Toggle("Hide the sidebar until the pointer reaches the edge (Cmd-S)", isOn: bind(\.sidebarHidden))
                Toggle("Sidebar on the right", isOn: bind(\.sidebarOnRight))
                Toggle("Icons only (Ctrl-Cmd-S)", isOn: Binding(get: { prefs.value.sidebarIconsOnly },
                                                               set: { SidebarResize.shared.setIconsOnly($0) }))
                Text("Drag the sidebar's edge to change its width. Drag it all the way in for one column of icons, and double-click the edge to go back to the default width.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
