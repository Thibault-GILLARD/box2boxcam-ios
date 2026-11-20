import Foundation
import DockKitCore

private func ball(_ x: Double, _ y: Double = 0.5, score: Double = 0.15) -> BallCandidate {
    BallCandidate(x: x, y: y, width: 0.01, height: 0.01, confidence: score)
}
private func tick(_ policy: inout HybridCameraPolicy, _ candidates: [BallCandidate], _ time: Double,
                  center: HybridVector = HybridVector(0.5, 0.5), people: [HybridPerson] = []) -> HybridDecision? {
    policy.update(candidates: candidates,
        people: HybridPeopleSnapshot(timestamp: time, cameraCenter: center, people: people),
        cameraCenter: center, motionValid: true, timestamp: time, now: time + 0.03)
}

func checkHybridContinuity() async throws {
    var steady = HybridCameraPolicy(), intermittent = HybridCameraPolicy()
    var good: HybridDecision?, weak: HybridDecision?
    for i in 0..<15 {
        good = tick(&steady, [ball(0.55)], Double(i) / 10)
        weak = tick(&intermittent, i % 4 == 0 ? [ball(0.55, score: 0.99)] : [], Double(i) / 10)
    }
    try expectTrue(good!.reliability > 0.9)
    try expectTrue(good!.ballWeight > 0.99)
    try expectTrue(weak!.reliability < 0.3)
    try expectTrue(weak!.ballWeight < 0.1)
}
func checkHybridOutlierAndDuplicates() async throws {
    var policy = HybridCameraPolicy()
    for i in 0..<10 { _ = tick(&policy, [ball(0.4)], Double(i) / 10) }
    let result = tick(&policy, [ball(0.401), ball(0.9, score: 0.99)], 1)!
    try expectTrue(abs(result.selectedBall!.x - 0.401) < 1e-8)
    try expectTrue(tick(&policy, [ball(0.9)], 1) == nil)
    let rejected = tick(&policy, [ball(0.9)], 1.1)!
    try expectFalse(rejected.measured)
    try expectTrue(rejected.ballPoint!.x < 0.45)
}
func checkHybridCameraCompensation() async throws {
    var policy = HybridCameraPolicy()
    var result: HybridDecision?
    for i in 0..<15 {
        let cameraShift = Double(i) * 0.008
        result = tick(&policy, [ball(0.6 - cameraShift)], Double(i) / 10,
                      center: HybridVector(0.5 + cameraShift, 0.5))
    }
    try expectTrue(result!.reliability > 0.95)
    try expectTrue(abs(result!.ballPoint!.x - (0.6 - 14 * 0.008)) < 1e-6)
    try expectTrue(result!.trail.allSatisfy { abs($0.x - result!.ballPoint!.x) < 1e-6 })
}
func checkHybridLossAndFreshness() async throws {
    var policy = HybridCameraPolicy()
    for i in 0..<10 { _ = tick(&policy, [ball(0.6)], Double(i) / 10) }
    let brieflyMissing = tick(&policy, [], 1)!
    try expectTrue(brieflyMissing.ballWeight > 0.99)
    let expired = tick(&policy, [], 1.6)!
    try expectTrue(expired.target == nil)
    try expectTrue(expired.motorTarget(now: 1.61) == nil)
    let fresh = tick(&policy, [ball(0.5)], 1.7)!
    try expectTrue(fresh.motorTarget(now: 2.1) == nil)
    try expectTrue(policy.update(candidates: [ball(0.5)], people: nil, cameraCenter: HybridVector(0.5,0.5),
        motionValid: true, timestamp: 2, now: 2.5) == nil)
}
func checkHybridExitSide() async throws {
    var policy = HybridCameraPolicy()
    for i in 0..<12 { _ = tick(&policy, [ball(0.68 + Double(i) * 0.02)], Double(i) / 10) }
    var result: HybridDecision?
    for i in 12..<18 { result = tick(&policy, [], Double(i) / 10) }
    try expectTrue(result!.mode.contains("sortie"))
    try expectTrue(result!.target!.x > 0.85)
}
func checkHybridFieldAndAirborne() async throws {
    var policy = HybridCameraPolicy()
    policy.setField([HybridVector(0.1,0.4),HybridVector(0.9,0.4),HybridVector(0.9,0.6),HybridVector(0.1,0.6)])
    var result: HybridDecision?
    for i in 0..<15 { result = tick(&policy, [ball(0.5,0.3),ball(0.5,0.8,score:0.99)], Double(i) / 10) }
    try expectTrue(result!.reliability > 0.9)
    try expectTrue(result!.ballPoint!.y < 0.4)
}
func checkHybridFieldDuringTracking() async throws {
    let field = [HybridVector(0.1,0.4),HybridVector(0.9,0.4),HybridVector(0.9,0.6),HybridVector(0.1,0.6)]
    var drift = HybridCameraPolicy()
    drift.setField(field)
    var result: HybridDecision?
    for i in 0..<30 {
        result = tick(&drift, [ball(0.5,0.54+Double(i)*0.008)], Double(i)/10)
        if i >= 16 { try expectFalse(result!.measured) }
        if let predicted = result!.ballPoint { try expectTrue(predicted.y <= 0.66) }
    }
    try expectTrue(result!.ballPoint == nil)
    try expectEqual(result!.ballWeight, 0)

    var association = HybridCameraPolicy()
    association.setField(field)
    for i in 0..<12 { _ = tick(&association, [ball(0.5,0.657)], Double(i)/10) }
    let valid = tick(&association, [ball(0.5,0.662,score:0.99),ball(0.5,0.651)], 1.2)!
    try expectTrue(valid.measured)
    try expectTrue(abs(valid.selectedBall!.y-0.651) < 1e-8)
}
func checkHybridFieldPredictionAndCameraShift() async throws {
    var policy = HybridCameraPolicy()
    policy.setField([HybridVector(0.1,0.4),HybridVector(0.9,0.4),HybridVector(0.9,0.6),HybridVector(0.1,0.6)])
    for i in 0..<12 { _ = tick(&policy, [ball(0.5,0.563+Double(i)*0.008)], Double(i)/10) }
    let missing = tick(&policy, [], 1.2)!
    try expectTrue(missing.ballPoint == nil)
    try expectEqual(missing.ballWeight, 0)

    var shifted = HybridCameraPolicy()
    shifted.setField([HybridVector(0.1,0.4),HybridVector(0.9,0.4),HybridVector(0.9,0.6),HybridVector(0.1,0.6)])
    for i in 0..<12 { _ = tick(&shifted, [ball(0.5,0.65)], Double(i)/10) }
    // A vertical pan changes local coordinates, not the calibrated world boundary.
    let outside = tick(&shifted, [ball(0.5,0.612,score:0.99),ball(0.5,0.60)], 1.2,
        center:HybridVector(0.5,0.55))!
    try expectTrue(abs(outside.selectedBall!.y-0.60) < 1e-8)
}
func checkHybridOffscreenPeople() async throws {
    var reference = HybridCameraPolicy(), injected = HybridCameraPolicy()
    let visible = [0.4,0.5,0.6].map { x in HybridPerson(x:x,y:0.45,width:0.03,height:0.1,confidence:0.9,
        rays:[HybridRay(origin:HybridVector(x,0.45),direction:HybridVector(1,0),weight:1,selected:true)]) }
    let hidden = (0..<100).map { _ in HybridPerson(x:1.5,y:0.45,width:0.03,height:0.1,confidence:1,
        rays:[HybridRay(origin:HybridVector(1.5,0.45),direction:HybridVector(-1,0),weight:100,selected:true)]) }
    for i in 0..<15 {
        let a = tick(&reference, [], Double(i)/10, people:visible)!
        let b = tick(&injected, [], Double(i)/10, people:visible+hidden)!
        try expectEqual(a.target,b.target)
        try expectTrue(b.people.count == 3)
    }
}
func checkHybridReferenceRate() async throws {
    var policy = HybridCameraPolicy()
    var previous: HybridVector?
    for i in 0..<50 {
        let people = [HybridPerson(x: i < 25 ? 0.2 : 0.8,y:0.45,width:0.05,height:0.1,confidence:0.9)]
        let result = tick(&policy, [], Double(i)/10,people:people)!
        if let old = previous, let target = result.target { try expectTrue(abs(target.x-old.x) <= 0.0850001) }
        previous = result.target
    }
}
func checkHybridBodyGeometryInvalid() async throws {
    try expectTrue(HybridBodyGeometry.rays(joints: [],width:1280,height:720).isEmpty)
    let empty = Array(repeating: HybridJoint(0.5,0.5,0),count:17)
    try expectTrue(HybridBodyGeometry.rays(joints:empty,width:1280,height:720).isEmpty)
}

func checkHybridSparseOrientationConfirmation() async throws {
    func players(_ sign: Double) -> [HybridPerson] {
        [0.4,0.5,0.6].map { x in HybridPerson(x:x,y:0.45,width:0.03,height:0.1,confidence:0.9,
            rays:[HybridRay(origin:HybridVector(x,0.45),direction:HybridVector(sign,0),weight:1,selected:true)]) }
    }
    var policy = HybridCameraPolicy()
    var previous: HybridDecision?
    for i in 0..<15 { previous = tick(&policy, [],Double(i)/10,people:players(1)) }
    var result: HybridDecision?
    for i in 0..<4 { result = tick(&policy, [],1.5+Double(i)*0.25,people:players(-1)) }
    try expectEqual(result!.mode,"Orientation commune")
    try expectTrue(result!.target!.x < previous!.target!.x)
}

func checkOrientationRefinementV2() async throws {
    let direction = HybridVector(cos(.pi/6),sin(.pi/6))
    let result = HybridBodyGeometry.refinedDirection(direction,motion:HybridVector(1,0),strength:1)
    try expectTrue(result.y < direction.y && result.y > 0)
    let backwards = HybridBodyGeometry.refinedDirection(direction,motion:direction * -1,strength:1)
    try expectEqual(backwards,direction)
    let veto = HybridBodyGeometry.refinedDirection(HybridVector(1,0),motion:HybridVector(0.8,-0.6),strength:1,
        limbEvidence:[(HybridVector(0,1),0.9,1.8)])
    try expectEqual(veto,HybridVector(1,0))
}
func checkOrientationMotionEvidenceV2() async throws {
    let samples = (0..<7).map { (Double($0)*0.2,HybridVector(0.5+Double($0)*0.01,0.5)) }
    let good = HybridBodyGeometry.motionEvidence(samples,width:1000,height:1000,bodyHeight:30)
    try expectTrue(good != nil && good!.angularStrength > 0.9)
    let jitter = (0..<7).map { (Double($0)*0.2,HybridVector(0.5+($0%2 == 0 ? 0.005 : -0.005),0.5)) }
    try expectTrue(HybridBodyGeometry.motionEvidence(jitter,width:1000,height:1000,bodyHeight:30) == nil)
    let reversal = [0.0,1,2,3,4,3,2].enumerated().map { (Double($0.offset)*0.2,HybridVector(0.5+$0.element*0.01,0.5)) }
    try expectTrue(HybridBodyGeometry.motionEvidence(reversal,width:1000,height:1000,bodyHeight:30) == nil)
}
func checkManualZoomFieldTransform() async throws {
    let points = [HybridVector(0.1,0.2),HybridVector(0.9,0.25),HybridVector(0.8,0.8),HybridVector(0.2,0.75)]
    let zoomed = points.map { FrameGeometry.zoomedPoint($0,from:1,to:3) }
    for (original,wide) in zip(points,zoomed.map({FrameGeometry.zoomedPoint($0,from:3,to:1)})) {
        try expectTrue((original-wide).length < 1e-8)
    }
    try expectTrue(FrameGeometry.validField(points))
    try expectTrue(FrameGeometry.validField(zoomed))
    try expectFalse(FrameGeometry.validField([points[0],points[2],points[1],points[3]]))
    try expectFalse(FrameGeometry.validField([points[0],points[1],points[1],points[3]]))
}
