import Foundation

/// Port of experiments/camera_imitation/zoom_policy.py (dynamic mode): slow tightening on a
/// continuous reliable ball, hold on brief loss, fast widening when lost, cautious framing of
/// the visible player group otherwise, 0.8 s stability wait, rate limit in log-zoom.
///
/// `zoom` is relative to the user's wide base (1 ... maximum). All inputs are normalised in the
/// CURRENT zoomed frame (centre 0.5, frame size 1). The Python version works in world coordinates
/// and divides by `view = base_view / zoom`; here the measurement is already in view units, so
/// a framing extent `e` (fraction of the current frame) gives target = zoom / e. Zooming in grows
/// the measured offsets by the same factor, which is a stable fixed point (e = 1), not a loop.
public struct AutoZoomPolicy: Sendable {
    public let maximum: Double
    public private(set) var zoom = 1.0
    public private(set) var reason = "recherche large"
    private var previousTime: Double?
    private var stableSince: Double?
    private var lastBall = -Double.infinity

    public init(maximum: Double = 2) {
        self.maximum = maximum.isFinite ? min(3, max(1, maximum)) : 1
    }
    public mutating func reset() { self = Self(maximum: maximum) }

    /// - Parameters:
    ///   - ball: confirmed, measured, reliable (>= 0.7) ball in the current frame, else nil.
    ///   - feet: player feet in the current frame (only those inside the frame vote).
    ///   - focus: where the pan/tilt planner is heading, in the current frame.
    @discardableResult
    public mutating func step(timestamp: Double, ball: HybridVector?, feet: [HybridVector],
                              focus: HybridVector?) -> Double {
        guard timestamp.isFinite else { return zoom }
        let dt = previousTime.map { timestamp - $0 } ?? 0.1
        guard dt > 0 else { return zoom }
        previousTime = timestamp
        // A gap restarts timing only; the next frames decide from fresh evidence.
        guard dt <= 1 else { stableSince = nil; return zoom }
        var target = 1.0, why = "recherche large"
        if let ball, ball.finite {
            lastBall = timestamp
            let extent = max(2 * abs(ball.x - 0.5), 2 * abs(ball.y - 0.5)) + 0.45
            target = zoom / extent
            why = "ballon continu : resserrer"
        } else if timestamp - lastBall <= 0.35 {
            target = zoom; why = "brève perte : tenir le zoom"
        } else if timestamp - lastBall < 1.8 {
            why = "ballon perdu : élargir"
        } else if let focus, focus.finite {
            let visible = feet.filter { $0.finite && abs($0.x - 0.5) <= 0.5 + 1e-8 && abs($0.y - 0.5) <= 0.5 + 1e-8 }
            if visible.count >= 3 {
                let count = max(3, Int((Double(visible.count) * 0.6).rounded(.up)))
                let group = visible.sorted { ($0 - focus).length < ($1 - focus).length }.prefix(count)
                let ex = 2 * group.map { abs($0.x - focus.x) }.max()! + 0.20
                let ey = 2 * group.map { abs($0.y - focus.y) }.max()! + 0.35
                target = zoom / max(0.001, ex, ey)
                why = "groupe visible : cadrage prudent"
            }
        }
        target = min(maximum, max(1, target))
        if target > zoom * 1.08 {
            if stableSince == nil { stableSince = timestamp }
            if timestamp - stableSince! < 0.8 { target = zoom; why = "attendre un cadrage stable" }
        } else { stableSince = nil }
        let rate = target > zoom ? 0.12 : 0.4
        let logStep = max(-rate * dt, min(rate * dt, log(target / zoom)))
        zoom = min(maximum, max(1, zoom * exp(logStep)))
        reason = why
        return zoom
    }
}
