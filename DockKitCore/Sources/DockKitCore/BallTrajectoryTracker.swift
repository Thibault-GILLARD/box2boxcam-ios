import Foundation

/// A detector proposal in upright, normalized image coordinates.
public struct BallCandidate: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let confidence: Double

    public init(x: Double, y: Double, width: Double, height: Double, confidence: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.confidence = confidence
    }

    fileprivate var isValid: Bool {
        [x, y, width, height, confidence].allSatisfy { $0.isFinite }
            && (0...1).contains(x) && (0...1).contains(y)
            && width > 0 && width <= 1 && height > 0 && height <= 1
            && (0...1).contains(confidence)
    }
}

public struct TrackedBall: Sendable {
    public let detection: BallCandidate
    public let x: Double
    public let y: Double
    public let velocityX: Double
    public let velocityY: Double
    public let timestamp: TimeInterval
    public let hasVelocity: Bool

    /// Compensate result age plus a short configurable lead. Never move blindly
    /// beyond 100 ms or more than 8% of the image from an accepted measurement.
    public func target(now: TimeInterval, lead: TimeInterval) -> BallTarget? {
        guard now.isFinite, lead.isFinite, now >= timestamp, now - timestamp <= 0.3 else { return nil }
        let horizon = hasVelocity ? min(0.1, max(0, now - timestamp + lead)) : 0
        var dx = velocityX * horizon, dy = velocityY * horizon
        let distance = hypot(dx, dy)
        if distance > 0.08 { dx *= 0.08 / distance; dy *= 0.08 / distance }
        return BallTarget(x: min(1, max(0, x + dx)), y: min(1, max(0, y + dy)),
                          confidence: detection.confidence, timestamp: timestamp)
    }
}

/// Constant image-velocity alpha/beta tracker. Outliers never enter the trail
/// or become motor targets. Missing/rejected frames yield nil, even while the
/// internal track is kept briefly for association on the next real detection.
public struct BallTrajectoryTracker: Sendable {
    public enum Status: Sendable, Equatable { case searching, confirming, tracking, rejected }
    public private(set) var status: Status = .searching
    public private(set) var state: TrackedBall?
    public var points: [BallTrailPoint] { history.points }
    private var history = BallMotionHistory()
    private var pending: BallCandidate?
    private var pendingCount = 0
    private var pendingStart: TimeInterval?
    private var pendingTime: TimeInterval?
    private var pendingFirst: BallTrailPoint?
    private var pendingVelocityX = 0.0
    private var pendingVelocityY = 0.0
    private var previousFrameTime: TimeInterval?
    private var previousNow: TimeInterval?
    public private(set) var selectionLocation: BallTrailPoint?

    public mutating func selectBall(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        reset()
        selectionLocation = BallTrailPoint(x: x, y: y, timestamp: 0)
    }

    public init() {}

    public mutating func reset() {
        state = nil; pending = nil; pendingCount = 0
        selectionLocation = nil
        pendingStart = nil; pendingTime = nil; pendingFirst = nil
        pendingVelocityX = 0; pendingVelocityY = 0
        previousFrameTime = nil; previousNow = nil
        status = .searching
        history.reset()
    }

    public mutating func expire(now: TimeInterval) {
        guard now.isFinite else { reset(); return }
        if let state, now - state.timestamp > 0.3 {
            let selection = selectionLocation
            reset()
            selectionLocation = selection
        } else if let state {
            history.update(with: BallTarget(x: state.x, y: state.y,
                                           confidence: state.detection.confidence,
                                           timestamp: state.timestamp), now: now)
        }
    }

    /// Image translation from the previous frame to this one, in normalized
    /// coordinates. When supplied, velocity describes motion relative to the background.
    public mutating func update(candidates: [BallCandidate], timestamp: TimeInterval,
                                now: TimeInterval, minimumConfidence: Double,
                                cameraShift: (x: Double, y: Double) = (0, 0)) -> TrackedBall? {
        guard now.isFinite, timestamp.isFinite, minimumConfidence.isFinite,
              now >= timestamp, now - timestamp <= 0.3 else { reset(); return nil }
        if previousNow.map({ now < $0 }) == true { reset() }
        // An old or duplicate frame cannot confirm acquisition or alter velocity.
        guard previousFrameTime.map({ timestamp > $0 }) ?? true else { return nil }
        previousNow = now
        previousFrameTime = timestamp
        if cameraShift.x.isFinite, cameraShift.y.isFinite,
           cameraShift.x != 0 || cameraShift.y != 0 {
            shiftImage(x: cameraShift.x, y: cameraShift.y)
        }
        let proposals = candidates.filter { $0.isValid && $0.confidence >= minimumConfidence }

        if let old = state, timestamp - old.timestamp > 0.25 {
            state = nil; history.reset(); pending = nil; pendingCount = 0
        }
        guard let old = state else {
            return acquire(proposals, timestamp: timestamp, now: now)
        }
        let dt = timestamp - old.timestamp
        let predictedX = old.x + old.velocityX * dt
        let predictedY = old.y + old.velocityY * dt
        let gate = min(0.20, 0.035 + 0.75 * max(old.detection.width, old.detection.height) + 0.8 * dt)
        // Prefer temporal proximity over score; a confident branch must not
        // replace a less confident ball continuing along the expected path.
        let nearby = proposals.filter { hypot($0.x - predictedX, $0.y - predictedY) <= gate }
        guard let chosen = nearby.min(by: {
            let a = hypot($0.x - predictedX, $0.y - predictedY)
            let b = hypot($1.x - predictedX, $1.y - predictedY)
            return a - 0.005 * $0.confidence < b - 0.005 * $1.confidence
        }) else {
            status = proposals.isEmpty ? .searching : .rejected
            return nil
        }
        let rx = chosen.x - predictedX, ry = chosen.y - predictedY
        let x = min(1, max(0, predictedX + 0.72 * rx))
        let y = min(1, max(0, predictedY + 0.72 * ry))
        // Scale beta with elapsed capture time rather than callback frequency.
        let beta = 1 - exp(-dt / 0.22)
        var vx = old.velocityX + beta * rx / dt
        var vy = old.velocityY + beta * ry / dt
        let speed = hypot(vx, vy)
        if speed > 6 { vx *= 6 / speed; vy *= 6 / speed }
        let tracked = TrackedBall(detection: chosen, x: x, y: y, velocityX: vx,
                                  velocityY: vy, timestamp: timestamp, hasVelocity: true)
        state = tracked; status = .tracking
        updateSelection(with: tracked)
        append(tracked, now: now)
        return tracked
    }

    private mutating func shiftImage(x dx: Double, y dy: Double) {
        if let old = state {
            state = TrackedBall(detection: old.detection, x: old.x + dx, y: old.y + dy,
                                velocityX: old.velocityX, velocityY: old.velocityY,
                                timestamp: old.timestamp, hasVelocity: old.hasVelocity)
        }
        if let old = pending {
            pending = BallCandidate(x: old.x + dx, y: old.y + dy, width: old.width,
                                    height: old.height, confidence: old.confidence)
        }
        if let point = pendingFirst { pendingFirst = point.shifted(x: dx, y: dy) }
        if let point = selectionLocation { selectionLocation = point.shifted(x: dx, y: dy) }
        history.shiftImage(x: dx, y: dy)
    }

    private mutating func acquire(_ proposals: [BallCandidate], timestamp: TimeInterval,
                                 now: TimeInterval) -> TrackedBall? {
        let pendingIsFresh = pendingTime.map { timestamp - $0 <= 0.15 } ?? false
        // One missed inference must not erase the two preceding coherent samples.
        // There is still no motor target until three real detections confirm a track.
        if proposals.isEmpty {
            if !pendingIsFresh { clearPending() }
            status = pendingCount > 0 ? .confirming : .searching
            return nil
        }
        let chosen: BallCandidate?
        if let previous = pending, let time = pendingTime, pendingIsFresh {
            let gap = timestamp - time
            let px = previous.x + pendingVelocityX * gap
            let py = previous.y + pendingVelocityY * gap
            let gate = min(0.20, 0.035 + 0.75 * max(previous.width, previous.height) + 0.8 * gap)
            chosen = proposals.filter { hypot($0.x - px, $0.y - py) <= gate }
                .min { hypot($0.x - px, $0.y - py) < hypot($1.x - px, $1.y - py) }
            if chosen == nil { clearPending() }
        } else {
            chosen = nil
            clearPending()
        }
        let fallback: BallCandidate?
        if let selection = selectionLocation {
            fallback = proposals.filter { hypot($0.x - selection.x, $0.y - selection.y) <= 0.15 }
                .min { hypot($0.x - selection.x, $0.y - selection.y) < hypot($1.x - selection.x, $1.y - selection.y) }
        } else {
            fallback = proposals.max(by: { $0.confidence < $1.confidence })
        }
        guard let proposal = chosen ?? fallback else { status = .searching; return nil }
        if pendingCount == 0 {
            pendingStart = timestamp
            pendingFirst = BallTrailPoint(x: proposal.x, y: proposal.y, timestamp: timestamp)
        } else if let first = pendingFirst {
            let elapsed = timestamp - first.timestamp
            pendingVelocityX = (proposal.x - first.x) / elapsed
            pendingVelocityY = (proposal.y - first.y) / elapsed
            let speed = hypot(pendingVelocityX, pendingVelocityY)
            if speed > 6 { pendingVelocityX *= 6 / speed; pendingVelocityY *= 6 / speed }
        }
        pending = proposal; pendingTime = timestamp; pendingCount += 1
        status = .confirming
        guard pendingCount >= 3, timestamp - (pendingStart ?? timestamp) >= 0.045 else { return nil }
        let tracked = TrackedBall(detection: proposal, x: proposal.x, y: proposal.y,
                                  velocityX: pendingVelocityX, velocityY: pendingVelocityY,
                                  timestamp: timestamp, hasVelocity: true)
        state = tracked; pending = nil; pendingCount = 0; status = .tracking
        updateSelection(with: tracked)
        append(tracked, now: now)
        return tracked
    }

    private mutating func updateSelection(with tracked: TrackedBall) {
        if selectionLocation != nil {
            selectionLocation = BallTrailPoint(x: tracked.x, y: tracked.y, timestamp: tracked.timestamp)
        }
    }

    private mutating func clearPending() {
        pending = nil; pendingCount = 0; pendingTime = nil; pendingStart = nil; pendingFirst = nil
        pendingVelocityX = 0; pendingVelocityY = 0
    }

    private mutating func append(_ tracked: TrackedBall, now: TimeInterval) {
        history.update(with: BallTarget(x: tracked.x, y: tracked.y,
                                       confidence: tracked.detection.confidence,
                                       timestamp: tracked.timestamp), now: now)
    }
}

/// Detection visibility is independent from trajectory confirmation. This state
/// is used by the app: raw boxes may be visible while the motor target is nil.
public struct BallObservationState: Sendable {
    public private(set) var rawDetection: BallCandidate?
    public private(set) var trackedBall: TrackedBall?
    private var tracker = BallTrajectoryTracker()
    private var lastTimestamp: TimeInterval?
    public var points: [BallTrailPoint] { tracker.points }
    public var status: BallTrajectoryTracker.Status { tracker.status }
    public var selectionLocation: BallTrailPoint? { tracker.selectionLocation }

    public mutating func selectBall(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        rawDetection = nil; trackedBall = nil
        tracker.selectBall(x: x, y: y)
    }

    public init() {}

    public mutating func reset() {
        rawDetection = nil; trackedBall = nil; lastTimestamp = nil
        tracker.reset()
    }

    public mutating func update(candidates: [BallCandidate], timestamp: TimeInterval, now: TimeInterval,
                                minimumConfidence: Double, displayMinimumConfidence: Double = 0.1) {
        guard now.isFinite, timestamp.isFinite, minimumConfidence.isFinite,
              displayMinimumConfidence.isFinite, now >= timestamp, now - timestamp <= 0.3 else {
            reset(); return
        }
        guard lastTimestamp.map({ timestamp > $0 }) ?? true else { return }
        lastTimestamp = timestamp
        let visible = candidates.filter { $0.isValid && $0.confidence >= displayMinimumConfidence }
        trackedBall = tracker.update(candidates: candidates, timestamp: timestamp, now: now,
                                     minimumConfidence: minimumConfidence)
        if let selection = tracker.selectionLocation {
            rawDetection = visible.filter { hypot($0.x - selection.x, $0.y - selection.y) <= 0.15 }
                .min { hypot($0.x - selection.x, $0.y - selection.y) < hypot($1.x - selection.x, $1.y - selection.y) }
        } else {
            rawDetection = visible.max { $0.confidence < $1.confidence }
        }
    }

    public mutating func expire(now: TimeInterval) {
        guard now.isFinite else { reset(); return }
        tracker.expire(now: now)
        if lastTimestamp.map({ now - $0 > 0.3 }) == true {
            rawDetection = nil; trackedBall = nil
        }
    }
}
