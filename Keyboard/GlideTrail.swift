import UIKit

/// The recording shows a rounded, translucent head and a tail that loses width
/// with both distance and age. Time keeps it receding even after the finger stops.
@MainActor
final class GlideTrail {
    private static let radius: CGFloat = 10
    private static let length: CGFloat = 210
    private static let lifetime: TimeInterval = 0.73

    private struct Vertex {
        var point: CGPoint
        var radius: CGFloat

        func toward(_ other: Self, by t: CGFloat) -> Self {
            Self(point: CGPoint(x: point.x + (other.point.x - point.x) * t,
                                y: point.y + (other.point.y - point.y) * t),
                 radius: radius + (other.radius - radius) * t)
        }
    }

    private let shape = CAShapeLayer()
    private var strokes: [GlideStroke] = []
    private var clock: CADisplayLink?

    init() {
        shape.zPosition = 1
        shape.masksToBounds = true
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull()]
    }

    func setAccent(_ accent: UIColor?, traits: UITraitCollection) {
        let opacity: CGFloat = 0.48
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        guard let accent, accent.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            shape.fillColor = UIColor(red: 0.57, green: 0.58, blue: 0.62, alpha: opacity).cgColor
            return
        }
        // Start from a neutral gray so the original trail's cool cast doesn't mask pale accents.
        func blend(_ component: CGFloat) -> CGFloat { 0.58 + 0.4 * (component - 0.58) }
        shape.fillColor = UIColor(red: blend(red), green: blend(green), blue: blend(blue), alpha: opacity).cgColor
    }

    func follow(_ stroke: GlideStroke, in view: UIView) {
        if strokes.last !== stroke { strokes.append(stroke) }
        guard clock == nil else { return }
        shape.frame = view.bounds
        view.layer.addSublayer(shape)
        render(at: CACurrentMediaTime())
        guard !strokes.isEmpty else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        clock = link
    }

    func cancel(_ stroke: GlideStroke) {
        guard let index = strokes.firstIndex(where: { $0 === stroke }) else { return }
        strokes.remove(at: index)
        render(at: CACurrentMediaTime())
    }

    func clear() {
        clock?.invalidate()
        clock = nil
        strokes.removeAll()
        shape.removeFromSuperlayer()
        shape.path = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        render(at: link.targetTimestamp)
    }

    private func render(at now: TimeInterval) {
        strokes.removeAll { stroke in
            guard let last = stroke.samples.last else { return true }
            return now - stroke.startTime - last.seconds >= Self.lifetime
        }
        guard !strokes.isEmpty else { clear(); return }
        let path = CGMutablePath()
        for stroke in strokes { append(stroke, at: now, to: path) }
        shape.path = path
    }

    private func append(_ stroke: GlideStroke, at now: TimeInterval, to path: CGMutablePath) {
        var vertices = [Vertex]()
        var distance: CGFloat = 0
        let elapsed = now - stroke.startTime
        for sample in stroke.samples.reversed() {
            if let last = vertices.last {
                distance += hypot(sample.point.x - last.point.x, sample.point.y - last.point.y)
            }
            let age = max(0, elapsed - sample.seconds)
            let radius = Self.radius * (1 - age / Self.lifetime - distance / Self.length)
            let vertex = Vertex(point: sample.point, radius: radius)
            if radius <= 0 {
                if let last = vertices.last {
                    var tip = last.toward(vertex, by: last.radius / (last.radius - radius))
                    tip.radius = 0
                    vertices.append(tip)
                }
                break
            }
            vertices.append(vertex)
        }
        guard var start = vertices.first, let end = vertices.last else { return }
        // Round changes of direction with a quadratic through successive midpoints.
        for index in vertices.indices.dropFirst().dropLast() {
            let control = vertices[index]
            let midpoint = control.toward(vertices[index + 1], by: 0.5)
            let length = hypot(control.point.x - start.point.x, control.point.y - start.point.y) +
                         hypot(midpoint.point.x - control.point.x, midpoint.point.y - control.point.y)
            let steps = max(1, Int(ceil(length / 4)))
            var previous = start
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let next = start.toward(control, by: t).toward(control.toward(midpoint, by: t), by: t)
                connect(previous, next, in: path)
                previous = next
            }
            start = midpoint
        }
        connect(start, end, in: path)
    }

    /// Fill all round-ended segments as one shape so bends and crossings have
    /// the same translucency as the rest of the trail.
    private func connect(_ a: Vertex, _ b: Vertex, in path: CGMutablePath) {
        let angle = atan2(b.point.y - a.point.y, b.point.x - a.point.x)
        let normal = CGPoint(x: -sin(angle), y: cos(angle))
        path.move(to: CGPoint(x: a.point.x - normal.x * a.radius, y: a.point.y - normal.y * a.radius))
        path.addLine(to: CGPoint(x: b.point.x - normal.x * b.radius, y: b.point.y - normal.y * b.radius))
        if b.radius > 0 {
            path.addArc(center: b.point, radius: b.radius, startAngle: angle - .pi / 2,
                        endAngle: angle + .pi / 2, clockwise: false)
        }
        path.addLine(to: CGPoint(x: a.point.x + normal.x * a.radius, y: a.point.y + normal.y * a.radius))
        path.addArc(center: a.point, radius: a.radius, startAngle: angle + .pi / 2,
                    endAngle: angle + 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
    }
}
