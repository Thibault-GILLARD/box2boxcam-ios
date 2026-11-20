import Foundation
import CoreGraphics
import DockKitCore

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

private func ball(_ x: Double, _ y: Double = 0.5, confidence: Double = 0.7) -> BallCandidate {
    BallCandidate(x: x, y: y, width: 0.01, height: 0.01, confidence: confidence)
}

/// Confirm a track at (0.3, 0.5) with three full-frame detections ending at 10.066 s.
private func confirmed() -> BallSearchWindowPolicy {
    var policy = BallSearchWindowPolicy()
    for time in [10, 10.033, 10.066] {
        policy.record(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: time),
                      candidates: [ball(0.3)], timestamp: time, now: time + 0.03, minimumConfidence: 0.25)
    }
    return policy
}

func checkSearchWindowGeometry() async throws {
    // 960 native pixels, centred, landscape and portrait.
    let centre = BallSearchWindow.centred(x: 0.5, y: 0.5, imageWidth: 1920, imageHeight: 1080)
    try expectTrue(near(centre.rect.width, 0.5) && near(centre.rect.height, 960.0 / 1080))
    try expectTrue(near(centre.rect.midX, 0.5) && near(centre.rect.midY, 0.5))
    let portrait = BallSearchWindow.centred(x: 0.5, y: 0.5, imageWidth: 1080, imageHeight: 1920)
    try expectTrue(near(portrait.rect.width * 1080, 960) && near(portrait.rect.height * 1920, 960))
    // Clamped inside the image at every border, size unchanged.
    for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.02, 0.98), (-3.0, 7.0)] {
        let window = BallSearchWindow.centred(x: x, y: y, imageWidth: 1920, imageHeight: 1080)
        try expectTrue(window.rect.minX >= 0 && window.rect.minY >= 0)
        try expectTrue(window.rect.maxX <= 1 + 1e-12 && window.rect.maxY <= 1 + 1e-12)
        try expectTrue(near(window.rect.width, 0.5) && near(window.rect.height, 960.0 / 1080))
    }
    let corner = BallSearchWindow.centred(x: 1, y: 0, imageWidth: 1920, imageHeight: 1080)
    try expectTrue(near(corner.rect.maxX, 1) && near(corner.rect.minY, 0))
    // A small image is analysed whole; invalid input falls back to the full frame.
    try expectTrue(BallSearchWindow.centred(x: 0.2, y: 0.2, imageWidth: 640, imageHeight: 640).isFullFrame)
    try expectTrue(BallSearchWindow.centred(x: .nan, y: 0.2, imageWidth: 1920, imageHeight: 1080).isFullFrame)

    // Full frame is the default Vision region and an exact identity mapping.
    try expectEqual(BallSearchWindow.fullFrame.visionRegion, CGRect(x: 0, y: 0, width: 1, height: 1))
    let box = CGRect(x: 0.123, y: 0.456, width: 0.01, height: 0.02)
    try expectEqual(BallSearchWindow.fullFrame.fullImageVisionBox(box), box)

    // Round trip: a full-image ball, expressed in window coordinates, maps back.
    let window = BallSearchWindow.centred(x: 0.8, y: 0.2, imageWidth: 1920, imageHeight: 1080)
    let region = window.visionRegion
    try expectTrue(near(region.minY, 1 - window.rect.maxY))
    let full = CGRect(x: 0.81, y: 0.75, width: 0.006, height: 0.011) // bottom-left, top-left y = 0.239
    let local = CGRect(x: (full.minX - region.minX) / region.width, y: (full.minY - region.minY) / region.height,
                       width: full.width / region.width, height: full.height / region.height)
    try expectTrue((0...1).contains(local.minX) && (0...1).contains(local.minY))
    let mapped = window.fullImageVisionBox(local)
    try expectTrue(near(mapped.minX, full.minX) && near(mapped.minY, full.minY))
    try expectTrue(near(mapped.width, full.width) && near(mapped.height, full.height))
    // The window centre maps back to the (clamped) window centre in top-left coordinates.
    try expectTrue(near(window.rect.maxX, 1) && near(window.rect.midX, 0.75))
    let middle = window.fullImageVisionBox(CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    try expectTrue(near(middle.minX, window.rect.midX) && near(1 - middle.minY, window.rect.midY))
}

func checkSearchWindowPolicy() async throws {
    // No track, or a track not yet confirmed: whole image.
    var policy = BallSearchWindowPolicy()
    try expectTrue(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: 1).isFullFrame)
    policy.record(.fullFrame, candidates: [ball(0.3)], timestamp: 1, now: 1.03, minimumConfidence: 0.25)
    policy.record(.fullFrame, candidates: [ball(0.3)], timestamp: 1.033, now: 1.063, minimumConfidence: 0.25)
    try expectTrue(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: 1.066).isFullFrame)

    // Confirmed and fresh: local, centred on the predicted position.
    policy = confirmed()
    let local = policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: 10.099)
    try expectFalse(local.isFullFrame)
    try expectTrue(abs(local.rect.midX - 0.3) < 0.01)
    // Stale measurement: whole image.
    try expectTrue(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: 10.066 + 0.151).isFullFrame)

    // With detections every frame, exactly every 5th analysis is full frame.
    var pattern: [Bool] = []
    var time = 10.066
    for _ in 0..<10 {
        time += 0.033
        let window = policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: time)
        pattern.append(window.isFullFrame)
        policy.record(window, candidates: [ball(0.3)], timestamp: time, now: time + 0.03, minimumConfidence: 0.25)
    }
    try expectEqual(pattern, [false, false, false, false, true, false, false, false, false, true])

    // Two consecutive local analyses without a proposal above threshold force a full one.
    policy = confirmed()
    pattern = []
    time = 10.066
    for _ in 0..<3 {
        time += 0.033
        let window = policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: time)
        pattern.append(window.isFullFrame)
        policy.record(window, candidates: [ball(0.3, confidence: 0.2)], timestamp: time, now: time + 0.03,
                      minimumConfidence: 0.25)
    }
    try expectEqual(pattern, [false, false, true])
    // The full analysis finds the ball again; local search resumes.
    policy.record(.fullFrame, candidates: [ball(0.3)], timestamp: time + 0.033, now: time + 0.063, minimumConfidence: 0.25)
    try expectFalse(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: time + 0.066).isFullFrame)

    // Reset forgets the track.
    policy.reset()
    try expectTrue(policy.window(imageWidth: 1920, imageHeight: 1080, timestamp: time + 0.066).isFullFrame)
}
