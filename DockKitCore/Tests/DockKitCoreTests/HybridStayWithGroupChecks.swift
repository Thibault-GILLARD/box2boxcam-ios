import Foundation
import DockKitCore

/// `count` players in a row centred on local x = 0.5 (feet at y = 0.5); the first `facing` look along +x.
private func row(_ count: Int, facing: Int? = nil) -> [HybridPerson] {
    (0..<count).map { i in
        let x = 0.5 + (Double(i) - Double(count - 1) / 2) * 0.02
        let rays = i < (facing ?? count) ? [HybridRay(origin: HybridVector(x, 0.45), direction: HybridVector(1, 0), weight: 1, selected: true)] : []
        return HybridPerson(x: x, y: 0.45, width: 0.03, height: 0.1, confidence: 0.9, rays: rays)
    }
}
/// 10 Hz, no ball; people are given in local image coordinates of a camera looking at `center`.
private func step(_ policy: inout HybridCameraPolicy, _ people: [HybridPerson], _ time: Double,
                  center: HybridVector = HybridVector(0.5, 0.5)) -> HybridDecision {
    policy.update(candidates: [], people: HybridPeopleSnapshot(timestamp: time, cameraCenter: center, people: people),
                  cameraCenter: center, motionValid: true, timestamp: time, now: time + 0.03)!
}

func checkHybridStayWithGroupOffAndLeadScaling() async throws {
    // Off (default): nothing new is logged, and with a small stable group (peak < 5) on changes nothing either.
    var off = HybridCameraPolicy(), on = HybridCameraPolicy()
    try expectFalse(off.stayWithGroup)
    on.stayWithGroup = true
    for i in 0..<30 {
        let people = i < 15 ? row(3) : row(3).map { var p = $0; p.rays = p.rays.map { var r = $0; r.direction = HybridVector(-1, 0); return r }; return p }
        let a = step(&off, people, Double(i) / 10), b = step(&on, people, Double(i) / 10)
        try expectEqual(a.target, b.target)
        try expectEqual(a.playerTarget, b.playerTarget)
        try expectEqual(a.mode, b.mode)
        try expectTrue(a.groupInView == nil && a.groupPeak == nil)
        try expectTrue(b.groupInView == 3 && b.groupPeak == 3)
    }
    // A collapse never triggers the return while off.
    off = HybridCameraPolicy()
    for i in 0..<10 { _ = step(&off, row(10), Double(i) / 10) }
    for i in 10..<40 { try expectTrue(step(&off, row(2), Double(i) / 10).mode != "Joueurs : retour vers le groupe") }

    // Peak of 20 bodies without heading, then n bodies all facing +x: full lead 0.42 scaled by
    // (n / 20 - 0.40) / 0.30 -> 100 % of the peak: full, 55 %: half, 40 %: none (and no return).
    for (count, scale) in [(20, 1.0), (11, 0.5), (8, 0.0)] {
        var policy = HybridCameraPolicy()
        policy.stayWithGroup = true
        for i in 0..<10 { _ = step(&policy, row(20, facing: 0), Double(i) / 10) }
        var result: HybridDecision?
        for i in 10..<35 { result = step(&policy, row(count), Double(i) / 10) }
        try expectEqual(result!.mode, "Orientation commune")
        try expectTrue(result!.groupInView == count && result!.groupPeak == 20)
        try expectTrue(abs(result!.playerTarget!.x - (0.5 + 0.42 * scale)) < 1e-3)
    }
}

func checkHybridStayWithGroupReturnAndWeakContinuation() async throws {
    // 10 players driving +x seen with the camera at 0.5; the camera then pans to 0.8 and only
    // 3 front-runners remain (30 % < 40 % of a peak >= 5): the target goes back toward 0.5.
    var policy = HybridCameraPolicy()
    policy.stayWithGroup = true
    for i in 0..<10 { _ = step(&policy, row(10), Double(i) / 10) }
    let pan = HybridVector(0.8, 0.5)
    var previous = step(&policy, row(3), 1.0, center: pan)
    try expectEqual(previous.mode, "Joueurs : retour vers le groupe")
    for i in 11..<20 {
        let result = step(&policy, row(3), Double(i) / 10, center: pan)
        try expectEqual(result.mode, "Joueurs : retour vers le groupe")
        let world = result.playerTarget!.x + 0.3, before = previous.playerTarget!.x + 0.3
        try expectTrue(world < before && before - world <= 0.03 + 1e-9)  // rate 0.30 / s
        previous = result
    }
    // 6 players back in view (>= 60 % of the remembered peak): following resumes.
    try expectTrue(step(&policy, row(6), 2.0, center: pan).mode != "Joueurs : retour vers le groupe")

    // Without recovery the return ends after 6 s and does not restart on the stale peak.
    policy = HybridCameraPolicy(); policy.stayWithGroup = true
    for i in 0..<10 { _ = step(&policy, row(10), Double(i) / 10) }
    var modes: [String] = []
    for i in 10..<90 { modes.append(step(&policy, row(3), Double(i) / 10, center: pan).mode) }
    try expectTrue(modes[0..<60].allSatisfy { $0 == "Joueurs : retour vers le groupe" })
    try expectTrue(modes[61...].allSatisfy { $0 != "Joueurs : retour vers le groupe" })

    // Rule 4: after a peak of 6, only 2 of 6 visible bodies keep the heading. Off, they continue
    // the lead (required max(2, 25 %)); on, fewer than 3 cannot, so the memorised direction expires.
    var off = HybridCameraPolicy(), on = HybridCameraPolicy()
    on.stayWithGroup = true
    var a: HybridDecision?, b: HybridDecision?
    for i in 0..<10 { a = step(&off, row(6), Double(i) / 10); b = step(&on, row(6), Double(i) / 10) }
    try expectTrue(a!.mode == "Orientation commune" && b!.mode == "Orientation commune")
    for i in 10..<25 { a = step(&off, row(6, facing: 2), Double(i) / 10); b = step(&on, row(6, facing: 2), Double(i) / 10) }
    try expectEqual(a!.mode, "Orientation commune")
    try expectEqual(b!.mode, "Recentrage joueurs")
    try expectTrue(b!.groupPeak == 6 && b!.groupInView == 6)
}
