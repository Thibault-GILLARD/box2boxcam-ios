import Foundation
import DockKitCore

private func spot(_ x: Double, _ y: Double = 0.5, confidence: Double = 0.6) -> BallCandidate {
    BallCandidate(x: x, y: y, width: 0.01, height: 0.018, confidence: confidence)
}

/// Feeds one frame and returns whether the single candidate was dropped.
private func dropped(_ filter: inout StaticCandidateFilter, _ candidate: BallCandidate, at time: Double,
                     camera: (reference: UUID, center: HybridVector)? = nil) -> Bool {
    filter.filter([candidate], timestamp: time, imageAspectRatio: 16.0 / 9, camera: camera).dropped == 1
}

func checkStaticFilterDwellAndGaps() async throws {
    // 25 Hz, fixed spot: kept while the presence is <= 0.5 s, dropped once it is longer.
    var filter = StaticCandidateFilter()
    var pattern: [Bool] = []
    for k in 0...14 { pattern.append(dropped(&filter, spot(0.3), at: 10 + Double(k) * 0.04)) }
    try expectEqual(pattern, Array(repeating: false, count: 13) + [true, true]) // 0.48 s kept, 0.52 s dropped.
    // Small jitter within 2 % of the width stays the same spot; other candidates are untouched.
    let mixed = filter.filter([spot(0.312, 0.51), spot(0.7, 0.4)], timestamp: 10.6, imageAspectRatio: 16.0 / 9, camera: nil)
    try expectEqual(mixed.dropped, 1)
    try expectTrue(mixed.kept.count == 1 && mixed.kept[0].x == 0.7)
    // 2 % of the width, not of the height: 0.03 of a 16:9 height is 1.7 % of the width.
    try expectTrue(dropped(&filter, spot(0.3, 0.53), at: 10.64))
    try expectFalse(dropped(&filter, spot(0.3, 0.54), at: 10.68))

    // Flicker: 3 missed frames (a 0.16 s gap) do not reset the dwell.
    filter = StaticCandidateFilter()
    pattern = []
    for k in 0...14 where !(5...7).contains(k) { pattern.append(dropped(&filter, spot(0.3), at: 20 + Double(k) * 0.04)) }
    try expectEqual(pattern.last, true)
    // A longer gap (0.3 s) before the spot was static restarts the dwell.
    filter = StaticCandidateFilter()
    for k in 0...7 { _ = dropped(&filter, spot(0.3), at: 30 + Double(k) * 0.04) }
    pattern = []
    for k in 0...13 { pattern.append(dropped(&filter, spot(0.3), at: 30.58 + Double(k) * 0.04)) }
    try expectEqual(pattern, Array(repeating: false, count: 13) + [true])

    // Once static, a 0.6 s occlusion keeps it static; after more than 1 s it is forgotten.
    filter = StaticCandidateFilter()
    for k in 0...14 { _ = dropped(&filter, spot(0.3), at: 40 + Double(k) * 0.04) }
    try expectTrue(dropped(&filter, spot(0.3), at: 40.56 + 0.6))
    try expectFalse(dropped(&filter, spot(0.3), at: 41.16 + 1.05))

    // Invalid time leaves candidates unchanged; a clock going backwards starts afresh.
    try expectEqual(filter.filter([spot(0.3)], timestamp: .nan, imageAspectRatio: 16.0 / 9, camera: nil).dropped, 0)
    for k in 0...14 { _ = dropped(&filter, spot(0.5), at: 50 + Double(k) * 0.04) }
    try expectFalse(dropped(&filter, spot(0.5), at: 1))
}

func checkStaticFilterMotionAndMemory() async throws {
    // A ball rolling slowly (0.15 image width per second) for 5 s is never dropped.
    var filter = StaticCandidateFilter()
    for k in 0..<150 {
        try expectFalse(dropped(&filter, spot(0.1 + Double(k) * 0.005), at: Double(k) / 30))
    }

    // Camera pans 0.4 % of the width per frame. The followed ball stays at the image centre:
    // with compensation it moves in the world and is kept; raw coordinates would drop it.
    let reference = UUID()
    var compensated = StaticCandidateFilter(), raw = StaticCandidateFilter()
    var compensatedDrops = 0, rawDrops = 0
    for k in 0..<60 {
        let time = 100 + Double(k) / 30, center = HybridVector(0.5 + Double(k) * 0.004, 0.5)
        if dropped(&compensated, spot(0.5), at: time, camera: (reference, center)) { compensatedDrops += 1 }
        if dropped(&raw, spot(0.5), at: time) { rawDrops += 1 }
    }
    try expectEqual(compensatedDrops, 0)
    try expectTrue(rawDrops > 30)
    // A floodlight moves across the image during the same pan: compensated, it is found
    // static; raw, it is not. A lost registration (new reference) counts as no motion and
    // keeps the accumulated position, so the floodlight stays static across it.
    compensated = StaticCandidateFilter(); raw = StaticCandidateFilter()
    var compensatedPattern: [Bool] = [], rawPattern: [Bool] = []
    var second = UUID()
    for k in 0..<45 {
        let time = 200 + Double(k) / 30
        let center = k < 30 ? HybridVector(0.5 + Double(k) * 0.004, 0.5) : HybridVector(0.5 + Double(k - 30) * 0.004, 0.5)
        if k == 30 { second = UUID() }
        let floodlight = spot(0.8 - Double(k) * 0.004, 0.2)
        compensatedPattern.append(dropped(&compensated, floodlight, at: time, camera: (k < 30 ? reference : second, center)))
        rawPattern.append(dropped(&raw, floodlight, at: time))
    }
    try expectTrue(compensatedPattern.suffix(25).allSatisfy { $0 })
    try expectFalse(rawPattern.contains(true))
    // A frame without registration is treated as raw (no motion assumed) and does not crash.
    try expectEqual(compensated.filter([spot(0.62, 0.2)], timestamp: 202, imageAspectRatio: 16.0 / 9, camera: nil).dropped, 1)

    // Bounded memory: many distinct spots never exceed the limit; old ones are evicted.
    filter = StaticCandidateFilter()
    for k in 0..<20 {
        let many = (0..<40).map { spot(Double($0) / 40 + 0.001, Double(k) / 20 + 0.01) }
        _ = filter.filter(many, timestamp: 300 + Double(k) / 30, imageAspectRatio: 16.0 / 9, camera: nil)
        try expectTrue(filter.spotCount <= StaticCandidateFilter.maximumSpots)
    }
    filter.reset()
    try expectEqual(filter.spotCount, 0)
}
