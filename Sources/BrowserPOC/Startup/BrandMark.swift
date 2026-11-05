import AppKit
import SwiftUI

/// The app's mark: one open loop and a dot. The stroke starts with a faded tail at the lower left,
/// sweeps up and around clockwise, and curls back in to stop at a dot just inside the gap.
/// Something you saw comes back around and settles. It's plain geometry, so it's crisp at any
/// size and can be drawn on.
enum MarkGeometry {
    /// Clock angles in degrees, clockwise from 12 o'clock.
    static let startAngle: Double = 212
    static let sweep: Double = 290
    /// The last part of the sweep where the loop turns slightly inward, toward the centre.
    static let curl: Double = 84
    /// The loop's radius and how far in the curl ends, as shares of the box.
    static let radius: Double = 0.40
    static let curlRadius: Double = 0.84
    /// Where the faded tail becomes fully drawn, as a share of the sweep.
    static let tailFade: Double = 0.16
    /// Default stroke weight as a share of the box, and the dot's size relative to the stroke.
    static let weight: CGFloat = 0.064
    static let dotScale: CGFloat = 2.15
    /// Nudges the whole loop so it looks centred: the open gap at the bottom makes it feel low.
    static let opticalOffset = CGPoint(x: -0.01, y: 0.02)

    /// A point on the loop at `t` from 0 (tail) to 1 (dot), in a unit box with y going down.
    static func point(_ t: Double) -> CGPoint {
        let angle = startAngle + sweep * t
        let curlStart = (sweep - curl) / sweep
        var r = radius
        if t > curlStart {
            let u = (t - curlStart) / (1 - curlStart)
            let eased = u * u * (3 - 2 * u)
            r = radius * (1 - (1 - curlRadius) * eased)
        }
        let a = angle * .pi / 180
        return CGPoint(x: 0.5 + r * sin(a) + opticalOffset.x, y: 0.5 - r * cos(a) + opticalOffset.y)
    }

    static func path(in rect: CGRect, samples: Int = 180) -> Path {
        var p = Path()
        for i in 0...samples {
            let u = point(Double(i) / Double(samples))
            let q = CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }

    static func end(in rect: CGRect) -> CGPoint {
        let u = point(1)
        return CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
    }

    /// The angular gradient's start, in SwiftUI's angle space (0 at 3 o'clock, clockwise).
    static var gradientStart: Angle { .degrees(startAngle - 90 - 2) }
}

struct MarkLoop: Shape {
    func path(in rect: CGRect) -> Path { MarkGeometry.path(in: rect) }
}

/// The loop as a filled ribbon instead of an even stroke: thin at the tail, swelling to full
/// weight, with a round head. Drawn up to `progress`, so the startup can draw it like a brush
/// stroke. An even-width arc drawing on reads as a spinner; a tapering one reads as a gesture.
struct MarkRibbon: Shape {
    var progress: Double = 1
    let lineWidth: CGFloat
    /// Width at the very start of the tail, as a share of the full weight, and how far along
    /// the loop it takes to reach full weight.
    static let taperStart: CGFloat = 0.28
    static let taperLength: Double = 0.34

    static func width(at t: Double, _ lw: CGFloat) -> CGFloat {
        let u = min(1, max(0, t / taperLength))
        let eased = u * u * (3 - 2 * u)
        return lw * (taperStart + (1 - taperStart) * CGFloat(eased))
    }

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        guard p > 0.002 else { return Path() }
        let n = max(4, Int(220 * p))
        func at(_ t: Double) -> CGPoint {
            let u = MarkGeometry.point(t)
            return CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
        }
        var pts: [CGPoint] = [], halves: [CGFloat] = []
        for i in 0...n {
            let t = p * Double(i) / Double(n)
            pts.append(at(t))
            halves.append(Self.width(at: t, lineWidth) / 2)
        }
        var left: [CGPoint] = [], right: [CGPoint] = [], normals: [CGFloat] = []
        for i in 0...n {
            let a = pts[max(0, i - 1)], b = pts[min(n, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, hypot(dx, dy))
            let nx = -dy / len, ny = dx / len
            normals.append(atan2(ny, nx))
            left.append(CGPoint(x: pts[i].x + nx * halves[i], y: pts[i].y + ny * halves[i]))
            right.append(CGPoint(x: pts[i].x - nx * halves[i], y: pts[i].y - ny * halves[i]))
        }
        var path = Path()
        path.move(to: left[0])
        for q in left.dropFirst() { path.addLine(to: q) }
        // Round head: around the front, from the left edge to the right edge.
        let steps = 10
        for k in 1..<steps {
            let ang = normals[n] - .pi * CGFloat(k) / CGFloat(steps)
            path.addLine(to: CGPoint(x: pts[n].x + cos(ang) * halves[n], y: pts[n].y + sin(ang) * halves[n]))
        }
        for q in right.reversed() { path.addLine(to: q) }
        // Round tail: around the back, from the right edge to the left edge.
        for k in 1..<steps {
            let ang = normals[0] + .pi - .pi * CGFloat(k) / CGFloat(steps)
            path.addLine(to: CGPoint(x: pts[0].x + cos(ang) * halves[0], y: pts[0].y + sin(ang) * halves[0]))
        }
        path.closeSubpath()
        return path
    }
}

/// The app's name, Rain, set in New York with a little air between the letters.
/// A wordmark for the launch, the About panel and the first run. Not an identifier.
struct Wordmark: View {
    static let name = "Rain"
    var size: CGFloat = 18
    var body: some View {
        Text(Self.name)
            .font(.system(size: size, weight: .regular, design: .serif))
            .tracking(size * 0.06)
            .foregroundStyle(.primary.opacity(0.85))
            .accessibilityLabel(Self.name)
    }
}

/// The mark. `draw` runs the stroke from 0 to 1 and `dot` brings the dot in, so the startup
/// can animate it. Both default to 1 for the static mark.
struct BrandMark: View {
    var draw: Double = 1
    var dot: Double = 1
    var weight: CGFloat = MarkGeometry.weight
    /// A floor on the stroke in points, so the mark stays visible at tiny sizes.
    var minLine: CGFloat = 0
    /// Use an opaque colour and set `opacity` instead, so overlaps stay clean.
    var color: Color = .primary
    var opacity: Double = 1

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let box = CGRect(x: (g.size.width - s) / 2, y: (g.size.height - s) / 2, width: s, height: s)
            let lw = max(minLine, s * weight)
            let fade = MarkGeometry.tailFade * MarkGeometry.sweep / 360
            let endAt = MarkGeometry.sweep / 360
            // Clear again past the end, so the round cap at the tail (which reaches back behind
            // the start angle) never picks up the opaque end of the gradient.
            let tail = AngularGradient(stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0.35), location: fade * 0.45),
                .init(color: color, location: fade),
                .init(color: color, location: endAt + 0.06),
                .init(color: color.opacity(0), location: endAt + 0.10),
                .init(color: color.opacity(0), location: 1),
            ], center: UnitPoint(x: 0.5 + MarkGeometry.opticalOffset.x, y: 0.5 + MarkGeometry.opticalOffset.y),
               startAngle: MarkGeometry.gradientStart, endAngle: MarkGeometry.gradientStart + .degrees(360))
            let end = MarkGeometry.end(in: box)
            let d = lw * MarkGeometry.dotScale
            let landing = min(1, max(0, dot))
            ZStack {
                MarkRibbon(progress: draw, lineWidth: lw)
                    .fill(tail)
                    .frame(width: s, height: s)
                    .position(x: box.midX, y: box.midY)
                // The dot lands last, like a drop: it arrives a little large and settles to size.
                Circle()
                    .fill(color)
                    .frame(width: d, height: d)
                    .scaleEffect(1 + 0.4 * (1 - landing))
                    .opacity(min(1, landing * 2.2))
                    .position(end)
            }
            // Flatten before any opacity is applied, so the dot and the stroke's end don't double up.
            .compositingGroup()
        }
        .opacity(opacity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
