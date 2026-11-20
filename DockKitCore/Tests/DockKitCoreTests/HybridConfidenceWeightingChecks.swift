import Foundation
import DockKitCore

private func scored(_ score: Double, x: Double = 0.55) -> BallCandidate {
    BallCandidate(x: x, y: 0.5, width: 0.01, height: 0.01, confidence: score)
}
/// 10 Hz, fixed camera, no people: reliability is coverage x span x residual x freshness (x factor when on).
private func step(_ policy: inout HybridCameraPolicy, _ candidates: [BallCandidate], _ time: Double) -> HybridDecision {
    policy.update(candidates: candidates, people: nil, cameraCenter: HybridVector(0.5, 0.5),
                  motionValid: true, timestamp: time, now: time + 0.03)!
}

func checkHybridConfidenceWeightingOffAndAcquisition() async throws {
    // Off (default): the score changes nothing, and nothing new is logged.
    var low = HybridCameraPolicy(), high = HybridCameraPolicy()
    try expectFalse(low.confidenceWeighting)
    for i in 0..<20 {
        let a = step(&low, i % 5 == 4 ? [] : [scored(0.3, x: 0.55 + Double(i) * 0.004)], Double(i) / 10)
        let b = step(&high, i % 5 == 4 ? [] : [scored(0.9, x: 0.55 + Double(i) * 0.004)], Double(i) / 10)
        try expectEqual(a.reliability, b.reliability)
        try expectEqual(a.ballWeight, b.ballWeight)
        try expectEqual(a.target, b.target)
        try expectTrue(a.confidenceFactor == nil && b.confidenceFactor == nil)
        try expectEqual(low.ballActive, high.ballActive)
    }
    try expectTrue(low.ballActive)

    // A continuous track at 0.40 acquires when off, never when on (factor (0.40 - 0.25) / 0.35).
    var off = HybridCameraPolicy(), on = HybridCameraPolicy()
    on.confidenceWeighting = true
    var offResult: HybridDecision?, onResult: HybridDecision?
    for i in 0..<30 {
        offResult = step(&off, [scored(0.4)], Double(i) / 10)
        onResult = step(&on, [scored(0.4)], Double(i) / 10)
        try expectFalse(on.ballActive)
    }
    try expectTrue(off.ballActive && offResult!.ballWeight > 0.99 && offResult!.reliability > 0.99)
    try expectTrue(abs(onResult!.confidenceFactor! - 0.15 / 0.35) < 1e-9)
    try expectTrue(abs(onResult!.reliability - 0.15 / 0.35) < 1e-9)
    try expectEqual(onResult!.ballWeight, 0)

    // A track at 0.80 (>= 0.60) acquires in both, with the same reliability and weight.
    off = HybridCameraPolicy(); on = HybridCameraPolicy(); on.confidenceWeighting = true
    for i in 0..<15 {
        offResult = step(&off, [scored(0.8)], Double(i) / 10)
        onResult = step(&on, [scored(0.8)], Double(i) / 10)
        try expectEqual(off.ballActive, on.ballActive)
        try expectEqual(offResult!.reliability, onResult!.reliability)
        try expectEqual(offResult!.ballWeight, onResult!.ballWeight)
    }
    try expectTrue(on.ballActive && onResult!.confidenceFactor == 1 && onResult!.ballWeight > 0.99)
}

func checkHybridConfidenceWeightingRetain() async throws {
    // Active at 0.80, then a 1 s dip to 0.35: the mean falls to 0.35, factor 0.29 >= retain 0.25.
    var policy = HybridCameraPolicy()
    policy.confidenceWeighting = true
    var result: HybridDecision?
    for i in 0..<15 { result = step(&policy, [scored(0.8)], Double(i) / 10) }
    try expectTrue(policy.ballActive)
    for i in 15..<25 {
        result = step(&policy, [scored(0.35)], Double(i) / 10)
        try expectTrue(policy.ballActive)
    }
    try expectTrue(result!.reliability < policy.acquireReliability && result!.reliability >= policy.retainReliability)
    try expectTrue(result!.ballWeight > 0.99)
    for i in 25..<30 { result = step(&policy, [scored(0.8)], Double(i) / 10) }
    try expectTrue(policy.ballActive && result!.confidenceFactor == 1)

    // A sustained drop below 0.3375 brings the factor under retain: the ball is released.
    var released = false
    for i in 30..<40 { result = step(&policy, [scored(0.2)], Double(i) / 10); released = released || !policy.ballActive }
    try expectTrue(released && !policy.ballActive)
    try expectEqual(result!.confidenceFactor!, 0)
}

func checkHybridMinimumBallConfidence() async throws {
    // Library default keeps the historical 0.10 floor; the app sets the threshold slider here.
    try expectEqual(HybridCameraPolicy().minimumBallConfidence, 0.10)
    // A continuous 0.20 track is accepted with floor 0.10 and ignored entirely with floor 0.25.
    var low = HybridCameraPolicy(), high = HybridCameraPolicy()
    high.minimumBallConfidence = 0.25
    var lowResult: HybridDecision?, highResult: HybridDecision?
    for i in 0..<15 {
        lowResult = step(&low, [scored(0.2)], Double(i) / 10)
        highResult = step(&high, [scored(0.2)], Double(i) / 10)
        try expectTrue(lowResult!.measured && lowResult!.selectedBall?.confidence == 0.2)
        try expectTrue(!highResult!.measured && highResult!.selectedBall == nil && !high.ballActive)
    }
    try expectTrue(low.ballActive && lowResult!.ballWeight > 0.99)
    try expectEqual(highResult!.ballWeight, 0)
    // A candidate exactly at the floor is accepted.
    var edge = HybridCameraPolicy()
    edge.minimumBallConfidence = 0.25
    try expectTrue(step(&edge, [scored(0.25)], 0).measured)
}
