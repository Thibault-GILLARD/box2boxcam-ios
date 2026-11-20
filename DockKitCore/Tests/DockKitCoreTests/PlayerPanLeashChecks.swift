import Foundation
import DockKitCore

private let degree = Double.pi / 180

func checkPlayerPanLeash() async throws {
    var leash = PlayerPanLeash()
    // Before the ball ever drove the camera, players move it freely.
    try expectEqual(leash.limit(azimuthRate: 0.3, azimuth: 1, ballDriving: false, now: 0), 0.3)
    // The ball drives at azimuth 0: no limit, the anchor follows.
    try expectEqual(leash.limit(azimuthRate: -0.3, azimuth: 0, ballDriving: true, now: 1), -0.3)
    try expectTrue(leash.anchor == 0 && leash.range(now: 1) == nil)
    // Players only: free inside 30°, slowed in the last 5°, stopped beyond.
    try expectEqual(leash.limit(azimuthRate: 0.3, azimuth: 10 * degree, ballDriving: false, now: 2), 0.3)
    let soft = leash.limit(azimuthRate: 0.3, azimuth: 27.5 * degree, ballDriving: false, now: 2)
    try expectTrue(soft > 0.1 && soft < 0.2)
    try expectEqual(leash.limit(azimuthRate: 0.3, azimuth: 31 * degree, ballDriving: false, now: 2), 0)
    try expectEqual(leash.limit(azimuthRate: -0.3, azimuth: 31 * degree, ballDriving: false, now: 2), -0.3)  // back is free
    // The 18 Nov runaway: 80° away 4 s after the ball, at full speed, is stopped.
    try expectEqual(leash.limit(azimuthRate: -0.3, azimuth: -80 * degree, ballDriving: false, now: 6), 0)
    // The range widens with time without the ball, up to 80°.
    try expectTrue(abs((leash.range(now: 12) ?? 0) - 50 * degree) < 1e-9)
    try expectEqual(leash.limit(azimuthRate: 0.3, azimuth: 40 * degree, ballDriving: false, now: 12), 0.3)
    try expectTrue(abs((leash.range(now: 100) ?? 0) - 80 * degree) < 1e-9)
    // Azimuths wrap around ±180°.
    var wrapped = PlayerPanLeash()
    _ = wrapped.limit(azimuthRate: 0, azimuth: 179 * degree, ballDriving: true, now: 0)
    try expectEqual(wrapped.limit(azimuthRate: 0.3, azimuth: -175 * degree, ballDriving: false, now: 0.1), 0.3)  // 6° away
    // The ball back resets the range around its new direction.
    try expectEqual(leash.limit(azimuthRate: 0.3, azimuth: 60 * degree, ballDriving: true, now: 13), 0.3)
    try expectTrue(leash.anchor == 60 * degree)
    leash.reset()
    try expectTrue(leash.anchor == nil)
}

func checkCutOffNearCamera() async throws {
    // A substitute next to the camera: tall, cut by the bottom of the image.
    try expectTrue(HybridPerson(x: 0.9, y: 0.75, width: 0.15, height: 0.5, confidence: 0.9).isCutOffNearCamera)
    // A player on the pitch, feet visible; a short body at the bottom edge; a tall body with feet in view.
    try expectFalse(HybridPerson(x: 0.5, y: 0.5, width: 0.04, height: 0.2, confidence: 0.9).isCutOffNearCamera)
    try expectFalse(HybridPerson(x: 0.5, y: 0.9, width: 0.05, height: 0.2, confidence: 0.9).isCutOffNearCamera)
    try expectFalse(HybridPerson(x: 0.5, y: 0.6, width: 0.1, height: 0.5, confidence: 0.9).isCutOffNearCamera)
}
