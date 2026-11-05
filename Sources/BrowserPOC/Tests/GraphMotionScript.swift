import AppKit
import QuartzCore

/// With `BROWSERPOC_GRAPH_SCRIPT=1`, the global graph drives itself through hover, pan, zoom,
/// drag, focus, filter and fit, measures frame pacing for each, prints the numbers and quits.
/// For real-window runs on a throwaway `--data-dir` profile, recorded with screencapture.
@MainActor
final class GraphMotionScript {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["BROWSERPOC_GRAPH_SCRIPT"] != nil }
    private static var running: GraphMotionScript?

    struct Phase {
        let name: String
        let duration: Double
        var setup: () -> Void = {}
        var step: (Double) -> Void = { _ in }
        var finish: () -> Void = {}
    }

    private let c: GraphController
    private weak var view: GraphMetalView?
    private var phases: [Phase] = []
    private var index = -1
    private var phaseStart = CACurrentMediaTime()
    private var timer: Timer?
    private var results: [GraphFramePacer.Summary] = []

    static func start(_ c: GraphController, view: GraphMetalView) {
        guard isRequested, running == nil else { return }
        let s = GraphMotionScript(c, view: view)
        running = s
        // A delay in seconds leaves time to start a screen recording.
        let delay = Double(ProcessInfo.processInfo.environment["BROWSERPOC_GRAPH_SCRIPT"] ?? "") ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { s.waitForLoad(tries: 0) }
    }

    private init(_ c: GraphController, view: GraphMetalView) {
        self.c = c
        self.view = view
    }

    private func waitForLoad(tries: Int) {
        if c.hasLoaded && !c.layout.nodes.isEmpty || tries > 100 {
            build()
            next()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForLoad(tries: tries + 1) }
    }

    private var size: CGSize { view?.bounds.size ?? CGSize(width: 900, height: 700) }

    private func hubs(_ n: Int) -> [Int] {
        c.layout.nodes.indices.sorted { c.layout.nodes[$0].degree > c.layout.nodes[$1].degree }.prefix(n).map { $0 }
    }

    private func screenOf(_ i: Int) -> CGPoint {
        let p = c.sim.positions()
        guard let v = view, i < p.count else { return .zero }
        return c.screen(p[i], in: v)
    }

    private func build() {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        var hoverPath: [CGPoint] = []
        phases = [
            Phase(name: "settle", duration: 5),
            Phase(name: "hover", duration: 3, setup: { [unowned self] in
                hoverPath = hubs(24).map(screenOf)
            }, step: { [unowned self] t in
                guard hoverPath.count > 1, let v = view else { return }
                // Glide the pointer from node to node.
                let f = t / 3 * Double(hoverPath.count - 1)
                let i = min(hoverPath.count - 2, Int(f)), k = CGFloat(f - Double(i))
                let a = hoverPath[i], b = hoverPath[i + 1]
                c.pointerMoved(CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), in: v)
            }, finish: { [unowned self] in if let v = view { c.pointerExited(in: v) } }),
            Phase(name: "pan", duration: 2, step: { [unowned self] t in
                guard let v = view else { return }
                let speed = sin(t / 2 * .pi) * 9
                c.pan(Float(cos(t * 2.2) * speed), Float(sin(t * 1.7) * speed), in: v)
            }),
            Phase(name: "zoom", duration: 2.4, step: { [unowned self] t in
                guard let v = view else { return }
                let f = t < 1.2 ? exp(0.012) : exp(-0.012)
                c.zoom(by: Float(f), at: CGPoint(x: mid.x + 80, y: mid.y - 40), in: v)
            }),
            Phase(name: "drag", duration: 2.6, setup: { [unowned self] in
                guard let v = view, let h = hubs(1).first else { return }
                c.pointerDown(screenOf(h), in: v)
            }, step: { [unowned self] t in
                guard let v = view, let h = hubs(1).first, t < 2 else { return }
                let o = screenOf(h)
                let p = CGPoint(x: mid.x + cos(t * 3) * 110, y: mid.y + sin(t * 3) * 80)
                c.pointerDragged(t < 0.05 ? o : p, in: v)
            }, finish: { [unowned self] in
                guard let v = view else { return }
                c.pointerUp(mid, modifiers: [], in: v)
            }),
            Phase(name: "focus", duration: 2, setup: { [unowned self] in
                guard let v = view, let h = hubs(3).last else { return }
                c.focusClick(h, in: v)
            }),
            Phase(name: "filter", duration: 2.2, setup: {
                GraphSettingsStore.shared.value.search = "swapshelf"
            }, step: { t in
                if t > 1.1 && !GraphSettingsStore.shared.value.search.isEmpty { GraphSettingsStore.shared.value.search = "" }
            }),
            Phase(name: "fit", duration: 1.6, setup: { [unowned self] in
                if let v = view { c.clearSelection(in: v); c.fit(in: v) }
            }),
        ]
    }

    private func next() {
        if index >= 0 {
            phases[index].finish()
            results.append(c.pacer.end())
        }
        index += 1
        guard index < phases.count else { done(); return }
        c.pacer.refresh = view?.window?.screen?.maximumFramesPerSecond ?? 60
        c.pacer.begin(phases[index].name)
        phases[index].setup()
        c.wakeAll()
        phaseStart = CACurrentMediaTime()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let t = CACurrentMediaTime() - phaseStart
        let p = phases[index]
        if t >= p.duration { next(); return }
        p.step(t)
    }

    private func done() {
        timer?.invalidate()
        let refresh = view?.window?.screen?.maximumFramesPerSecond ?? 0
        print("graph motion script: display \(refresh) Hz, view asks for \(view?.preferredFramesPerSecond ?? 0) fps, \(c.layout.nodes.count) nodes, \(c.layout.edges.count) lines")
        for r in results { print("pacing " + r.description) }
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}
