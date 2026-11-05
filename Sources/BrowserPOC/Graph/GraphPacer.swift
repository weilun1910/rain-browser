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

    func presented(_ t: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if phase != nil && t > 0 { times.append(t) }
    }

    func prepared(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if phase != nil { cpu.append(ms) }
    }

    var isMeasuring: Bool {
        lock.lock(); defer { lock.unlock() }
        return phase != nil
    }

    func end() -> Summary {
        lock.lock(); defer { lock.unlock() }
        let name = phase ?? "?"
        phase = nil
        let t = times.sorted()
        var gaps: [Double] = []
        for i in 1..<max(1, t.count) { gaps.append((t[i] - t[i - 1]) * 1000) }
        let budget = 1000 / Double(max(1, refresh))
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let span = t.count > 1 ? t.last! - t.first! : 0
        return Summary(phase: name, frames: t.count, fps: span > 0 ? Double(t.count - 1) / span : 0,
                       meanMS: gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count), p95MS: p95, maxMS: sorted.last ?? 0,
                       dropped: gaps.filter { $0 > budget * 1.5 }.count, refresh: refresh,
                       cpuMeanMS: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count), cpuMaxMS: cpu.max() ?? 0)
    }
}
