import Foundation

/// A new build backs the profile up before touching it, and the app's ID and profile folder stay
/// put, since changing either would open an empty profile and sign you out of every site.
enum BackupTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let before = Paths.overrideRoot
        defer {
            Paths.overrideRoot = before
            _ = DataNotices.take()
        }
        identity()
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        Paths.ensure(root)
        Paths.overrideRoot = root
        backups(root, scratch: dir)
        MainActor.assumeIsolated { webKitLocations(scratch: dir) }
    }

    // MARK: - The app's ID and folder

    static func identity() {
        check(AppIdentity.bundleID == "local.browserpoc", "the bundle ID stays local.browserpoc, which keeps your cookies and logins")
        check(AppIdentity.supportFolder == "BrowserPOC", "the profile folder stays BrowserPOC, which keeps your tabs, settings and history")
        let saved = Paths.overrideRoot
        Paths.overrideRoot = nil
        let real = Paths.root
        Paths.overrideRoot = saved
        check(real.lastPathComponent == "BrowserPOC" && real.deletingLastPathComponent().lastPathComponent == "Application Support",
              "the profile is in Application Support/BrowserPOC")
    }

    // MARK: - Backups

    static func backups(_ root: URL, scratch: URL) {
        let fm = FileManager.default
        let t0 = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
        func text(_ u: URL) -> String? { (try? Data(contentsOf: u)).flatMap { String(data: $0, encoding: .utf8) } }
        func put(_ rel: String, _ body: String) {
            let u = root.appendingPathComponent(rel)
            Paths.ensure(u.deletingLastPathComponent())
            try? Data(body.utf8).write(to: u)
        }

        check(DataBackup.runIfNewBuild(build: "A", webKit: [], now: t0) == nil
              && text(DataBackup.buildFile) == "A" && !fm.fileExists(atPath: DataBackup.dir.path),
              "a new profile has nothing to back up")

        put("state.json", "tabs v1")
        put("settings.json", "settings")
        put("history.sqlite", "history")
        put("index.sqlite", "index")
        put("index.sqlite-wal", "index wal")
        put("Notes/plan.md", "# Plan")
        put("sessions/x.json", "back and forward")
        put("Models/model.gguf", "big")
        put("favicons/a.png", "icon")
        put("tmp/scratch", "scratch")
        put("Recovered/state old.json", "old")
        let web = scratch.appendingPathComponent("data-safety-webkit", isDirectory: true)
        try? fm.removeItem(at: web)
        let site = web.appendingPathComponent("WebsiteData", isDirectory: true)
        Paths.ensure(site.appendingPathComponent("LocalStorage"))
        Paths.ensure(site.appendingPathComponent("NetworkCache"))
        try? Data("local".utf8).write(to: site.appendingPathComponent("LocalStorage/a.localstorage"))
        try? Data("cache".utf8).write(to: site.appendingPathComponent("NetworkCache/blob"))
        let cookies = web.appendingPathComponent("cookies.binarycookies")
        try? Data("cookies".utf8).write(to: cookies)
        let webKit: [(label: String, url: URL)] = [("Default profile", site), ("Default profile cookies", cookies),
                                                  ("Not there", web.appendingPathComponent("missing"))]

        guard let first = DataBackup.runIfNewBuild(build: "B", webKit: webKit, now: t0) else {
            check(false, "a new build backs up the profile", "\(DataNotices.peek())"); return
        }
        let p = first.appendingPathComponent("Profile")
        check(text(p.appendingPathComponent("state.json")) == "tabs v1" && text(p.appendingPathComponent("Notes/plan.md")) == "# Plan"
              && text(p.appendingPathComponent("index.sqlite-wal")) == "index wal" && text(p.appendingPathComponent("sessions/x.json")) != nil,
              "a new build backs up tabs, settings, history, the index and notes")
        check(!["Models", "favicons", "tmp", "Recovered", "Backups", "last-build.txt"].contains { fm.fileExists(atPath: p.appendingPathComponent($0).path) },
              "the backup leaves out models, caches and earlier backups")
        let w = first.appendingPathComponent("WebKit")
        check(text(w.appendingPathComponent("Default profile/LocalStorage/a.localstorage")) == "local"
              && !fm.fileExists(atPath: w.appendingPathComponent("Default profile/NetworkCache").path)
              && text(w.appendingPathComponent("Default profile cookies")) == "cookies"
              && !fm.fileExists(atPath: w.appendingPathComponent("Not there").path),
              "the backup has cookies and site data, without WebKit's caches")
        let about = text(first.appendingPathComponent(DataBackup.aboutName)) ?? ""
        check(about.contains(site.path) && about.contains(cookies.path) && about.contains("build B"), "the backup says how to restore it")
        check(text(DataBackup.buildFile) == "B", "the build is remembered")
        check(DataBackup.runIfNewBuild(build: "B", webKit: webKit, now: t0.addingTimeInterval(30)) == nil, "the same build doesn't back up again")

        put("state.json", "tabs v2")
        let second = DataBackup.runIfNewBuild(build: "C", webKit: webKit, now: t0.addingTimeInterval(60))
        check(second.map { text($0.appendingPathComponent("Profile/state.json")) } == "tabs v2"
              && text(p.appendingPathComponent("state.json")) == "tabs v1",
              "each build gets its own backup, and older ones stay as they were")

        for (i, b) in ["D", "E", "F", "G"].enumerated() {
            DataBackup.runIfNewBuild(build: b, webKit: webKit, now: t0.addingTimeInterval(Double(120 + i * 60)))
        }
        let kept = ((try? fm.contentsOfDirectory(atPath: DataBackup.dir.path)) ?? []).filter { !$0.hasPrefix(".") }
        check(kept.count == DataBackup.keep && !fm.fileExists(atPath: first.path) && kept.contains { $0.hasSuffix("before G") },
              "the last five backups are kept", "\(kept.sorted())")

        // A backup that can't be made is reported, keeps nothing half-made, and is tried again next launch.
        try? fm.removeItem(at: DataBackup.dir)
        try? Data("a file where the folder should be".utf8).write(to: DataBackup.dir)
        _ = DataNotices.take()
        let failed = DataBackup.runIfNewBuild(build: "H", webKit: webKit, now: t0.addingTimeInterval(600))
        check(failed == nil && text(DataBackup.buildFile) == "G"
              && DataNotices.take().contains { if case .backupFailed = $0 { return true } else { return false } },
              "a failed backup is reported and tried again next launch")
        try? fm.removeItem(at: DataBackup.dir)
    }

    @MainActor
    static func webKitLocations(scratch: URL) {
        let lib = scratch.appendingPathComponent("data-safety-library", isDirectory: true)
        let stores = lib.appendingPathComponent("WebKit/\(AppIdentity.bundleID)/WebsiteDataStore", isDirectory: true)
        let workID = BrowserModel.profileStoreID("Work")
        Paths.ensure(stores.appendingPathComponent(workID.uuidString.lowercased()))
        let saved = BrowserModel.dataStoreID
        BrowserModel.dataStoreID = nil
        let locs = WebKitData.locations(profileNames: ["Work", "work"], library: lib)
        BrowserModel.dataStoreID = saved
        let paths = locs.map { $0.url.path }
        check(paths.contains(lib.appendingPathComponent("WebKit/local.browserpoc/WebsiteData").path)
              && paths.contains(lib.appendingPathComponent("HTTPStorages/local.browserpoc.binarycookies").path),
              "the default profile's site data and cookies are found under the bundle ID")
        check(locs.filter { $0.label.hasPrefix("Profile ") }.map { $0.url.lastPathComponent } == [workID.uuidString.lowercased()],
              "a named profile's store is found once, whatever case WebKit used")
    }
}
