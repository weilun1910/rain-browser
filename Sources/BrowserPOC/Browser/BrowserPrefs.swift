import Foundation

/// Browsing settings for the Arc and Zen behaviour. Kept in their own `browser.json`, apart from
/// `settings.json`, so they never collide with the index and model settings.
struct BrowserPrefsValue: Codable, Equatable {
    /// Hours before an idle Today tab moves to the archive. 0 means never.
    var archiveAfterHours: Double = 12
    /// Links to other sites from pinned tabs and Essentials open in Peek, like Arc.
    var peekForPinnedLinks: Bool = true
    /// Links opened from other apps open in a small window, like Little Arc.
    var littleArc: Bool = true
    /// Picture in picture when you leave a tab with a playing video.
    var autoPictureInPicture: Bool = true
    /// Compact mode: the sidebar hides and slides in from the edge.
    var sidebarHidden: Bool = false
    /// Tabs on the right, like Zen.
    var sidebarOnRight: Bool = false
    /// How often each command bar action was picked or passed over, from -5 to 5, like Zen's learner.
    var actionScores: [String: Int] = [:]

    static let archiveChoices: [(String, Double)] = [("12 hours", 12), ("24 hours", 24), ("7 days", 24 * 7), ("30 days", 24 * 30), ("Never", 0)]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrowserPrefsValue()
        archiveAfterHours = try c.decodeIfPresent(Double.self, forKey: .archiveAfterHours) ?? d.archiveAfterHours
        peekForPinnedLinks = try c.decodeIfPresent(Bool.self, forKey: .peekForPinnedLinks) ?? d.peekForPinnedLinks
        littleArc = try c.decodeIfPresent(Bool.self, forKey: .littleArc) ?? d.littleArc
        autoPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .autoPictureInPicture) ?? d.autoPictureInPicture
        sidebarHidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? d.sidebarHidden
        sidebarOnRight = try c.decodeIfPresent(Bool.self, forKey: .sidebarOnRight) ?? d.sidebarOnRight
        actionScores = try c.decodeIfPresent([String: Int].self, forKey: .actionScores) ?? [:]
    }
}

@MainActor
final class BrowserPrefs: ObservableObject {
    static let shared = BrowserPrefs()
    @Published private(set) var value = BrowserPrefsValue()

    static var file: URL { Paths.root.appendingPathComponent("browser.json") }

    private init() { reload() }

    /// Reads the file again. Tests call this after pointing Paths at a throwaway folder.
    func reload() {
        if let v = SavedFile.read(BrowserPrefsValue.self, from: Self.file, label: "browser preferences") {
            value = v
        } else {
            value = BrowserPrefsValue()
        }
    }

    func update(_ change: (inout BrowserPrefsValue) -> Void) {
        var v = value
        change(&v)
        guard v != value else { return }
        value = v
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(v) { SavedFile.write(data, to: Self.file) }
    }
}
