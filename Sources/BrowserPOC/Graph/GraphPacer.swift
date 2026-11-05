import Foundation
import QuartzCore

/// Measures how evenly frames reach the screen: the time between presented frames, from Metal's
/// own presented timestamps, and the main-thread time spent preparing each one.
final class GraphFramePacer: @unchecked Sendable {
    struct Summary: CustomStringConvertible {
        let phase: String
        let frames: Int
        let fps: Double
        let meanMS: Double
        let p95MS: Double
        let maxMS: Double
        /// Frames that took longer than one and a half refresh intervals.
        let dropped: Int
        let refresh: Int
        let cpuMeanMS: Double
        let cpuMaxMS: Double

        var description: String {
            String(format: "%-8@ %4d frames  %5.1f fps  interval mean %5.2f ms  p95 %5.2f ms  max %6.2f ms  dropped %3d (%4.1f%%) at %d Hz  main thread mean %.2f ms  max %.2f ms",
                   phase as NSString, frames, fps, meanMS, p95MS, maxMS, dropped, frames > 1 ? Double(dropped) * 100 / Double(frames - 1) : 0,
                   refresh, cpuMeanMS, cpuMaxMS)
        }
    }

    private let lock = NSLock()
    private var times: [CFTimeInterval] = []
    private var cpu: [Double] = []
    private var phase: String?
    /// The display's refresh rate, set by the view.
    var refresh = 60

    func begin(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        phase = name
        times = []
        cpu = []
    }

    /// Frame times split where the view paused on purpose, so an idle stretch isn't a drop.
    private var breaks: [Int] = []
    private var pauseMarked = false

    func presented(_ t: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard phase != nil && t > 0 else { return }
        if pauseMarked { breaks.append(times.count); pauseMarked = false }
        times.append(t)
    }

    /// The view paused because nothing was moving.
    func markPause() {
        lock.lock(); defer { lock.unlock() }
        if phase != nil { pauseMarked = true }
    }

    func prepared(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if phase != nil { cpu.append(ms) }
    }

    /// Named parts of a frame's main-thread time, for finding where a slow frame went.
    private var parts: [String: [Double]] = [:]
    func part(_ name: String, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if phase != nil { parts[name, default: []].append(ms) }
    }

    func partsSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = parts.keys.sorted().map { k -> String in
            let v = parts[k]!
            return String(format: "%@ mean %.2f max %.2f", k, v.reduce(0, +) / Double(max(1, v.count)), v.max() ?? 0)
        }.joined(separator: ", ")
        parts = [:]
        return s
    }

    var isMeasuring: Bool {
        lock.lock(); defer { lock.unlock() }
        return phase != nil
    }

    func end() -> Summary {
        lock.lock(); defer { lock.unlock() }
        let name = phase ?? "?"
        phase = nil
        let t = times
        let cuts = Set(breaks)
        breaks = []
        pauseMarked = false
        var gaps: [Double] = []
        for i in 1..<max(1, t.count) where !cuts.contains(i) { gaps.append((t[i] - t[i - 1]) * 1000) }
        let budget = 1000 / Double(max(1, refresh))
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let span = gaps.reduce(0, +) / 1000
        return Summary(phase: name, frames: t.count, fps: span > 0 ? Double(gaps.count) / span : 0,
                       meanMS: gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count), p95MS: p95, maxMS: sorted.last ?? 0,
                       dropped: gaps.filter { $0 > budget * 1.5 }.count, refresh: refresh,
                       cpuMeanMS: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count), cpuMaxMS: cpu.max() ?? 0)
    }
}
