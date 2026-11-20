import Foundation

public struct HybridVector: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    public static let zero = HybridVector()
    public var length: Double { hypot(x, y) }
    public var finite: Bool { x.isFinite && y.isFinite }
    public var unit: HybridVector { length > 1e-9 ? self / length : .zero }
    public func dot(_ other: Self) -> Double { x * other.x + y * other.y }
    public func limited(_ maximum: Double) -> Self { length > maximum ? unit * maximum : self }
    public func clipped(_ low: Double, _ high: Double) -> Self { Self(max(low, min(high, x)), max(low, min(high, y))) }
    public static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
    public static func * (a: Self, b: Double) -> Self { Self(a.x * b, a.y * b) }
    public static func / (a: Self, b: Double) -> Self { Self(a.x / b, a.y / b) }
}

public struct HybridJoint: Codable, Sendable {
    public var point: HybridVector
    public var confidence: Double
    public init(_ x: Double, _ y: Double, _ confidence: Double) { point = HybridVector(x, y); self.confidence = confidence }
}

public struct HybridRay: Codable, Sendable {
    public var origin: HybridVector
    public var direction: HybridVector
    public var weight: Double
    public var selected: Bool
    public init(origin: HybridVector, direction: HybridVector, weight: Double, selected: Bool) {
        self.origin = origin; self.direction = direction; self.weight = weight; self.selected = selected
    }
}

public struct HybridPerson: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double
    public var joints: [HybridJoint]
    public var rays: [HybridRay]
    public init(x: Double, y: Double, width: Double, height: Double, confidence: Double,
                joints: [HybridJoint] = [], rays: [HybridRay] = []) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.confidence = confidence; self.joints = joints; self.rays = rays
    }
    public var foot: HybridVector { HybridVector(x, y + height / 2) }
    /// A tall body cut by the bottom of the image: someone standing next to the camera (a
    /// substitute or a spectator on the touchline, 18 Nov 2026), not a player to frame. Its foot,
    /// outside the image, is unknown too.
    public var isCutOffNearCamera: Bool { y + height / 2 >= 0.97 && height >= 0.35 }
    public func translated(_ offset: HybridVector) -> Self {
        var result = self
        result.x += offset.x; result.y += offset.y
        result.joints = joints.map { var joint = $0; joint.point = joint.point + offset; return joint }
        result.rays = rays.map { var ray = $0; ray.origin = ray.origin + offset; return ray }
        return result
    }
}

public struct HybridPeopleSnapshot: Codable, Sendable {
    public var timestamp: TimeInterval
    public var cameraCenter: HybridVector
    public var people: [HybridPerson]
    public var analysisMilliseconds: Double
    public var error: String?
    public init(timestamp: TimeInterval, cameraCenter: HybridVector, people: [HybridPerson],
                analysisMilliseconds: Double = 0, error: String? = nil) {
        self.timestamp = timestamp; self.cameraCenter = cameraCenter; self.people = people
        self.analysisMilliseconds = analysisMilliseconds; self.error = error
    }
}

public struct HybridDecision: Codable, Sendable {
    public var timestamp: TimeInterval
    public var target: HybridVector?
    public var playerTarget: HybridVector?
    public var ballPoint: HybridVector?
    public var ballWeight: Double
    public var reliability: Double
    public var coverage: Double
    public var ballAge: Double?
    public var measured: Bool
    public var mode: String
    public var reason: String
    public var orientationSupport: Int
    public var people: [HybridPerson]
    public var peopleTimestamp: TimeInterval?
    public var motionCompensated: Bool
    public var selectedBall: BallCandidateRecord?
    public var trail: [HybridVector]
    /// Reliability multiplier from the track's mean detector score; nil while confidence weighting is off.
    public var confidenceFactor: Double? = nil
    /// Players in view and their recent peak (last 4 s); nil while « Rester avec le groupe » is off.
    public var groupInView: Int? = nil
    public var groupPeak: Int? = nil
    public func motorTarget(now: TimeInterval) -> BallTarget? {
        guard now >= timestamp, now - timestamp <= 0.30, let target, target.finite else { return nil }
        return BallTarget(x: target.x, y: target.y, confidence: 1, timestamp: timestamp)
    }
}

public struct BallCandidateRecord: Codable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double; public var confidence: Double
    public init(_ ball: BallCandidate) { x = ball.x; y = ball.y; width = ball.width; height = ball.height; confidence = ball.confidence }
}

/// Same continuity, hysteresis and shared-reference rules as the offline hybrid.
/// Coordinates are stabilized using measured image registration, never motor commands.
public struct HybridCameraPolicy {
    public var acquireReliability = 0.70
    public var retainReliability = 0.25
    public var transitionRate = 0.85
    public var exitHold = 1.2
    /// Experimental, off by default: scale reliability by the mean detector score of the
    /// track's recent measurements. Off, the score only gates (>= minimumBallConfidence) and breaks acquisition ties.
    public var confidenceWeighting = false
    /// Lowest detector score a ball candidate needs to be considered at all (the app sets the
    /// user's threshold slider here). 0.10 keeps the library's historical floor.
    public var minimumBallConfidence = 0.10
    /// Mean score giving a zero factor, and the range above it reaching a full factor (0.25 → 0, 0.60 → 1).
    public static let confidenceWeightingFloor = 0.25
    public static let confidenceWeightingRange = 0.35
    /// Experimental, off by default: keep the player-guided camera with the group. Tracks the
    /// peak of players in view over 4 s, scales the heading lead by the share still in view,
    /// returns toward where the camera looked at the peak when the share collapses, and refuses
    /// a continuation supported by fewer than 3 players after a peak of 6 or more.
    public var stayWithGroup = false
    public static let groupWindow = 4.0, groupFullLead = 0.70, groupZeroLead = 0.40
    public static let groupEnter = 0.40, groupExit = 0.60, groupMinimumPeak = 5
    public static let groupReturnRate = 0.30, groupTimeout = 6.0
    private var groupHistory: [(Double, Int, HybridVector)] = []
    private var groupCount = 0
    private var groupPeak = 0
    private var groupPeakCenter: HybridVector?
    private var groupReturning = false
    private var groupReturnPeak = 0
    private var groupReturnCenter = HybridVector.zero
    private var groupReturnSince = 0.0
    private var point: HybridVector?
    private var velocity = HybridVector.zero
    private var lastSeen: Double?
    private var started = 0.0
    private var hits = 0
    private var history: [(Double, Bool, Double)] = []
    private var path: [(Double, HybridVector)] = []
    private var residualError = 0.0
    private var previousTime: Double?
    private var previousCenter = HybridVector(0.5, 0.5)
    private var lastLocal = HybridVector.zero
    private var relativeVelocity = HybridVector.zero
    private var lastReliability = 0.0
    public private(set) var ballActive = false
    private var weight = 0.0
    private var reference: HybridVector?
    private var playerReference: HybridVector?
    private var direction: HybridVector?
    private var pendingDirection: HybridVector?
    private var pendingCount = 0
    private var pendingStarted = 0.0
    private var lastSupport = -Double.infinity
    private var lead = 0.0
    private var lastPeopleTime = -Double.infinity
    private var previousPeople: [(HybridVector, Double, Double)] = []
    private var exitDirection: HybridVector?
    private var exitTarget: HybridVector?
    private var exitUntil = -Double.infinity
    private var selection: HybridVector?
    public private(set) var field: [HybridVector] = []

    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func selectBall(_ local: HybridVector) {
        resetBall(); selection = local + previousCenter - HybridVector(0.5, 0.5)
    }
    public mutating func setField(_ polygon: [HybridVector]) {
        field = polygon.map { $0 + previousCenter - HybridVector(0.5, 0.5) }
        resetBall()
    }
    private mutating func resetBall() {
        point = nil; velocity = .zero; lastSeen = nil; hits = 0; history = []; residualError = 0
        ballActive = false; weight = 0; lastReliability = 0; exitDirection = nil; exitUntil = -.infinity; path = []
    }
    private func allowedByField(_ candidate: HybridVector) -> Bool {
        guard candidate.finite else { return false }
        if field.count >= 3 {
            var edges: [Double] = []
            for i in field.indices {
                let a = field[i], b = field[(i + 1) % field.count]
                if abs(b.x - a.x) > 1e-8 && min(a.x, b.x) <= candidate.x && candidate.x <= max(a.x, b.x) {
                    edges.append(a.y + (candidate.x - a.x) / (b.x - a.x) * (b.y - a.y))
                }
            }
            guard let near = edges.max(), candidate.y <= near + 0.06 else { return false }
        }
        return true
    }
    private func eligibleAcquisition(_ candidate: HybridVector, people: [HybridPerson]) -> Bool {
        if let selection, (candidate - selection).length > 0.15 { return false }
        if field.count < 3, people.count >= 3, let near = people.map(\.foot.y).max() {
            // People feet are only a weak acquisition prior, not a calibrated
            // field boundary. Do not use this changing heuristic on a track.
            if candidate.y > near + 0.12 { return false }
        }
        return true
    }

    public mutating func update(candidates: [BallCandidate], people snapshot: HybridPeopleSnapshot?,
            cameraCenter: HybridVector, motionValid: Bool, timestamp: TimeInterval, now: TimeInterval,
            imageAspectRatio: Double = 1) -> HybridDecision? {
        guard timestamp.isFinite, now.isFinite, cameraCenter.finite, now >= timestamp, now - timestamp <= 0.30,
              previousTime.map({ timestamp > $0 }) ?? true else { return nil }
        let dt = previousTime.map { timestamp - $0 } ?? 0.1
        let step = min(0.2, dt), cameraVelocity = (cameraCenter - previousCenter) / dt
        if dt > 0.65 || !motionValid {
            resetBall(); previousPeople = []; direction = nil; pendingCount = 0
            reference = nil; playerReference = nil; lastSupport = -.infinity
            // The compensated frame restarts: remembered camera positions are no longer comparable.
            groupHistory = []; groupPeak = 0; groupPeakCenter = nil; groupReturning = false
        }
        previousTime = timestamp; previousCenter = cameraCenter
        let offset = cameraCenter - HybridVector(0.5, 0.5)
        let peopleFresh = snapshot.map { timestamp >= $0.timestamp && timestamp - $0.timestamp <= 0.65 && $0.error == nil } ?? false
        let worldPeople = peopleFresh ? snapshot!.people.map { $0.translated(snapshot!.cameraCenter - HybridVector(0.5, 0.5)) }.filter {
            let local = $0.foot - offset
            return local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1 && $0.height > 0
        } : []
        var peopleTarget: HybridVector?
        var playerMode = "Recentrage joueurs"
        var support = 0
        var confirmedHeading: HybridVector?
        var leadScale = 1.0
        if stayWithGroup {
            // (1) Recent peak of players in view and where the camera looked then, in the same
            // registration-compensated frame as worldPeople and playerReference. Only fresh people
            // snapshots count: a missing pose analysis is not an empty view.
            if peopleFresh {
                groupCount = worldPeople.count
                groupHistory.append((timestamp, groupCount, cameraCenter))
            }
            groupHistory.removeAll { $0.0 < timestamp - Self.groupWindow }
            if let best = groupHistory.max(by: { ($0.1, $0.0) < ($1.1, $1.0) }) { groupPeak = best.1; groupPeakCenter = best.2 }
            else { groupPeak = 0; groupPeakCenter = nil }
            if ballActive || (groupReturning && (Double(groupCount) >= Self.groupExit * Double(groupReturnPeak)
                    || timestamp - groupReturnSince > Self.groupTimeout)) { groupReturning = false }
            let ratio = groupPeak > 0 ? Double(groupCount) / Double(groupPeak) : 1
            // (3) The group collapsed while players drive: drop the heading and go back.
            if !groupReturning, !ballActive, groupPeak >= Self.groupMinimumPeak, ratio < Self.groupEnter, let center = groupPeakCenter {
                groupReturning = true; groupReturnPeak = groupPeak; groupReturnCenter = center; groupReturnSince = timestamp
                direction = nil; pendingCount = 0
            }
            // (2) Full lead at >= 70 % of the peak, none at <= 40 %.
            leadScale = groupPeak > 0 ? max(0, min(1, (ratio - Self.groupZeroLead) / (Self.groupFullLead - Self.groupZeroLead))) : 1
        }
        if !worldPeople.isEmpty {
            var weighted = HybridVector.zero, total = 0.0
            for person in worldPeople {
                let foot = person.foot
                var movement = 0.0
                if let old = previousPeople.min(by: { (foot - $0.0).length < (foot - $1.0).length }), timestamp > old.2 {
                    let delta = foot - old.0
                    if delta.length < max(person.height, old.1) * 1.8 {
                        movement = min(3, max(0, (delta.length / (timestamp - old.2) / max(0.01, person.height) - 0.35) * 1.5))
                    }
                }
                let density = worldPeople.reduce(0.0) { $0 + exp(-pow((foot - $1.foot).length / 0.25, 2) / 2) }.squareRoot()
                let contribution = (1 + movement) * density
                weighted = weighted + foot * contribution; total += contribution
            }
            peopleTarget = weighted / max(1e-6, total)
            if let snapshot, snapshot.timestamp > lastPeopleTime {
                lastPeopleTime = snapshot.timestamp
                previousPeople = worldPeople.map { ($0.foot, $0.height, snapshot.timestamp) }
                let rays = worldPeople.compactMap { $0.rays.first(where: { $0.selected && $0.weight > 0 }) }
                if rays.count >= 2 && !groupReturning {
                    let best = rays.max { a, b in
                        rays.filter { $0.direction.dot(a.direction) >= cos(35 * .pi / 180) }.reduce(0) { $0 + $1.weight }
                        < rays.filter { $0.direction.dot(b.direction) >= cos(35 * .pi / 180) }.reduce(0) { $0 + $1.weight }
                    }!
                    let agreeing = rays.filter { $0.direction.dot(best.direction) >= cos(35 * .pi / 180) }
                    let dominance = agreeing.reduce(0) { $0 + $1.weight } / max(1e-6, rays.reduce(0) { $0 + $1.weight })
                    let heading = agreeing.reduce(HybridVector.zero) { $0 + $1.direction * $1.weight }.unit
                    let continuing = direction.map { $0.dot(heading) >= cos(35 * .pi / 180) } ?? false
                    var required = continuing ? max(2, Int(ceil(Double(worldPeople.count) * 0.25))) : max(3, Int(ceil(Double(worldPeople.count) * 0.35)))
                    // (4) After a peak of 6+, fewer than 3 bodies cannot continue a lead.
                    if stayWithGroup && continuing && groupPeak >= 6 { required = max(required, 3) }
                    if agreeing.count >= required && dominance >= (continuing ? 0.55 : 0.75) {
                        support = agreeing.count
                        if let pendingDirection, pendingDirection.dot(heading) >= cos(.pi / 6) { pendingCount += 1 }
                        else { pendingCount = 1; pendingStarted = timestamp }
                        pendingDirection = heading
                        let opposite = direction.map { $0.dot(heading) < 0 } ?? false
                        // Confirmation is timed, so sparse live poses do not
                        // turn seven 10 Hz samples into a multi-second wait.
                        if continuing || (pendingCount >= (opposite ? 3 : 2) && timestamp - pendingStarted >= (opposite ? 0.55 : 0.18)) {
                            let newIntent = direction == nil || opposite
                            direction = newIntent ? heading : (direction! * 0.8 + heading * 0.2).unit
                            let agreement = max(0, min(1, (dominance - 0.75) / 0.25))
                            let coverage = max(0, min(1, (Double(support) / Double(worldPeople.count) - 0.2) / 0.4))
                            let amount = 0.15 + 0.27 * agreement * coverage
                            lead = newIntent ? amount : max(lead, amount)
                            lastSupport = timestamp; confirmedHeading = direction
                        }
                    } else { pendingCount = 0 }
                } else { pendingCount = 0 }
            }
        }
        if timestamp - lastSupport > 4 { direction = nil }
        if confirmedHeading == nil, let direction, peopleFresh {
            // Display the still-visible supporting bodies without counting the
            // cached snapshot as a new confirmation observation.
            support = worldPeople.filter { person in
                person.rays.contains { $0.selected && $0.direction.dot(direction) >= cos(35 * .pi / 180) }
            }.count
        }
        if groupReturning {
            playerMode = "Joueurs : retour vers le groupe"
            if playerReference == nil { playerReference = groupReturnCenter }
            else { playerReference = playerReference! + (groupReturnCenter - playerReference!)
                .clipped(-Self.groupReturnRate * step, Self.groupReturnRate * step) }
        } else if let base = peopleTarget {
            var desired = base, rate = 0.15
            if let direction, timestamp - lastSupport <= 1.2 {
                let lead = self.lead * leadScale
                desired = base + HybridVector(direction.x * lead, max(-0.25, min(0.25, direction.y * lead * imageAspectRatio)))
                playerMode = confirmedHeading == nil ? "Direction mémorisée" : "Orientation commune"
                rate = 0.45
                if let playerReference, (desired - playerReference).dot(direction) < 0 { rate = 0.15 }
            }
            if playerReference == nil { playerReference = desired }
            else { playerReference = playerReference! + (desired - playerReference!).clipped(-rate * step, rate * step) }
        } else if timestamp - lastSupport > 3 { playerReference = nil }

        var age = lastSeen.map { timestamp - $0 } ?? .infinity
        if age > 0.65 { point = nil; velocity = .zero; hits = 0; history = []; residualError = 0; path = [] }
        let valid = candidates.filter { c in
            [c.x,c.y,c.width,c.height,c.confidence].allSatisfy(\.isFinite) && c.confidence >= minimumBallConfidence && c.confidence <= 1
                && (0...1).contains(c.x) && (0...1).contains(c.y) && c.width > 0 && c.height > 0
                && allowedByField(HybridVector(c.x, c.y) + offset)
        }
        var chosen: BallCandidate?
        if let point {
            let predicted = point + velocity * age
            chosen = valid.min { (HybridVector($0.x, $0.y) + offset - predicted).length < (HybridVector($1.x, $1.y) + offset - predicted).length }
            if let candidate = chosen, (HybridVector(candidate.x, candidate.y) + offset - predicted).length > min(0.23, 0.055 + 0.65 * age) { chosen = nil }
        } else {
            let prior = peopleTarget ?? cameraCenter
            chosen = valid.filter { eligibleAcquisition(HybridVector($0.x, $0.y) + offset, people: worldPeople) }.min {
                (HybridVector($0.x, $0.y) + offset - prior).length - 0.08 * $0.confidence
                < (HybridVector($1.x, $1.y) + offset - prior).length - 0.08 * $1.confidence
            }
        }
        if let chosen {
            let observed = HybridVector(chosen.x, chosen.y) + offset
            if let old = point {
                let predicted = old + velocity * age, residual = observed - predicted
                residualError = 0.7 * residualError + 0.3 * residual.length
                point = predicted + residual * 0.78
                velocity = (velocity + residual * ((1 - exp(-age / 0.22)) / age)).clipped(-2, 2)
            } else { point = observed; started = timestamp; exitDirection = nil }
            lastSeen = timestamp; hits += 1; age = 0
            lastLocal = point! - cameraCenter; relativeVelocity = velocity - cameraVelocity
            if selection != nil { selection = point }
        }
        history.append((timestamp, chosen != nil, chosen?.confidence ?? 0)); history.removeAll { $0.0 < timestamp - 0.8 + 1e-8 }
        let coverage = Double(history.filter(\.1).count) / Double(max(1, history.count))
        let span = lastSeen.map { $0 - started } ?? 0
        let confirmed = hits >= 3 && span >= 0.18
        if confirmed && chosen != nil, let point { path.append((timestamp, point)) }
        path.removeAll { timestamp - $0.0 > 1.5 }  // display-only trail
        let scores = history.filter(\.1).map(\.2)
        let confidenceFactor = confidenceWeighting ? max(0, min(1, (scores.reduce(0, +) / Double(max(1, scores.count))
            - Self.confidenceWeightingFloor) / Self.confidenceWeightingRange)) : 1
        let reliability = coverage * (confirmed ? min(1, span / 0.5) : 0) * max(0.35, min(1, 1 - residualError / 0.16)) * max(0, 1 - age / 0.5)
            * confidenceFactor
        if chosen != nil { lastReliability = reliability }
        else if lastReliability >= 0.55 && age <= 0.35 && exitDirection == nil {
            let dx = abs(lastLocal.x) >= 0.37 && lastLocal.x * relativeVelocity.x > 0.03 ? (lastLocal.x > 0 ? 1.0 : -1.0) : 0
            let dy = abs(lastLocal.y) >= 0.37 && lastLocal.y * relativeVelocity.y > 0.03 ? (lastLocal.y > 0 ? 1.0 : -1.0) : 0
            if dx != 0 || dy != 0 {
                exitDirection = HybridVector(dx, dy).unit
                exitTarget = (reference ?? cameraCenter) + exitDirection! * 0.38
                exitUntil = timestamp + exitHold
            }
        }
        let ballTarget: HybridVector? = confirmed && age <= 0.5 ? point.flatMap {
            let predicted = $0 + (velocity * min(age + 0.1, 0.25)).limited(0.15)
            return allowedByField(predicted) ? predicted : nil
        } : nil
        if ballTarget != nil && chosen != nil && reliability >= acquireReliability {
            ballActive = true; exitUntil = -.infinity; exitDirection = nil; groupReturning = false
        }
        else if reliability < retainReliability || ballTarget == nil { ballActive = false }
        if ballTarget == nil { weight = 0 }
        else { weight += max(-3 * step, min(2.2 * step, (ballActive ? 1 : 0) - weight)) }
        var fallback = playerReference
        var mode = playerMode, reason = "Le ballon n’a pas la priorité ; les joueurs visibles guident le cadrage."
        if let exitDirection, let exitTarget, timestamp < exitUntil {
            if let confirmedHeading, confirmedHeading.dot(exitDirection) < -0.5 { exitUntil = timestamp }
            else {
                fallback = exitTarget
                if let playerReference, (playerReference - exitTarget).dot(exitDirection) > 0 { fallback = playerReference }
                mode = "Recherche côté de sortie"; reason = "Une piste fiable a disparu au bord ; le côté de sortie est conservé temporairement."
            }
        }
        var desired = fallback
        if let ballTarget, weight > 0 {
            desired = (fallback ?? cameraCenter) * (1 - weight) + ballTarget * weight
            mode = weight >= 0.85 ? "Ballon continu" : "Transition ballon / joueurs"
            reason = weight >= 0.85 ? "La trajectoire est continue et cohérente ; le ballon pilote." : "Le relais change progressivement la cible, sans réinitialiser la vitesse."
        }
        var localTarget: HybridVector?
        if let desired {
            if reference == nil { reference = cameraCenter }
            reference = reference! + (desired - reference!).clipped(-transitionRate * step, transitionRate * step)
            localTarget = (reference! - offset).clipped(0.02, 0.98)
            if ballActive { playerReference = reference }
        } else {
            mode = "Observation sans indice"; reason = "Aucune cible récente suffisamment fiable ; arrêt du mouvement."
        }
        return HybridDecision(timestamp: timestamp, target: localTarget,
            playerTarget: playerReference.map { $0 - offset }, ballPoint: ballTarget.map { $0 - offset },
            ballWeight: weight, reliability: reliability, coverage: coverage, ballAge: age.isFinite ? age : nil,
            measured: chosen != nil, mode: mode, reason: reason, orientationSupport: support,
            people: worldPeople.map { $0.translated(HybridVector.zero - offset) },
            peopleTimestamp: peopleFresh ? snapshot?.timestamp : nil, motionCompensated: motionValid,
            selectedBall: chosen.map(BallCandidateRecord.init), trail: path.map { $0.1 - offset },
            confidenceFactor: confidenceWeighting ? confidenceFactor : nil,
            groupInView: stayWithGroup ? groupCount : nil, groupPeak: stayWithGroup ? groupPeak : nil)
    }
}
