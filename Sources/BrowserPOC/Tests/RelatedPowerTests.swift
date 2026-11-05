import Foundation

/// When Related runs: the power setting and its default, the pause rules, the dwell before the
/// models run, and each gate holding a run back and letting it go.
enum RelatedPowerTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            setting()
            rules()
            gate()
            runs()
            // Leave everything as the other tests expect it.
            RelatedGate.enforced = false
            RelatedGate.firstDwell = 3
            RelatedGate.secondDwell = 10
            RelatedGate.shared.windowVisible = true
            PowerSource.shared.override = nil
            try? FileManager.default.removeItem(at: RelatedPrefs.file)
            RelatedPrefs.shared.reload()
            RelatedGate.shared.update()
        }
    }

    // MARK: The setting

    @MainActor static func setting() {
        check(RelatedPrefsValue().power == .pluggedIn, "Related runs only when plugged in by default")
        let old = try? JSONDecoder().decode(RelatedPrefsValue.self, from: Data("{\"mode\":\"sidebar\",\"shelfHidden\":true}".utf8))
        check(old?.power == .pluggedIn && old?.mode == .sidebar, "a related.json from before the setting gets the default and keeps its mode")
        let odd = try? JSONDecoder().decode(RelatedPrefsValue.self, from: Data("{\"mode\":\"shelf\",\"power\":\"turbo\"}".utf8))
        check(odd?.power == .pluggedIn, "an unknown power value falls back to the default")

        let prefs = RelatedPrefs.shared
        try? FileManager.default.removeItem(at: RelatedPrefs.file)
        prefs.reload()
        for p in RelatedPower.allCases {
            prefs.update { $0.power = p }
            prefs.reload()
            check(prefs.value.power == p, "the \(p.title) setting survives a reload")
        }
        check(RelatedPower.allCases.map(\.title) == ["Only when plugged in", "Always on", "Always off"], "Settings offers the three choices, default first")
    }

    // MARK: Rules

    @MainActor static func rules() {
        typealias G = RelatedGate
        check(G.pause(power: .pluggedIn, onBattery: true, lowPower: false, related: true, window: true) == .battery,
              "the default pauses on battery")
        check(G.pause(power: .pluggedIn, onBattery: false, lowPower: true, related: true, window: true) == .lowPower,
              "the default pauses in Low Power Mode, plugged in or not")
        check(G.pause(power: .pluggedIn, onBattery: false, lowPower: false, related: true, window: true) == nil,
              "the default runs when plugged in")
        check(G.pause(power: .always, onBattery: true, lowPower: true, related: true, window: true) == nil,
              "Always on runs on battery and in Low Power Mode")
        check(G.pause(power: .never, onBattery: false, lowPower: false, related: true, window: true) == .off,
              "Always off never runs, even plugged in")
        check(G.pause(power: .always, onBattery: false, lowPower: false, related: false, window: true) == .hidden,
              "nothing runs while the shelf or panel is hidden")
        check(G.pause(power: .always, onBattery: false, lowPower: false, related: true, window: false) == .windowHidden,
              "nothing runs while the window is out of sight")
        check(G.pause(power: .never, onBattery: true, lowPower: false, related: false, window: false) == .off,
              "the setting's pause wins over the others, so the panel says why")
        check(RelatedPause.battery.isPower && RelatedPause.off.isPower && !RelatedPause.hidden.isPower && !RelatedPause.windowHidden.isPower,
              "only the setting's pauses clear the cards")
    }

    // MARK: The live gate

    @MainActor static func gate() {
        let g = RelatedGate.shared
        let prefs = RelatedPrefs.shared
        prefs.setMode(.shelf)
        prefs.update { $0.shelfHidden = false; $0.power = .pluggedIn }
        PowerSource.shared.override = (onBattery: true, lowPower: false)

        RelatedGate.enforced = false
        g.update()
        check(g.pause == nil, "tests and tours run Related whatever the power source")

        RelatedGate.enforced = true
        g.update()
        check(g.pause == .battery, "the real app pauses Related on battery by default")
        PowerSource.shared.override = (onBattery: false, lowPower: false)
        g.update()
        check(g.pause == nil, "and lets it run once plugged in")
        check(RelatedGate.firstDwellNow == RelatedGate.firstDwell && RelatedGate.secondDwellNow == RelatedGate.secondDwell,
              "the real app waits the dwell before the models run")
    }

    // MARK: Runs

    static func input(_ n: Int) -> ContextInput {
        ContextInput(key: "https://example.com/power-\(n)", title: "Power test page \(n)",
                     text: "A page about sourdough starters, rye flour and cold proofing, number \(n), long enough to count.", kind: .page)
    }

    @MainActor static func runs() {
        let g = RelatedGate.shared
        let prefs = RelatedPrefs.shared
        RelatedGate.enforced = true
        RelatedGate.firstDwell = 0.6
        RelatedGate.secondDwell = 1.2
        g.windowVisible = true
        prefs.update { $0.shelfHidden = false; $0.power = .pluggedIn }
        PowerSource.shared.override = (onBattery: true, lowPower: false)
        g.update()

        let r = Resurfacer()
        // Let index notifications from earlier tests settle, so they don't count as runs here.
        _ = SelfTest.spin(2.5) { false }
        var n = r.retrievalCount

        // On battery with the default setting: nothing runs.
        r.setContext(input(1))
        _ = SelfTest.spin(1.0) { false }
        check(r.retrievalCount == n && r.cards.isEmpty, "on battery the default runs nothing for a new page", "\(n) -> \(r.retrievalCount)")

        // Plugging in runs the page that's open.
        PowerSource.shared.override = (onBattery: false, lowPower: false)
        g.update()
        check(SelfTest.spin(2) { r.retrievalCount == n + 1 }, "plugging in runs the page that's open", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // The dwell: a new page waits before anything runs.
        r.setContext(input(2))
        _ = SelfTest.spin(0.3) { false }
        check(r.retrievalCount == n, "a new page waits for the dwell before the models run", "\(n) -> \(r.retrievalCount)")
        check(SelfTest.spin(1.5) { r.retrievalCount == n + 1 }, "and runs once it has stayed in front", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // A page you only glance at costs nothing.
        r.setContext(input(3))
        _ = SelfTest.spin(0.2) { false }
        r.setContext(input(4))
        _ = SelfTest.spin(1.5) { false }
        check(r.retrievalCount == n + 1 && r.context?.key == input(4).key, "a page left before the dwell never runs", "\(n) -> \(r.retrievalCount)")
        // Reading the same page again while it waits doesn't restart the wait.
        n = r.retrievalCount
        r.setContext(input(5))
        _ = SelfTest.spin(0.4) { false }
        r.setContext(input(5))
        check(SelfTest.spin(0.5) { r.retrievalCount == n + 1 }, "reading the waiting page again keeps its place in the wait", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // Hidden shelf: nothing runs until it shows again.
        prefs.update { $0.shelfHidden = true }
        g.update()
        _ = SelfTest.spin(0.2) { false }
        check(g.pause == .hidden, "hiding the shelf pauses Related")
        r.setContext(input(6))
        _ = SelfTest.spin(1.0) { false }
        check(r.retrievalCount == n, "a page opened while the shelf is hidden doesn't run", "\(n) -> \(r.retrievalCount)")
        prefs.update { $0.shelfHidden = false }
        g.update()
        check(SelfTest.spin(1.5) { r.retrievalCount == n + 1 }, "showing the shelf runs the page that's open", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // Showing it again with nothing owed doesn't rerun.
        prefs.update { $0.shelfHidden = true }
        g.update()
        _ = SelfTest.spin(0.3) { false }
        prefs.update { $0.shelfHidden = false }
        g.update()
        _ = SelfTest.spin(1.0) { false }
        check(r.retrievalCount == n, "hiding and showing a finished page doesn't run it again", "\(n) -> \(r.retrievalCount)")

        // The window out of sight.
        g.windowVisible = false
        _ = SelfTest.spin(0.2) { false }
        check(g.pause == .windowHidden, "a hidden window pauses Related")
        r.setContext(input(7))
        _ = SelfTest.spin(1.0) { false }
        check(r.retrievalCount == n, "a page opened while the window is hidden doesn't run", "\(n) -> \(r.retrievalCount)")
        g.windowVisible = true
        check(SelfTest.spin(1.5) { r.retrievalCount == n + 1 }, "the window coming back runs it", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // Always on runs on battery.
        prefs.update { $0.power = .always }
        PowerSource.shared.override = (onBattery: true, lowPower: false)
        g.update()
        _ = SelfTest.spin(0.2) { false }
        r.setContext(input(8))
        check(SelfTest.spin(1.5) { r.retrievalCount == n + 1 }, "Always on runs on battery", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(2) { !r.isWorking }
        n = r.retrievalCount

        // Always off: nothing runs, nothing shows, even plugged in.
        prefs.update { $0.power = .never }
        PowerSource.shared.override = (onBattery: false, lowPower: false)
        g.update()
        _ = SelfTest.spin(0.3) { false }
        check(g.pause == .off && r.cards.isEmpty, "Always off clears the cards")
        r.setContext(input(9))
        _ = SelfTest.spin(1.0) { false }
        check(r.retrievalCount == n && r.cards.isEmpty, "Always off runs nothing, plugged in or not", "\(n) -> \(r.retrievalCount)")
        // Turning it back on runs the page that's open.
        prefs.update { $0.power = .pluggedIn }
        g.update()
        check(SelfTest.spin(1.5) { r.retrievalCount == n + 1 }, "turning Related back on runs the page that's open", "\(n) -> \(r.retrievalCount)")
        _ = SelfTest.spin(3) { !r.isWorking }
    }
}
