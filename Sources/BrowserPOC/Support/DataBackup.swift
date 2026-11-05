import Foundation
import os

/// Where Rain keeps your data, by name. Your profile is a folder in Application Support called
/// `supportFolder`, and WebKit files cookies, logins and site data under `bundleID`. Changing
/// either makes Rain open on an empty profile and signs you out of every site, so a rename has
/// to move the data across first. The self test pins both, and scripts/build.sh refuses an
/// Info.plist with another bundle ID.
enum AppIdentity {
    static let bundleID = "local.browserpoc"
    static let supportFolder = "BrowserPOC"

    /// Which build this is. scripts/build.sh stamps the commit and build time into Info.plist.
    /// A binary run outside the bundle uses its own modification time.
    static var build: String {
        if let b = Bundle.main.object(forInfoDictionaryKey: "RainBuild") as? String, !b.isEmpty { return b }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let m = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date
        return "unbundled-\(Int(m?.timeIntervalSince1970 ?? 0))"
    }
}

/// A copy of everything you've saved, made the first time a new build of Rain opens, before it
/// reads or writes anything. The last five are kept in `Backups/` in the profile.
///
/// Each backup has your profile (spaces and tabs, settings, history, what Related knows, notes in
/// Rain's own Notes folder) and WebKit's cookies and site data for this profile and its named
/// profiles. Copies on the Mac's drive share unchanged data with the originals, so they're quick
/// and take little room. The models, caches and set-aside files are left out.
enum DataBackup {
    static let keep = 5
    static var dir: URL { Paths.root.appendingPathComponent("Backups", isDirectory: true) }
    static var buildFile: URL { Paths.root.appendingPathComponent("last-build.txt") }
    static var aboutName: String { "About this backup.txt" }

    /// Profile entries that aren't copied: backups, set-aside files, the models (downloaded again
    /// from Settings), the favicon cache and scratch space.
    static let skippedInProfile: Set<String> = ["Backups", "Recovered", "Models", "favicons", "tmp", "last-build.txt"]
    /// WebKit folders that only hold caches.
    static let skippedInWebKit: Set<String> = ["NetworkCache", "MediaCache", "CacheStorage", "JavaScriptCoreDebug", "ContentRuleLists"]

    /// The app runs this at launch. Returns the new backup's folder, or nil when this build has
    /// opened the profile before, the profile is new, or the backup failed (which is reported).
    @discardableResult
    static func runIfNewBuild(build: String, webKit: [(label: String, url: URL)], now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let last = (try? String(contentsOf: buildFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if last == build { return nil }
        let entries = ((try? fm.contentsOfDirectory(atPath: Paths.root.path)) ?? [])
            .filter { !skippedInProfile.contains($0) && !$0.hasPrefix(".") }
            .sorted()
        // A new profile has nothing to keep yet.
        guard !entries.isEmpty else {
            try? Data(build.utf8).write(to: buildFile, options: .atomic)
            return nil
        }
        let name = "\(SavedFile.stamp(now)) before \(safeName(build))"
        let dest = dir.appendingPathComponent(name, isDirectory: true)
        do {
            let profile = dest.appendingPathComponent("Profile", isDirectory: true)
            try fm.createDirectory(at: profile, withIntermediateDirectories: true)
            for e in entries {
                try copyTree(Paths.root.appendingPathComponent(e), to: profile.appendingPathComponent(e), skipping: [])
            }
            var copied: [(String, URL)] = []
            for w in webKit where fm.fileExists(atPath: w.url.path) {
                let to = dest.appendingPathComponent("WebKit", isDirectory: true).appendingPathComponent(safeName(w.label))
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyTree(w.url, to: to, skipping: skippedInWebKit)
                copied.append((w.label, w.url))
            }
            let about = aboutText(build: build, last: last, now: now, webKit: copied)
            try Data(about.utf8).write(to: dest.appendingPathComponent(aboutName))
            try Data(build.utf8).write(to: buildFile, options: .atomic)
            prune()
            appLog.notice("Backed up the profile to \(dest.lastPathComponent, privacy: .public)")
            return dest
        } catch {
            // A half-made backup isn't kept, and the next launch tries again.
            try? fm.removeItem(at: dest)
            DataNotices.add(.backupFailed(error.localizedDescription))
            appLog.error("Backup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Copies a file or folder, leaving out folders named in `skipping` at any depth. Symbolic
    /// links are copied as links.
    static func copyTree(_ src: URL, to dst: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        let type = (try fm.attributesOfItem(atPath: src.path))[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            try fm.copyItem(at: src, to: dst)
            return
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) where !skipping.contains(name) {
            try copyTree(src.appendingPathComponent(name), to: dst.appendingPathComponent(name), skipping: skipping)
        }
    }

    /// Keeps the newest `keep` backups. Names start with the date, so they sort oldest first.
    static func prune() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in names.dropLast(keep) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    private static func safeName(_ s: String) -> String {
        String(s.map { "/:".contains($0) ? "-" : $0 })
    }

    private static func aboutText(build: String, last: String?, now: Date, webKit: [(String, URL)]) -> String {
        var lines = [
            "Rain made this backup on \(SavedFile.stamp(now)), the first time build \(build) opened this profile.",
            "The build before it was \(last ?? "one from before backups existed").",
            "",
            "Profile/ is a copy of the profile folder, \(Paths.root.path). It has your spaces and tabs",
            "(state.json), settings, history (history.sqlite), what Related knows (index.sqlite) and notes",
            "in Rain's own Notes folder. Notes in folders you picked live in those folders and aren't copied.",
            "",
            "To restore: quit Rain, copy what's in Profile/ back into the profile folder, and copy each",
            "folder in WebKit/ back to where it came from:",
        ]
        if webKit.isEmpty { lines.append("  (no WebKit data yet)") }
        for (label, url) in webKit { lines.append("  \(safeName(label)): \(url.path)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Where WebKit keeps this profile's cookies, logins and site data.
@MainActor
enum WebKitData {
    /// The default profile uses WebKit's default store, filed under the bundle ID. A --data-dir
    /// profile, and each named profile a space can use, have their own store named by a UUID.
    /// `library` is the user's Library folder. The self test passes a throwaway one.
    static func locations(profileNames: [String], library: URL? = nil) -> [(label: String, url: URL)] {
        let lib = library ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let wk = lib.appendingPathComponent("WebKit", isDirectory: true).appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
        let stores = wk.appendingPathComponent("WebsiteDataStore", isDirectory: true)
        var out: [(label: String, url: URL)] = []
        if let id = BrowserModel.dataStoreID {
            out.append(("Default profile", store(id, in: stores)))
        } else {
            out.append(("Default profile", wk.appendingPathComponent("WebsiteData", isDirectory: true)))
            let http = lib.appendingPathComponent("HTTPStorages", isDirectory: true)
            out.append(("Default profile cookies", http.appendingPathComponent(AppIdentity.bundleID + ".binarycookies")))
            out.append(("Default profile HTTP storage", http.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)))
        }
        for name in Set(profileNames.map { $0.lowercased() }).sorted() where !name.isEmpty {
            out.append(("Profile \(name)", store(BrowserModel.profileStoreID(name), in: stores)))
        }
        return out
    }

    /// WebKit may write the UUID in either case, so match the folder that's there.
    private static func store(_ id: UUID, in stores: URL) -> URL {
        let want = id.uuidString.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stores.path)) ?? []
        let found = names.first { $0.lowercased() == want }
        return stores.appendingPathComponent(found ?? id.uuidString, isDirectory: true)
    }

    /// The named profiles the spaces in state.json use, read without changing anything.
    static func profileNames(in stateFile: URL) -> [String] {
        struct Names: Decodable {
            struct S: Decodable { let profile: String? }
            let spaces: LossyArray<S>?
        }
        guard let d = try? Data(contentsOf: stateFile), let n = try? JSONDecoder.iso.decode(Names.self, from: d) else { return [] }
        return (n.spaces?.items ?? []).compactMap { $0.profile }
    }
}

/// What the app does with your data before its window opens.
enum DataSafety {
    /// Backs up the profile if this build hasn't opened it before, then lets the app repair files
    /// it can't read. The tours run on throwaway folders and skip the backup.
    @MainActor
    static func prepareLaunch() {
        Paths.ensure(Paths.root)
        if !BrowserModel.useEphemeralStore {
            let names = WebKitData.profileNames(in: Paths.stateFile)
            DataBackup.runIfNewBuild(build: AppIdentity.build, webKit: WebKitData.locations(profileNames: names))
        }
        SavedFile.mayRepair = true
    }
}
