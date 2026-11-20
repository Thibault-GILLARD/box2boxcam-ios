import Foundation
import DockKitCore

private func proposal(_ x: Double, _ y: Double = 0.5, confidence: Double = 0.7) -> BallCandidate {
    BallCandidate(x: x, y: y, width: 0.04, height: 0.04, confidence: confidence)
}

private func update(_ tracker: inout BallTrajectoryTracker, _ candidates: [BallCandidate],
                    _ time: Double, delay: Double = 0.047) -> TrackedBall? {
    tracker.update(candidates: candidates, timestamp: time, now: time + delay, minimumConfidence: 0.25)
}

private func seed(_ tracker: inout BallTrajectoryTracker, x: Double = 0.3) throws {
    tracker.reset()
    try expectTrue(update(&tracker, [proposal(x)], 10) == nil)
    try expectTrue(update(&tracker, [proposal(x)], 10.033) == nil)
    try expectTrue(update(&tracker, [proposal(x)], 10.066) != nil)
}

func checkTrajectoryAssociation() async throws {
    var tracker = BallTrajectoryTracker()
    try seed(&tracker)
    // A high-scoring branch cannot replace the actual, lower-scoring ball.
    let selected = update(&tracker, [proposal(0.85, 0.1, confidence: 0.95), proposal(0.31)], 10.099)
    try expectEqual(selected?.detection.x, 0.31)
    let previousTrail = tracker.points
    try expectTrue(update(&tracker, [proposal(0.85, 0.1)], 10.132) == nil)
    try expectEqual(tracker.status, .rejected)
    try expectEqual(tracker.points, previousTrail)
    try expectTrue(update(&tracker, [proposal(0.33)], 10.165) != nil)
    try expectTrue(tracker.points.allSatisfy { $0.x < 0.4 && $0.y > 0.4 })

    // A single false positive in empty footage is never a confirmed track.
    tracker.reset()
    try expectTrue(update(&tracker, [proposal(0.9)], 20) == nil)
    try expectTrue(update(&tracker, [], 20.033) == nil)
    try expectEqual(tracker.points.count, 0)
    try expectTrue(update(&tracker, [proposal(0.3)], 20.066) == nil)
    try expectTrue(update(&tracker, [proposal(0.3)], 20.099) == nil)
    try expectTrue(update(&tracker, [proposal(0.3)], 20.132) != nil)
}

func checkTrajectoryPrediction() async throws {
    var tracker = BallTrajectoryTracker()
    try seed(&tracker)
    var tracked: TrackedBall?
    for i in 1...24 {
        let elapsed = Double(i) * 0.033
        tracked = update(&tracker, [proposal(0.3 + 0.3 * elapsed)], 10.066 + elapsed)
        try expectTrue(tracked != nil)
    }
    guard let tracked else { try expectTrue(false); return }
    try expectTrue(abs(tracked.velocityX - 0.3) < 0.015)
    try expectTrue(abs(tracked.velocityY) < 0.000001)
    let target = tracked.target(now: tracked.timestamp + 0.047, lead: 0.03)
    // Same direction as the trajectory, using capture age + configured lead.
    try expectTrue(abs((target?.x ?? 0) - tracked.x - tracked.velocityX * 0.077) < 0.000001)
    try expectEqual(target?.timestamp, tracked.timestamp)
    try expectTrue(tracked.target(now: tracked.timestamp + 0.301, lead: 0.03) == nil)
    try expectTrue(tracked.target(now: tracked.timestamp - 0.01, lead: 0.03) == nil)
    try expectTrue(tracked.target(now: .nan, lead: 0.03) == nil)
    try expectTrue(tracked.target(now: tracked.timestamp, lead: .infinity) == nil)
    let bounded = tracked.target(now: tracked.timestamp + 0.2, lead: 2)
    try expectTrue(abs((bounded?.x ?? 0) - tracked.x - tracked.velocityX * 0.1) < 0.000001)

    // Even a high measured image speed only allows a short displacement.
    tracker.reset()
    var fastTracked: TrackedBall?
    for i in 0...15 {
        fastTracked = update(&tracker, [proposal(0.1 + Double(i) * 0.04)], 30 + Double(i) * 0.033)
    }
    guard let fast = fastTracked, let projected = fast.target(now: fast.timestamp + 0.05, lead: 0.06) else {
        try expectTrue(false); return
    }
    try expectTrue(hypot(projected.x - fast.x, projected.y - fast.y) <= 0.080001)
}

func checkCameraShiftAcrossMissingFrame() async throws {
    var baseline = BallTrajectoryTracker()
    try seed(&baseline)
    var compensated = baseline
    try expectTrue(update(&baseline, [], 10.099) == nil)
    try expectTrue(compensated.update(candidates: [], timestamp: 10.099, now: 10.146,
                                     minimumConfidence: 0.25, cameraShift: (0.12, 0)) == nil)
    try expectEqual(compensated.state?.timestamp, 10.066)

    let proposals = [proposal(0.54), proposal(0.30, confidence: 0.95)]
    try expectEqual(update(&baseline, proposals, 10.132)?.detection.x, 0.30)
    let tracked = compensated.update(candidates: proposals, timestamp: 10.132, now: 10.179,
                                     minimumConfidence: 0.25, cameraShift: (0.12, 0))
    try expectEqual(tracked?.detection.x, 0.54)
    try expectTrue(abs(tracked?.velocityX ?? 1) < 1e-9)
    try expectTrue(compensated.points.allSatisfy { abs($0.x - 0.54) < 1e-9 })
}

func checkTrajectoryLossAndMotorTarget() async throws {
    var tracker = BallTrajectoryTracker()
    try seed(&tracker)
    var policy = BallFollowPolicy()
    let accepted = update(&tracker, [proposal(0.31)], 10.099)
    try expectTrue(policy.velocity(for: accepted?.target(now: 10.146, lead: 0.03), now: 10.146) != .zero)
    let rejected = update(&tracker, [proposal(0.85, 0.1)], 10.132)
    try expectTrue(rejected == nil)
    try expectEqual(policy.velocity(for: rejected?.target(now: 10.179, lead: 0.03), now: 10.179), .zero)
    try expectTrue(update(&tracker, [], 10.165) == nil)
    // After loss, a distant position needs confirmation and starts a new trail.
    try expectTrue(update(&tracker, [proposal(0.8)], 10.4) == nil)
    try expectEqual(tracker.points.count, 0)
    try expectTrue(update(&tracker, [proposal(0.8)], 10.433) == nil)
    try expectTrue(update(&tracker, [proposal(0.8)], 10.466) != nil)
    try expectEqual(tracker.points.count, 1)
    tracker.expire(now: 10.767)
    try expectEqual(tracker.points.count, 0)
    try expectTrue(tracker.state == nil)

    try seed(&tracker)
    let stateTime = tracker.state?.timestamp
    try expectTrue(update(&tracker, [proposal(0.31)], 10.066) == nil)
    try expectEqual(tracker.state?.timestamp, stateTime)
    try expectTrue(tracker.update(candidates: [proposal(0.31)], timestamp: 10.05, now: 10.12, minimumConfidence: 0.25) == nil)
    try expectEqual(tracker.state?.timestamp, stateTime)
    try expectTrue(update(&tracker, [proposal(.nan)], 10.099) == nil)
    try expectTrue(update(&tracker, [proposal(0.31, confidence: 0.1)], 10.132) == nil)
    try expectTrue(update(&tracker, [proposal(0.31)], 10.165, delay: 0.301) == nil)
    try expectTrue(tracker.state == nil)
}

func checkTrajectorySmoothingAndTurn() async throws {
    var tracker = BallTrajectoryTracker()
    try seed(&tracker, x: 0.5)
    var rawJitter = 0.0, filteredJitter = 0.0
    var lastRaw = 0.5, lastFiltered = 0.5
    for i in 1...30 {
        let raw = 0.5 + (i.isMultiple(of: 2) ? 0.008 : -0.008)
        let tracked = update(&tracker, [proposal(raw)], 10.066 + Double(i) * 0.033)
        guard let tracked else { try expectTrue(false); return }
        rawJitter += abs(raw - lastRaw)
        filteredJitter += abs(tracked.x - lastFiltered)
        lastRaw = raw; lastFiltered = tracked.x
    }
    try expectTrue(filteredJitter < rawJitter * 0.8)
    // An actual reversal must be followed rather than rejected as a teleport.
    var final: TrackedBall?
    for i in 1...12 {
        final = update(&tracker, [proposal(0.5 + Double(i) * 0.01)], 11.056 + Double(i) * 0.033)
        try expectTrue(final != nil)
    }
    for i in 1...12 {
        final = update(&tracker, [proposal(0.62 - Double(i) * 0.01)], 11.452 + Double(i) * 0.033)
        try expectTrue(final != nil)
    }
    try expectTrue((final?.velocityX ?? 0) < -0.2)
}

func checkSparseTrajectoryConfirmation() async throws {
    var tracker = BallTrajectoryTracker()
    try expectTrue(update(&tracker, [proposal(0.3)], 10) == nil)
    try expectTrue(update(&tracker, [proposal(0.31)], 10.033) == nil)
    try expectTrue(update(&tracker, [], 10.066) == nil)
    // Three coherent measurements, even with a dropped frame, confirm motion.
    let confirmed = update(&tracker, [proposal(0.33)], 10.099)
    try expectTrue(confirmed != nil)
    try expectTrue(abs((confirmed?.velocityX ?? 0) - 0.30303) < 0.001)
    try expectTrue(confirmed?.hasVelocity == true)
    try expectTrue(update(&tracker, [proposal(0.85, 0.1)], 10.132) == nil)
    try expectTrue(update(&tracker, [proposal(0.35)], 10.165) != nil)

    // A long absence cannot reuse the earlier two observations to acquire.
    tracker.reset()
    try expectTrue(update(&tracker, [proposal(0.3)], 20) == nil)
    try expectTrue(update(&tracker, [proposal(0.31)], 20.033) == nil)
    try expectTrue(update(&tracker, [], 20.2) == nil)
    try expectTrue(update(&tracker, [proposal(0.32)], 20.233) == nil)
    try expectTrue(update(&tracker, [proposal(0.33)], 20.266) == nil)
    try expectTrue(update(&tracker, [proposal(0.34)], 20.299) != nil)
}

func checkRawDetectionSeparatedFromMotorTarget() async throws {
    var observation = BallObservationState()
    var policy = BallFollowPolicy()
    func receive(_ candidates: [BallCandidate], _ time: Double) {
        observation.update(candidates: candidates, timestamp: time, now: time + 0.047,
                           minimumConfidence: 0.25)
    }
    receive([proposal(0.3, confidence: 0.8)], 10)
    try expectEqual(observation.rawDetection?.confidence, 0.8)
    try expectTrue(observation.trackedBall == nil)
    try expectEqual(policy.velocity(for: observation.trackedBall?.target(now: 10.047, lead: 0.03), now: 10.047), .zero)
    receive([proposal(0.3)], 10.033)
    receive([proposal(0.3)], 10.066)
    try expectTrue(observation.trackedBall != nil)
    // A raw box may differ from the temporally accepted lower-score candidate.
    receive([proposal(0.85, 0.1, confidence: 0.95), proposal(0.31, confidence: 0.6)], 10.099)
    try expectEqual(observation.rawDetection?.x, 0.85)
    try expectEqual(observation.trackedBall?.detection.x, 0.31)
    receive([proposal(0.85, 0.1)], 10.132)
    try expectEqual(observation.rawDetection?.x, 0.85)
    try expectTrue(observation.trackedBall == nil)
    try expectEqual(policy.velocity(for: observation.trackedBall?.target(now: 10.179, lead: 0.03), now: 10.179), .zero)
    // Below the follow threshold still appears as a scored raw proposal.
    receive([proposal(0.31, confidence: 0.12)], 10.165)
    try expectEqual(observation.rawDetection?.confidence, 0.12)
    try expectTrue(observation.trackedBall == nil)
    observation.expire(now: 10.466)
    try expectTrue(observation.rawDetection == nil)
    try expectTrue(observation.trackedBall == nil)
    try expectEqual(observation.points.count, 0)
    receive([proposal(0.3)], 11)
    observation.reset()
    try expectTrue(observation.rawDetection == nil && observation.trackedBall == nil)
}

func checkManualBallSelection() async throws {
    var observation = BallObservationState()
    observation.selectBall(x: 0.3, y: 0.7)
    for i in 0..<3 {
        let time = 10 + Double(i) * 0.033
        observation.update(candidates: [proposal(0.85, 0.4, confidence: 0.95),
                                        proposal(0.3 + Double(i) * 0.01, 0.7, confidence: 0.6)],
                           timestamp: time, now: time + 0.047, minimumConfidence: 0.25)
        try expectTrue((observation.rawDetection?.x ?? 1) < 0.4)
    }
    try expectTrue((observation.trackedBall?.detection.x ?? 1) < 0.4)
    // Losing the moving ball cannot silently switch to the high-score spare ball.
    observation.update(candidates: [proposal(0.85, 0.4, confidence: 0.95)],
                       timestamp: 10.1, now: 10.147, minimumConfidence: 0.25)
    try expectTrue(observation.trackedBall == nil && observation.rawDetection == nil)
    observation.expire(now: 10.4)
    try expectTrue(observation.selectionLocation != nil)
    observation.update(candidates: [proposal(0.85, 0.4, confidence: 0.95)],
                       timestamp: 10.5, now: 10.547, minimumConfidence: 0.25)
    try expectTrue(observation.trackedBall == nil && observation.rawDetection == nil)
    // Invalid taps leave the current choice intact; reset returns to automatic.
    let selected = observation.selectionLocation
    observation.selectBall(x: .nan, y: 0.3)
    try expectEqual(observation.selectionLocation, selected)
    observation.reset()
    try expectTrue(observation.selectionLocation == nil)
    for i in 0..<3 {
        let time = 11 + Double(i) * 0.033
        observation.update(candidates: [proposal(0.85, 0.4, confidence: 0.95)],
                           timestamp: time, now: time + 0.047, minimumConfidence: 0.25)
    }
    try expectEqual(observation.trackedBall?.detection.x, 0.85)
}
