import Foundation

/// Drops ball candidates seen at the same world-fixed spot for too long: floodlights,
/// turf marks, spare balls or bags lying on the touchline. A ball at rest is dropped too,
/// until it moves again. Spots are compensated with the measured image registration
/// (the hybrid mode's camera centre); a frame without a valid registration is assumed
/// not to have moved, i.e. falls back to raw image coordinates.
public struct StaticCandidateFilter: Sendable {
    /// Continuous presence at one spot after which its candidates are dropped.
    public static let maximumDwell: TimeInterval = 0.5
    /// Spot radius as a fraction of image width; vertical distances use the same unit.
    public static let radius = 0.02
    /// Detection gaps up to this long keep the presence continuous (flicker, local window).
    public static let maximumGap: TimeInterval = 0.2
    /// A spot unseen for this long is forgotten. Until then a spot already found static
    /// stays static, so a player passing in front of a bag does not restart its dwell.
    public static let forgetAfter: TimeInterval = 1.0
    /// Memory bound; the least recently seen spot is evicted first.
    public static let maximumSpots = 32

    private struct Spot: Sendable {
        let x: Double, y: Double // World coordinates, image-width units.
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var isStatic: Bool { lastSeen - firstSeen > StaticCandidateFilter.maximumDwell }
    }
    private var spots: [Spot] = []
    private var offset = HybridVector.zero
    private var camera: (reference: UUID, center: HybridVector)?
    private var lastTimestamp: TimeInterval?
    public var spotCount: Int { spots.count }

    public init() {}

    public mutating func reset() { self = Self() }

    /// `camera` is the registered camera centre and its reference for this frame, nil
    /// when unavailable. Candidates are normalized, top-left origin, upright image.
    public mutating func filter(_ candidates: [BallCandidate], timestamp: TimeInterval, imageAspectRatio: Double,
                                camera: (reference: UUID, center: HybridVector)?) -> (kept: [BallCandidate], dropped: Int) {
        guard timestamp.isFinite, imageAspectRatio.isFinite, imageAspectRatio > 0 else { return (candidates, 0) }
        if let lastTimestamp, timestamp <= lastTimestamp { reset() }
        lastTimestamp = timestamp
        // Integrate the camera centre's motion within one registration reference only;
        // a new reference (registration lost) or a missing estimate counts as no motion.
        let current = camera.flatMap { $0.center.finite ? $0 : nil }
        if let current, let previous = self.camera, previous.reference == current.reference {
            offset = offset + (current.center - previous.center)
        }
        self.camera = current
        spots.removeAll { timestamp - $0.lastSeen > Self.forgetAfter }

        var kept: [BallCandidate] = []
        for candidate in candidates {
            guard candidate.x.isFinite, candidate.y.isFinite else { kept.append(candidate); continue }
            let x = candidate.x + offset.x, y = (candidate.y + offset.y) / imageAspectRatio
            let nearest = spots.indices.filter { hypot(spots[$0].x - x, spots[$0].y - y) <= Self.radius }
                .min { hypot(spots[$0].x - x, spots[$0].y - y) < hypot(spots[$1].x - x, spots[$1].y - y) }
            guard let index = nearest else {
                spots.append(Spot(x: x, y: y, firstSeen: timestamp, lastSeen: timestamp))
                kept.append(candidate)
                continue
            }
            if !spots[index].isStatic, timestamp - spots[index].lastSeen > Self.maximumGap {
                spots[index].firstSeen = timestamp
            }
            spots[index].lastSeen = timestamp
            if !spots[index].isStatic { kept.append(candidate) }
        }
        while spots.count > Self.maximumSpots,
              let oldest = spots.indices.min(by: { spots[$0].lastSeen < spots[$1].lastSeen }) {
            spots.remove(at: oldest)
        }
        return (kept, candidates.count - kept.count)
    }
}
