import Foundation

/// A measured ball center in normalized image coordinates, with capture time.
public struct BallTrailPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let timestamp: Double

    public init(x: Double, y: Double, timestamp: Double) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }

    func shifted(x dx: Double, y dy: Double) -> Self {
        Self(x: x + dx, y: y + dy, timestamp: timestamp)
    }
}

/// A short observed trail and image velocity; it does not predict future positions.
public struct BallMotionHistory: Sendable {
    public private(set) var points: [BallTrailPoint] = []
    /// Image widths/second (right is positive) and heights/second (down is positive).
    /// Nil until two distinct capture times are available; zero when stationary.
    public private(set) var velocityX: Double?
    public private(set) var velocityY: Double?

    private var previousUpdateTime: TimeInterval?
    private static let duration: TimeInterval = 0.6
    private static let maximumPoints = 30
    private static let maximumAge: TimeInterval = 0.3
    private static let maximumGap: TimeInterval = 0.25
    private static let maximumJump = 0.35

    public init() {}

    mutating func shiftImage(x: Double, y: Double) {
        points = points.map { $0.shifted(x: x, y: y) }
    }

    public mutating func reset() {
        points.removeAll(keepingCapacity: true)
        velocityX = nil
        velocityY = nil
        previousUpdateTime = nil
    }

    public mutating func update(with target: BallTarget?, now: TimeInterval) {
        guard let target, now.isFinite, target.timestamp.isFinite,
              target.x.isFinite, target.y.isFinite, target.confidence.isFinite,
              (0...1).contains(target.x), (0...1).contains(target.y),
              (0...1).contains(target.confidence),
              now >= target.timestamp, now - target.timestamp <= Self.maximumAge else {
            reset()
            return
        }

        // A clock rewind starts a new trail rather than linking two timelines.
        if previousUpdateTime.map({ now < $0 }) == true
            || points.last.map({ target.timestamp < $0.timestamp }) == true {
            reset()
        }
        previousUpdateTime = now
        points.removeAll { now - $0.timestamp > Self.duration }

        if let previous = points.last {
            // Repeated callbacks for one captured frame never add a new sample.
            guard target.timestamp != previous.timestamp else {
                updateVelocity()
                return
            }
            let gap = target.timestamp - previous.timestamp
            let distance = hypot(target.x - previous.x, target.y - previous.y)
            if gap > Self.maximumGap || distance > Self.maximumJump {
                points.removeAll(keepingCapacity: true)
            }
        }

        points.append(BallTrailPoint(x: target.x, y: target.y, timestamp: target.timestamp))
        if points.count > Self.maximumPoints {
            points.removeFirst(points.count - Self.maximumPoints)
        }
        updateVelocity()
    }

    private mutating func updateVelocity() {
        // The last four deltas are averaged by duration, so uneven capture
        // intervals do not give short, noisy deltas disproportionate weight.
        let recent = points.suffix(5)
        guard recent.count >= 2, let first = recent.first, let last = recent.last else {
            velocityX = nil
            velocityY = nil
            return
        }
        let elapsed = last.timestamp - first.timestamp
        let x = (last.x - first.x) / elapsed
        let y = (last.y - first.y) / elapsed
        guard elapsed > 0, x.isFinite, y.isFinite else {
            velocityX = nil
            velocityY = nil
            return
        }
        velocityX = x
        velocityY = y
    }
}
