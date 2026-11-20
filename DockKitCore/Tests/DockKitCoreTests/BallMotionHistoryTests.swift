import Foundation
import DockKitCore

private func motionTarget(_ x: Double, _ y: Double, _ time: Double,
                          confidence: Double = 0.8) -> BallTarget {
    BallTarget(x: x, y: y, confidence: confidence, timestamp: time)
}

private func expectVelocity(_ history: BallMotionHistory, x: Double, y: Double) throws {
    try expectTrue(history.velocityX.map { abs($0 - x) < 0.000001 } == true)
    try expectTrue(history.velocityY.map { abs($0 - y) < 0.000001 } == true)
}

private func expectNoMotion(_ history: BallMotionHistory, count: Int = 0) throws {
    try expectEqual(history.points.count, count)
    try expectEqual(history.velocityX, nil)
    try expectEqual(history.velocityY, nil)
}

func checkBallMotionMeasurement() async throws {
    var history = BallMotionHistory()
    for elapsed in [0.0, 0.04, 0.17, 0.22, 0.40] {
        let time = 10 + elapsed
        history.update(with: motionTarget(0.2 + 0.4 * elapsed, 0.7 - 0.25 * elapsed, time),
                       now: time + 0.05)
        // Use capture time rather than callback time and support irregular intervals.
        try expectEqual(history.points.last?.timestamp, time)
        if elapsed == 0 { try expectNoMotion(history, count: 1) }
        else { try expectVelocity(history, x: 0.4, y: -0.25) }
    }

    // Smooth the last four deltas, with their real durations, even when noisy.
    history.reset()
    for (time, x, y) in [(1.0, 0.30, 0.70), (1.04, 0.31, 0.70),
                          (1.17, 0.37, 0.68), (1.22, 0.36, 0.69), (1.40, 0.45, 0.65)] {
        history.update(with: motionTarget(x, y, time), now: time)
    }
    try expectVelocity(history, x: 0.15 / 0.4, y: -0.05 / 0.4)
    history.update(with: motionTarget(0.47, 0.65, 1.45), now: 1.45)
    try expectVelocity(history, x: 0.16 / 0.41, y: -0.05 / 0.41)
    let unchangedPoints = history.points
    // A repeated timestamp, even with different coordinates, is not a new frame.
    for _ in 0..<50 {
        history.update(with: motionTarget(0.6, 0.8, 1.45), now: 1.46)
    }
    try expectEqual(history.points, unchangedPoints)
    try expectVelocity(history, x: 0.16 / 0.41, y: -0.05 / 0.41)

    history.reset()
    for i in 0..<60 {
        let time = 2 + Double(i) * 0.005
        history.update(with: motionTarget(0.5, 0.5, time), now: time)
    }
    try expectEqual(history.points.count, 30)
    try expectEqual(history.points.first?.timestamp, 2 + 30 * 0.005)
    try expectVelocity(history, x: 0, y: 0)

    history.reset()
    for i in 0..<12 {
        let time = 3 + Double(i) * 0.1
        history.update(with: motionTarget(0.5, 0.5, time), now: time + 0.05)
    }
    try expectTrue(history.points.allSatisfy { 4.15 - $0.timestamp <= 0.600001 })
    try expectTrue(history.points.count >= 5 && history.points.count <= 6)
    try expectEqual(history.points.last?.timestamp, 4.1)
    try expectVelocity(history, x: 0, y: 0)
}

func checkBallMotionInvalidation() async throws {
    var history = BallMotionHistory()
    func seed() {
        history.reset()
        history.update(with: motionTarget(0.3, 0.4, 10), now: 10)
        history.update(with: motionTarget(0.32, 0.4, 10.1), now: 10.1)
    }
    seed()
    history.update(with: nil, now: 10.11)
    try expectNoMotion(history)

    for target in [motionTarget(0.4, 0.4, 10),                         // Too old.
                   motionTarget(0.4, 0.4, 10.4),                      // Future capture.
                   motionTarget(.nan, 0.4, 10.2),
                   motionTarget(0.4, .infinity, 10.2),
                   motionTarget(-0.01, 0.4, 10.2),
                   motionTarget(0.4, 1.01, 10.2),
                   motionTarget(0.4, 0.4, .nan),
                   motionTarget(0.4, 0.4, 10.2, confidence: .infinity),
                   motionTarget(0.4, 0.4, 10.2, confidence: -0.01),
                   motionTarget(0.4, 0.4, 10.2, confidence: 1.01)] {
        seed()
        history.update(with: target, now: 10.31)
        try expectNoMotion(history)
    }
    for now in [Double.nan, Double.infinity] {
        seed()
        history.update(with: motionTarget(0.4, 0.4, 10.2), now: now)
        try expectNoMotion(history)
    }

    seed()
    // A repeated captured frame eventually expires rather than keeping a trail alive.
    history.update(with: motionTarget(0.32, 0.4, 10.1), now: 10.401)
    try expectNoMotion(history)

    seed()
    history.update(with: motionTarget(0.34, 0.4, 10.351), now: 10.351)
    try expectNoMotion(history, count: 1)
    try expectEqual(history.points.last, BallTrailPoint(x: 0.34, y: 0.4, timestamp: 10.351))
    history.update(with: motionTarget(0.35, 0.4, 10.401), now: 10.401)
    try expectVelocity(history, x: 0.2, y: 0)

    // The gap and distance limits themselves still allow a connected trail.
    history.reset()
    history.update(with: motionTarget(0, 0.5, 20), now: 20)
    history.update(with: motionTarget(0.35, 0.5, 20.25), now: 20.25)
    try expectEqual(history.points.count, 2)
    try expectVelocity(history, x: 1.4, y: 0)

    seed()
    history.update(with: motionTarget(0.7, 0.4, 10.2), now: 10.2)
    try expectNoMotion(history, count: 1)
    try expectEqual(history.points.last?.x, 0.7)
    // A diagonal jump uses image distance rather than independent axis thresholds.
    seed()
    history.update(with: motionTarget(0.58, 0.66, 10.2), now: 10.2)
    try expectNoMotion(history, count: 1)

    seed()
    history.update(with: motionTarget(0.31, 0.4, 10.05), now: 10.2)
    try expectNoMotion(history, count: 1)
    try expectEqual(history.points.last?.timestamp, 10.05)
    seed()
    history.update(with: motionTarget(0.33, 0.4, 10.11), now: 10.2)
    history.update(with: motionTarget(0.34, 0.4, 10.12), now: 10.15)
    try expectNoMotion(history, count: 1)
    try expectEqual(history.points.last?.timestamp, 10.12)
    history.reset()
    try expectNoMotion(history)
}
