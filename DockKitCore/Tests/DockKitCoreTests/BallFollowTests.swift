import Foundation
import CoreGraphics
import DockKitCore

func checkBallPolicy() async throws {
    var policy = BallFollowPolicy()
    func target(_ x: Double, _ y: Double, _ time: Double = 1, _ confidence: Double = 0.8) -> BallTarget {
        BallTarget(x: x, y: y, confidence: confidence, timestamp: time)
    }
    // A modest offset previously inside the broad dead zone now recenters.
    let first = policy.velocity(for: target(0.6, 0.4), now: 1)
    try expectTrue(first.yaw > 0.04 && first.pitch < -0.04)
    try expectTrue(abs(first.yaw) <= 0.060001 && abs(first.pitch) <= 0.060001)
    try expectEqual(policy.velocity(for: target(0.5, 0.5, 1.01), now: 1.01), .zero)
    policy.reset()
    let initial = policy.velocity(for: target(1, 0), now: 1)
    try expectTrue(abs(initial.yaw - 0.06) < 0.000001)
    try expectTrue(abs(initial.pitch + 0.06) < 0.000001)
    var previous = initial
    for i in 1...20 {
        let time = 1 + Double(i) * 0.1
        let next = policy.velocity(for: target(1, 0, time), now: time)
        try expectTrue(abs(next.yaw) <= 0.20 && abs(next.pitch) <= 0.20)
        try expectTrue(abs(next.yaw - previous.yaw) <= 0.120001)
        try expectTrue(abs(next.pitch - previous.pitch) <= 0.120001)
        if i == 2 {
            try expectTrue(abs(next.yaw - 0.20) < 0.000001)
            try expectTrue(abs(next.pitch + 0.20) < 0.000001)
        }
        previous = next
    }
    // A requested speed beyond the supported range still cannot exceed 0.30.
    policy.maximumSpeed = 1
    let capped = policy.velocity(for: target(1, 0, 3.001), now: 3.001)
    try expectTrue(abs(capped.yaw) <= 0.30 && abs(capped.pitch) <= 0.30)
    let atHardCap = policy.velocity(for: target(1, 0, 3.101), now: 3.101)
    try expectTrue(abs(atHardCap.yaw - 0.30) < 0.000001)
    try expectTrue(abs(atHardCap.pitch + 0.30) < 0.000001)
    policy.maximumSpeed = 0.05
    let reduced = policy.velocity(for: target(1, 0, 3.11), now: 3.11)
    try expectTrue(abs(reduced.pitch) <= 0.05 && abs(reduced.yaw) <= 0.05)
    try expectEqual(policy.velocity(for: nil, now: 3.2), .zero)
    try expectEqual(policy.velocity(for: target(1, 1), now: 1.31), .zero)
    try expectEqual(policy.velocity(for: target(1, 1, 4), now: 3), .zero)
    try expectEqual(policy.velocity(for: target(1, 1, 4, 0.2), now: 4), .zero)
    try expectEqual(policy.velocity(for: target(.nan, 1, 4), now: 4), .zero)
    policy.invertYaw = true; policy.invertPitch = true
    let inverted = policy.velocity(for: target(1, 0, 4), now: 4)
    try expectTrue(inverted.yaw < 0 && inverted.pitch > 0)
    try expectEqual(policy.velocity(for: target(0.5, 0.5, 4.1), now: 4.1), .zero)

    var precise = BallFollowPolicy()
    try expectEqual(precise.velocity(for: target(0.5049, 0.4951, 10), now: 10), .zero)
    let nearCenter = precise.velocity(for: target(0.5051, 0.4949, 10.1), now: 10.1)
    // Aim at the actual center, rather than subtracting the tolerance width.
    try expectTrue(abs(nearCenter.yaw - 0.00918) < 0.000001)
    try expectTrue(abs(nearCenter.pitch + 0.00765) < 0.000001)
    precise.deadZone = -1
    try expectTrue(precise.velocity(for: target(0.5001, 0.5, 10.2), now: 10.2).yaw > 0)
    precise.deadZone = 1
    try expectEqual(precise.velocity(for: target(0.599, 0.401, 10.3), now: 10.3), .zero)
    let outsideMaximumZone = precise.velocity(for: target(0.61, 0.39, 10.4), now: 10.4)
    try expectTrue(outsideMaximumZone.yaw > 0 && outsideMaximumZone.pitch < 0)
    try expectEqual(precise.velocity(for: nil, now: 10.41), .zero)

    var cadence = BallFollowPolicy()
    let atStart = cadence.velocity(for: target(1, 0, 20), now: 20)
    // Extra callbacks do not get an additional acceleration allowance.
    try expectEqual(cadence.velocity(for: target(1, 0, 20), now: 20), atStart)
    let afterFiveMilliseconds = cadence.velocity(for: target(1, 0, 20.005), now: 20.005)
    try expectTrue(abs(afterFiveMilliseconds.yaw - atStart.yaw - 0.006) < 0.000001)
    try expectTrue(abs(afterFiveMilliseconds.pitch - atStart.pitch + 0.006) < 0.000001)
    let afterLongGap = cadence.velocity(for: target(1, 0, 21), now: 21)
    try expectTrue(abs(afterLongGap.yaw - afterFiveMilliseconds.yaw - 0.12) < 0.000001)
    try expectTrue(abs(afterLongGap.pitch - afterFiveMilliseconds.pitch + 0.12) < 0.000001)
    try expectEqual(cadence.velocity(for: target(1, 0, 21), now: 21.31), .zero)
}

func checkFrameGeometry() async throws {
    let box = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2)
    let ninety = FrameGeometry.rotate(box, angle: 90)
    try expectTrue(abs(ninety.midX - 0.7) < 0.00001 && abs(ninety.midY - 0.15) < 0.00001)
    var rotated = box
    for _ in 0..<4 { rotated = FrameGeometry.rotate(rotated, angle: 90) }
    try expectTrue(abs(rotated.minX - box.minX) < 0.00001 && abs(rotated.minY - box.minY) < 0.00001)
    try expectEqual(FrameGeometry.aspectFit(image: CGSize(width: 1280, height: 720),
                      bounds: CGRect(x: 0, y: 0, width: 320, height: 300)),
                    CGRect(x: 0, y: 60, width: 320, height: 180))

    // Sensor-dependent angles can start on any quarter turn, including wrapped
    // and negative values. The preview and Vision must receive the same turn.
    for (reported, expected) in [(0.2, 0), (89.8, 90), (180.1, 180),
                                 (269.7, 270), (359.8, 0), (-90.2, 270), (450.1, 90)] {
        try expectEqual(FrameGeometry.snappedRotationAngle(reported), expected)
    }
    var turn = FrameGeometry.snappedRotationAngle(0)
    for reported in [44.0, 46.0, 44.5, 49.9] {
        turn = FrameGeometry.snappedRotationAngle(reported, previous: turn)
        try expectEqual(turn, 0)
    }
    turn = FrameGeometry.snappedRotationAngle(50.1, previous: turn)
    try expectEqual(turn, 90)
    for reported in [46.0, 44.5, 40.1, 89.9] {
        turn = FrameGeometry.snappedRotationAngle(reported, previous: turn)
        try expectEqual(turn, 90)
    }
    turn = FrameGeometry.snappedRotationAngle(39.9, previous: turn)
    try expectEqual(turn, 0)
    try expectEqual(FrameGeometry.snappedRotationAngle(319.9, previous: 270), 270)
    try expectEqual(FrameGeometry.snappedRotationAngle(320.1, previous: 270), 0)
    try expectEqual(FrameGeometry.snappedRotationAngle(315, previous: 0), 0)
    try expectEqual(FrameGeometry.snappedRotationAngle(.nan), nil)
    try expectEqual(FrameGeometry.snappedRotationAngle(.infinity), nil)

    // Touches use the fitted image, including front/landscape letterboxing.
    let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
    let wide = CGSize(width: 1600, height: 900)
    let center = FrameGeometry.normalizedPoint(CGPoint(x: 200, y: 200), image: wide, bounds: viewport)
    try expectEqual(center, CGPoint(x: 0.5, y: 0.5))
    try expectTrue(FrameGeometry.normalizedPoint(CGPoint(x: 200, y: 20), image: wide, bounds: viewport) == nil)
    try expectTrue(FrameGeometry.normalizedPoint(CGPoint(x: -1, y: 200), image: wide, bounds: viewport) == nil)
    try expectTrue(FrameGeometry.normalizedPoint(CGPoint(x: 200, y: 200), image: .zero, bounds: viewport) == nil)
    let fitted = FrameGeometry.aspectFit(image: wide, bounds: viewport)
    let quarter = CGPoint(x: fitted.minX + fitted.width * 0.25, y: fitted.minY + fitted.height * 0.75)
    try expectEqual(FrameGeometry.normalizedPoint(quarter, image: wide, bounds: viewport), CGPoint(x: 0.25, y: 0.75))
}
