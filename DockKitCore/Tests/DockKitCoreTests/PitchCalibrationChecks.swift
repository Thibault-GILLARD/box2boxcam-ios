import Foundation
import DockKitCore

/// World direction from a camera at height `h` above the origin to a ground point (metres).
private func toward(_ x: Double, _ y: Double, h: Double = 2) -> PitchVector3 { PitchVector3(x, y, -h) }

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

func checkPitchCalibrationGeometry() async throws {
    // A 60 × 40 m pitch, camera 2 m high on the near touchline at halfway, looking along +y.
    // Image right is +x, so the left goal is at x = −30.
    guard let pitch = PitchCalibration(leftGoal: toward(-30, 20), rightGoal: toward(30, 20), centerSpot: toward(0, 20)) else {
        throw NSError(domain: "check", code: 1)
    }
    try expectTrue(close(pitch.halfLength, 15) && close(pitch.halfWidth, 10))  // in camera heights
    try expectTrue(pitch.centerError < 1e-9 && pitch.goalsInOrder)
    try expectTrue(pitch.containsFoot(toward(10, 35)))      // player 5 m inside the far touchline
    try expectTrue(pitch.containsFoot(toward(0, -1)))       // player just behind the camera's touchline
    try expectFalse(pitch.containsFoot(toward(0, 45)))      // spectator 5 m beyond the far touchline
    try expectFalse(pitch.containsFoot(toward(-36, 20)))    // 6 m behind the left goal line
    try expectFalse(pitch.containsFoot(PitchVector3(0, 1, 0.01)))  // above the horizon
    // Balls: only the camera's own touchline is a safe boundary.
    try expectTrue(pitch.isBehindNearTouchline(toward(-12, -3)))        // spare ball 3 m outside, near the bench
    try expectFalse(pitch.isBehindNearTouchline(toward(-12, 1)))        // ball in play near the touchline
    // A ball 1 m up over the pitch at (20, 30): the ray (20, 30, −1) meets the ground at (40, 60),
    // beyond the far touchline and the goal line. The people test would reject it, the ball test keeps it.
    let airborne = PitchVector3(20, 30, 1 - 2)
    try expectFalse(pitch.containsFoot(airborne))
    try expectFalse(pitch.isBehindNearTouchline(airborne))
    // Swapped goal marks are detected.
    let swapped = PitchCalibration(leftGoal: toward(30, 20), rightGoal: toward(-30, 20), centerSpot: toward(0, 20))
    try expectEqual(swapped?.goalsInOrder, false)
    // Relative azimuths: the left goal is counter-clockwise (positive) of the centre spot.
    try expectTrue(pitch.relativeAzimuth(pitch.leftAzimuth) > 0 && pitch.relativeAzimuth(pitch.rightAzimuth) < 0)
    try expectTrue(close(pitch.relativeAzimuth(pitch.leftAzimuth), atan2(30, 20), 1e-9))

    // Camera 10 m off halfway: the long axis is still found and the centre spot stays consistent.
    guard let shifted = PitchCalibration(leftGoal: toward(-40, 20), rightGoal: toward(20, 20), centerSpot: toward(-10, 20)) else {
        throw NSError(domain: "check", code: 2)
    }
    try expectTrue(close(shifted.halfWidth, 10) && close(shifted.halfLength, 15) && shifted.centerError < 1e-9)
    // A badly marked centre spot is reported.
    let doubtful = PitchCalibration(leftGoal: toward(-30, 20), rightGoal: toward(30, 20), centerSpot: toward(12, 20))
    try expectTrue(close(doubtful?.centerError ?? 0, 0.4, 1e-9))  // 6 camera heights over a half length of 15
    // A goal marked above the horizon cannot calibrate.
    try expectTrue(PitchCalibration(leftGoal: PitchVector3(-1, 1, 0.1), rightGoal: toward(30, 20), centerSpot: toward(0, 20)) == nil)
    // Two goals are enough: same pitch, centre at the middle of the goals, no consistency error.
    guard let twoTaps = PitchCalibration(leftGoal: toward(-30, 20), rightGoal: toward(30, 20)) else { throw NSError(domain: "check", code: 6) }
    try expectTrue(close(twoTaps.halfWidth, 10) && close(twoTaps.halfLength, 15) && twoTaps.centerError == 0 && twoTaps.centerSpot == nil)
    try expectTrue(close(twoTaps.centerAzimuth, .pi / 2) && twoTaps.goalsInOrder)
    try expectEqual(twoTaps.markings().count, 7)  // outline, halfway, circle, 2 × (penalty + goal area)
    // Markings: outline corners lie on the pitch edges.
    let outline = pitch.markings()[0]
    try expectTrue(close(outline[0].x, -15) && close(outline[0].y, 0) && close(outline[2].x, 15) && close(outline[2].y, 20))
    try expectFalse(pitch.behindGoal)
}

func checkGoalModelChoice() async throws {
    // Behind a goal (60 × 40 m, camera 3 m behind): goals nearly aligned, behind-goal model.
    let behind = PitchCalibration.fromGoals(toward(0, 3), toward(0, 63), preferBehindGoal: true)
    try expectTrue(behind?.behindGoal == true)
    // In a corner on the touchline extension (camera at x = −33, y = −20 of a pitch centred at 0):
    // goals 60° apart, touchline model with the measured width, goals put in order.
    let corner = PitchCalibration.fromGoals(toward(3, 20), toward(63, 20), preferBehindGoal: true)
    try expectTrue(corner?.behindGoal == false && corner?.goalsInOrder == true)
    try expectTrue(abs((corner?.halfWidth ?? 0) - 10) < 1e-6 && abs((corner?.halfLength ?? 0) - 15) < 1e-6)
    // Full-pitch mode: swapped taps are put back in order.
    let swapped = PitchCalibration.fromGoals(toward(30, 20), toward(-30, 20), preferBehindGoal: false)
    try expectTrue(swapped?.goalsInOrder == true && abs((swapped?.halfLength ?? 0) - 15) < 1e-6)
}

func checkBehindGoalCalibration() async throws {
    // A 60 × 40 m pitch along +y, camera 2 m high, 3 m behind its goal (goals at y = 3 and y = 63).
    guard let pitch = PitchCalibration(nearGoal: toward(0, 3), farGoal: toward(0, 63), widthToLength: 2.0 / 3.0) else {
        throw NSError(domain: "check", code: 7)
    }
    try expectTrue(pitch.behindGoal && pitch.goalsInOrder)
    try expectTrue(close(pitch.halfLength, 10) && close(pitch.halfWidth, 15))  // half width, half length (camera heights)
    try expectTrue(close(pitch.middle.x, 0) && close(pitch.middle.y, 16.5))   // centre spot at y = 33 m
    try expectTrue(pitch.containsFoot(toward(0, 50)) && pitch.containsFoot(toward(-18, 10)))
    try expectFalse(pitch.containsFoot(toward(25, 30)))   // 5 m beyond a touchline
    try expectFalse(pitch.containsFoot(toward(0, 75)))    // 12 m beyond the far goal line
    // Balls: a ball in the net (2 m behind the line) is kept, one 6 m behind the line is dropped.
    try expectFalse(pitch.isBehindNearTouchline(toward(0, 1)))
    try expectTrue(pitch.isBehindNearTouchline(toward(0, -3)))
    // Pan limits are the corners: left corner counter-clockwise of the centre, right one clockwise.
    try expectTrue(pitch.relativeAzimuth(pitch.leftAzimuth) > 0 && pitch.relativeAzimuth(pitch.rightAzimuth) < 0)
    // Markings drawn along the long axis: first outline corner is the left corner of the camera's goal line.
    let markings = pitch.markings()
    try expectEqual(markings.count, 7)
    try expectTrue(close(markings[0][0].x, -10) && close(markings[0][0].y, 1.5))
    // Halfway line crosses the pitch at the centre spot, from touchline to touchline.
    try expectTrue(close(markings[1][0].y, 16.5) && close(markings[1][1].y, 16.5) && close(abs(markings[1][0].x), 10))
    // Goals tapped far first are put back in order (same pitch); identical taps cannot calibrate.
    guard let swapped = PitchCalibration(nearGoal: toward(0, 63), farGoal: toward(0, 3), widthToLength: 2.0 / 3.0) else {
        throw NSError(domain: "check", code: 8)
    }
    try expectTrue(swapped.goalsInOrder && close(swapped.middle.y, 16.5) && close(swapped.leftGoal.x, -10))
    try expectTrue(PitchCalibration(nearGoal: toward(5, 3), farGoal: toward(5, 3)) == nil)
    // Camera a little off the axis: the pitch still follows the line between the goals.
    guard let offAxis = PitchCalibration(nearGoal: toward(4, 3), farGoal: toward(4, 63), widthToLength: 2.0 / 3.0) else {
        throw NSError(domain: "check", code: 9)
    }
    try expectTrue(offAxis.goalsInOrder && close(offAxis.middle.x, 2) && offAxis.containsFoot(toward(-14, 20)))
}

func checkCameraPoseProjection() async throws {
    try expectTrue(close(CameraPose.focal(longSideFieldOfViewDegrees: 60, zoom: 1, width: 1080, height: 1920) ?? 0,
                         1920 / (2 * tan(.pi / 6))))
    guard let pose = CameraPose(axis: PitchVector3(0.3, 1, -0.1), focal: 1500, width: 1920, height: 1080) else {
        throw NSError(domain: "check", code: 3)
    }
    // Image centre is the optical axis; a point right of centre turns clockwise (lower azimuth).
    let centre = pose.ray(HybridVector(0.5, 0.5))
    try expectTrue(close(centre.normalized!.dot(pose.axis), 1, 1e-12))
    try expectTrue(pose.ray(HybridVector(0.8, 0.5)).azimuth < centre.azimuth)
    // A point lower in the image looks further down.
    try expectTrue(pose.ray(HybridVector(0.5, 0.9)).normalized!.z < centre.normalized!.z)
    // Round trip image → ray → image.
    for point in [HybridVector(0.1, 0.2), HybridVector(0.9, 0.85), HybridVector(0.5, 0.5)] {
        guard let back = pose.project(pose.ray(point)) else { throw NSError(domain: "check", code: 4) }
        try expectTrue(close(back.x, point.x, 1e-9) && close(back.y, point.y, 1e-9))
    }
    try expectTrue(pose.project(pose.axis * -1) == nil)  // behind the camera
    try expectTrue(CameraPose(axis: PitchVector3(0, 0, -1), focal: 1500, width: 1920, height: 1080) == nil)  // straight down

    // End to end: a camera 2 m high looking at the centre spot of the pitch above sees the
    // pitch markings where the calibration puts them.
    guard let pitch = PitchCalibration(leftGoal: toward(-30, 20), rightGoal: toward(30, 20), centerSpot: toward(0, 20)),
          let look = CameraPose(axis: toward(0, 20), focal: 1500, width: 1920, height: 1080) else {
        throw NSError(domain: "check", code: 5)
    }
    let spot = look.project(PitchCalibration.direction(to: pitch.middle))
    try expectTrue(spot != nil && close(spot!.x, 0.5, 1e-9) && close(spot!.y, 0.5, 1e-9))
}
