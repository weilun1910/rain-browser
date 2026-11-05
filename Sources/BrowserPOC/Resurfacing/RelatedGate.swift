import AppKit
import Combine
import Foundation
import IOKit.ps

// When Related is allowed to run its models. Every new page costs the reranker several seconds
// of GPU, and Apple's model more on top, so the real app holds Related back when nobody can see
// it, until a page has been in front for a moment, and on battery by default.
// Measurements are in notes/research/2026-11-05-related-energy.md.

/// The setting in Settings, General.
enum RelatedPower: String, Codable, CaseIterable {
    /// The default: off on battery or in Low Power Mode, on when plugged in.
    case pluggedIn
    case always
    case never

    var title: String {
        switch self {
        case .pluggedIn: return "Only when plugged in"
        case .always: return "Always on"
        case .never: return "Always off"
        }
    }

    /// Whether this setting lets Related run on the power the Mac has right now.
    func allows(onBattery: Bool, lowPower: Bool) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        case .pluggedIn: return !onBattery && !lowPower
        }
    }
}

/// Whether the Mac runs on battery, and whether Low Power Mode is on. Updates when either changes.
@MainActor
final class PowerSource: ObservableObject {
    static let shared = PowerSource()
    @Published private(set) var onBattery = false
    @Published private(set) var lowPower = false
    /// Tests stand in for the real power source with this.
    var override: (onBattery: Bool, lowPower: Bool)? { didSet { refresh() } }
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PowerSource.shared.refresh() } }
        }
        if let s = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerSource.shared.refresh() }
        }
    }

    func refresh() {
        let battery = override?.onBattery ?? Self.readOnBattery()
        let low = override?.lowPower ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        if battery != onBattery { onBattery = battery }
        if low != lowPower { lowPower = low }
    }

    /// A desktop Mac reports AC power, so it never counts as on battery.
    nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// Why Related isn't running right now.
enum RelatedPause: Equatable {
    /// The default setting, on battery.
    case battery
    /// The default setting, in Low Power Mode.
    case lowPower
    /// Set to Always off.
    case off
    /// The shelf or the side panel is hidden.
    case hidden
    /// Rain's window is minimised, hidden or covered.
    case windowHidden

    /// Pauses that come from the setting. Related shows nothing during these. The others only
    /// wait, since nobody can see the cards anyway.
    var isPower: Bool { self == .battery || self == .lowPower || self == .off }

    var title: String { self == .off ? "Related is off" : "Related is paused" }

    var detail: String {
        switch self {
        case .battery: return "It runs only when your Mac is plugged in. You can change that in Settings, under General."
        case .lowPower: return "Low Power Mode is on, so it waits until that's off. You can change that in Settings, under General."
        case .off: return "Turn it back on in Settings, under General."
        case .hidden, .windowHidden: return ""
        }
    }

    /// The line under the setting, and the toast when you show Related while it's paused.
    var short: String {
        switch self {
        case .battery: return "Related is paused while your Mac is on battery"
        case .lowPower: return "Related is paused while Low Power Mode is on"
        case .off: return "Related is off"
        case .hidden, .windowHidden: return ""
        }
    }
}

/// Puts the setting, the power source, whether Related is on screen and whether the window is
/// visible together into one answer: may Related run now, and if not, why.
@MainActor
final class RelatedGate: ObservableObject {
    static let shared = RelatedGate()

    /// Only the real app holds Related to the gate and the dwell. Tests, tours and demos run it
    /// freely unless a test turns this on.
    static var enforced = false
    /// How long a page or note stays in front before the reranker runs.
    static var firstDwell: TimeInterval = 3
    /// How long before Apple's model describes what you're doing and Related searches again.
    static var secondDwell: TimeInterval = 10

    static var firstDwellNow: TimeInterval { enforced ? firstDwell : 0 }
    static var secondDwellNow: TimeInterval { enforced ? secondDwell : 0 }

    @Published private(set) var pause: RelatedPause?
    var canRun: Bool { pause == nil }

    /// Whether Rain's main window shows on screen. Tests set it by hand.
    var windowVisible = true { didSet { if windowVisible != oldValue { update() } } }

    private var subs: Set<AnyCancellable> = []
    private var occlusion: NSObjectProtocol?
    private var started = false
    private var wasVisible = true

    private init() {}

    /// Starts watching. Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        // @Published sends before the value changes, so read the new state on the next turn.
        let later: (Any) -> Void = { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } } }
        RelatedPrefs.shared.$value.sink(receiveValue: later).store(in: &subs)
        Settings.shared.$published.sink(receiveValue: later).store(in: &subs)
        PowerSource.shared.$onBattery.sink(receiveValue: later).store(in: &subs)
        PowerSource.shared.$lowPower.sink(receiveValue: later).store(in: &subs)
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow, w === AppDelegate.shared?.window else { return }
                RelatedGate.shared.windowVisible = w.occlusionState.contains(.visible)
            }
        }
        update()
    }

    /// The pause, from the current state of everything it depends on.
    static func pause(power: RelatedPower, onBattery: Bool, lowPower: Bool, related visible: Bool, window: Bool) -> RelatedPause? {
        if power == .never { return .off }
        if !power.allows(onBattery: onBattery, lowPower: lowPower) { return onBattery ? .battery : .lowPower }
        if !visible { return .hidden }
        if !window { return .windowHidden }
        return nil
    }

    func update() {
        let prefs = RelatedPrefs.shared
        let visible = prefs.isVisible
        defer { wasVisible = visible }
        guard Self.enforced else {
            if pause != nil { pause = nil }
            return
        }
        let p = Self.pause(power: prefs.value.power, onBattery: PowerSource.shared.onBattery, lowPower: PowerSource.shared.lowPower,
                           related: visible, window: windowVisible)
        if p != pause { pause = p }
        // Showing Related while the setting has it paused gets a word on why it stays empty.
        if visible, !wasVisible, let p, p.isPower { AppDelegate.shared?.model?.toast(p.short) }
    }
}
