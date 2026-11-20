import Foundation
import DockKitCore

private let degree = Double.pi / 180

func checkAngleLimits() async throws {
    let limits = (-30 * degree, 40 * degree)   // order does not matter
    // Free inside, both directions.
    try expectEqual(AngleLimits.clampYaw(velocity: 0.2, yaw: 0, limits: limits), 0.2)
    try expectEqual(AngleLimits.clampYaw(velocity: -0.2, yaw: 0, limits: (limits.1, limits.0)), -0.2)
    // Soft zone: half way through the 5° zone gives half the outward speed.
    try expectTrue(abs(AngleLimits.clampYaw(velocity: 0.2, yaw: 37.5 * degree, limits: limits) - 0.1) < 1e-9)
    try expectTrue(abs(AngleLimits.clampYaw(velocity: -0.2, yaw: -27.5 * degree, limits: limits) + 0.1) < 1e-9)
    // At or beyond a limit: zero outward, inward untouched.
    try expectEqual(AngleLimits.clampYaw(velocity: 0.2, yaw: 40 * degree, limits: limits), 0)
    try expectEqual(AngleLimits.clampYaw(velocity: 0.2, yaw: 55 * degree, limits: limits), 0)
    try expectEqual(AngleLimits.clampYaw(velocity: -0.2, yaw: 55 * degree, limits: limits), -0.2)
    try expectEqual(AngleLimits.clampYaw(velocity: -0.2, yaw: -31 * degree, limits: limits), 0)
    try expectEqual(AngleLimits.clampYaw(velocity: 0.2, yaw: -31 * degree, limits: limits), 0.2)
    // Invalid input never moves.
    try expectEqual(AngleLimits.clampYaw(velocity: .nan, yaw: 0, limits: limits), 0)
    try expectEqual(AngleLimits.clampYaw(velocity: 0.2, yaw: .infinity, limits: limits), 0)
    // Low tilt limit, both sign conventions; going back up is free.
    try expectEqual(AngleLimits.clampPitch(velocity: -0.1, pitch: -20 * degree, lowLimit: -20 * degree, downSign: -1), 0)
    try expectEqual(AngleLimits.clampPitch(velocity: 0.1, pitch: -20 * degree, lowLimit: -20 * degree, downSign: -1), 0.1)
    try expectEqual(AngleLimits.clampPitch(velocity: 0.1, pitch: 21 * degree, lowLimit: 20 * degree, downSign: 1), 0)
    try expectEqual(AngleLimits.clampPitch(velocity: -0.1, pitch: 21 * degree, lowLimit: 20 * degree, downSign: 1), -0.1)
    // A simulated pan toward the limit decelerates and never overshoots it.
    var yaw = 0.0
    var previous = 0.3
    for _ in 0..<400 {
        let v = AngleLimits.clampYaw(velocity: 0.3, yaw: yaw, limits: limits)
        try expectTrue(v <= previous + 1e-12)
        previous = v; yaw += v * 0.033
    }
    try expectTrue(yaw <= 40 * degree + 1e-9 && yaw > 39 * degree)
}

/// Simulates the camera: a world point (base-frame units, centre 0.5) is seen at
/// 0.5 + offset * zoom in the zoomed frame, as the detector reports it.
private func seen(_ world: HybridVector, _ zoom: Double, view: HybridVector = HybridVector(1, 1)) -> HybridVector {
    HybridVector(0.5 + (world.x - 0.5) / view.x * zoom, 0.5 + (world.y - 0.5) / view.y * zoom)
}

func checkAutoZoomRatesAndWaits() async throws {
    // Python test_dynamic_waits_and_respects_asymmetric_rate_limits.
    var zoom = AutoZoomPolicy(maximum: 3)
    var previous = 1.0, value = 1.0
    for i in 0..<50 {
        value = zoom.step(timestamp: Double(i) / 10, ball: HybridVector(0.5, 0.5), feet: [], focus: nil)
        try expectTrue(log(value / previous) <= 0.012 + 1e-8)
        if i < 8 { try expectEqual(value, 1) }
        previous = value
    }
    try expectTrue(value > 1.5)
    for i in 50..<75 {
        value = zoom.step(timestamp: Double(i) / 10, ball: nil, feet: [], focus: nil)
        try expectTrue(log(value / previous) >= -0.04 - 1e-8)
        previous = value
    }
    try expectTrue(abs(value - 1) < 1e-9)

    // Brief loss holds (<= 0.35 s), then widening starts.
    zoom = AutoZoomPolicy(maximum: 2)
    for i in 0..<40 { zoom.step(timestamp: Double(i) / 10, ball: HybridVector(0.5, 0.5), feet: [], focus: nil) }
    let held = zoom.zoom
    try expectTrue(held > 1.2)
    for i in 40..<43 { try expectEqual(zoom.step(timestamp: Double(i) / 10, ball: nil, feet: [], focus: nil), held) }
    try expectTrue(zoom.step(timestamp: 4.4, ball: nil, feet: [], focus: nil) < held)

    // Invalid parameters and timestamps never start or jump (Python raises instead).
    try expectEqual(AutoZoomPolicy(maximum: .nan).maximum, 1)
    try expectEqual(AutoZoomPolicy(maximum: 4).maximum, 3)
    try expectEqual(AutoZoomPolicy(maximum: 0).maximum, 1)
    zoom = AutoZoomPolicy(maximum: 2)
    zoom.step(timestamp: 1, ball: HybridVector(0.5, 0.5), feet: [], focus: nil)
    for t in [Double.nan, 1, 0.5, 9] { try expectEqual(zoom.step(timestamp: t, ball: HybridVector(0.5, 0.5), feet: [], focus: nil), 1) }
}

func checkAutoZoomPlayersAndFeedback() async throws {
    // Python test_unseen_people_cannot_cause_zoom: feet at world 0.9 with view 0.4 are outside.
    var zoom = AutoZoomPolicy(maximum: 3)
    let view = HybridVector(0.4, 0.4)
    for i in 0..<30 {
        let foot = seen(HybridVector(0.9, 0.5), zoom.zoom, view: view)
        zoom.step(timestamp: Double(i) / 10, ball: nil, feet: Array(repeating: foot, count: 20), focus: foot)
    }
    try expectEqual(zoom.zoom, 1)

    // Python test_compact_visible_group_can_probe_a_tighter_view_without_a_ball.
    zoom = AutoZoomPolicy(maximum: 2)
    for i in 0..<70 {
        let feet = [0.49, 0.5, 0.51].map { seen(HybridVector($0, 0.5), zoom.zoom, view: view) }
        zoom.step(timestamp: Double(i) / 10, ball: nil, feet: feet, focus: HybridVector(0.5, 0.5))
    }
    try expectTrue(zoom.zoom > 1.8 && zoom.zoom <= 2)

    // Python test_offcenter_visible_action_does_not_deadlock_zoom_and_tilt.
    zoom = AutoZoomPolicy(maximum: 2.5)
    let tall = HybridVector(0.45, 0.96)
    for i in 0..<40 {
        let feet = [0.49, 0.5, 0.51].map { seen(HybridVector($0, 0.25), zoom.zoom, view: tall) }
        zoom.step(timestamp: Double(i) / 10, ball: nil, feet: feet, focus: seen(HybridVector(0.5, 0.25), zoom.zoom, view: tall))
    }
    try expectTrue(zoom.zoom > 1.4)

    // Feedback: a fixed off-centre ball, re-measured in the zoomed frame each step, converges
    // monotonically to the fixed point (0.4 z + 0.45 = 1, z = 1.375) and stays in frame.
    zoom = AutoZoomPolicy(maximum: 2)
    var previous = 1.0
    for i in 0..<300 {
        let ball = seen(HybridVector(0.7, 0.5), zoom.zoom)
        try expectTrue(ball.x <= 1)
        let value = zoom.step(timestamp: Double(i) / 30, ball: ball, feet: [], focus: nil)
        try expectTrue(value >= previous - 1e-12)
        previous = value
    }
    try expectTrue(abs(zoom.zoom - 1.375) < 0.02)
}

func checkHighlightDetector() async throws {
    // Fast ball: 1.2 frame/s sustained for > 0.5 s gives one marker; rate limited to 8 s.
    var detector = HighlightDetector()
    var markers: [(Double, HighlightMarker.Kind)] = []
    for i in 0..<600 {   // 20 s at 30 Hz, the ball going back and forth at 1.2 frame/s
        let t = Double(i) / 30
        let phase = (t * 1.2).truncatingRemainder(dividingBy: 1.6)
        let x = 0.1 + (phase <= 0.8 ? phase : 1.6 - phase)
        if let kind = detector.update(timestamp: t, ball: HybridVector(x, 0.5)) { markers.append((t, kind)) }
    }
    try expectTrue(!markers.isEmpty && markers.allSatisfy { $0.1 == .fastBall })
    for pair in zip(markers, markers.dropFirst()) { try expectTrue(pair.1.0 - pair.0.0 >= 8) }
    // A slow ball never marks; nor does a jittering one beyond the jump guard.
    detector = HighlightDetector()
    for i in 0..<300 {
        let t = Double(i) / 30
        try expectTrue(detector.update(timestamp: t, ball: HybridVector(0.5 + 0.1 * t / 10, 0.5)) == nil)
    }
    detector = HighlightDetector()
    for i in 0..<300 {
        try expectTrue(detector.update(timestamp: Double(i) / 30, ball: HybridVector(i % 2 == 0 ? 0.1 : 0.9, 0.5)) == nil)
    }
    // Reacquired after >= 3 s of loss; not after a short loss, not on the first ever track.
    detector = HighlightDetector()
    try expectTrue(detector.update(timestamp: 0, ball: HybridVector(0.5, 0.5)) == nil)
    try expectTrue(detector.update(timestamp: 2, ball: HybridVector(0.5, 0.5)) == nil)
    try expectTrue(detector.update(timestamp: 3, ball: nil) == nil)
    try expectEqual(detector.update(timestamp: 5.5, ball: HybridVector(0.5, 0.5)), .ballReacquired)
    try expectTrue(detector.update(timestamp: 9, ball: HybridVector(0.5, 0.5)) == nil)    // 3.5 s loss but < 8 s since marker
    try expectEqual(detector.update(timestamp: 14, ball: HybridVector(0.5, 0.5)), .ballReacquired)
    let marker = HighlightMarker(time: 12.5, kind: .manual)
    let json = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
    try expectTrue(json.contains("\"kind\":\"manual\"") && json.contains("Moment marqué"))
}
