import Foundation

/// Image coordinates have their origin at the top left; no trajectory prediction.
public struct BallTarget: Sendable {
    public let x: Double
    public let y: Double
    public let confidence: Double
    public let timestamp: TimeInterval

    public init(x: Double, y: Double, confidence: Double, timestamp: TimeInterval) {
        self.x = x; self.y = y; self.confidence = confidence; self.timestamp = timestamp
    }
}

public struct BallFollowPolicy {
    public var deadZone = 0.005 // Half-width/height: central 1% of the image.
    public var maximumSpeed = 0.20
    public var minimumConfidence = 0.35
    public var maximumAge = 0.30
    public var invertYaw = false
    public var invertPitch = false
    private var previous = MotorVelocity.zero
    private var previousTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        previous = .zero
        previousTime = nil
    }

    public mutating func velocity(for target: BallTarget?, now: TimeInterval) -> MotorVelocity {
        guard let target, now.isFinite, target.timestamp.isFinite,
              target.x.isFinite, target.y.isFinite, target.confidence.isFinite,
              (0...1).contains(target.x), (0...1).contains(target.y),
              target.confidence >= minimumConfidence,
              now >= target.timestamp, now - target.timestamp <= maximumAge else {
            reset()
            return .zero
        }
        let dt = min(0.1, max(0, now - (previousTime ?? (now - 0.05))))
        let zone = min(0.10, max(0, deadZone))
        let cap = min(0.3, max(0, maximumSpeed))
        func axis(_ center: Double, gain: Double, previous: Double, inverted: Bool) -> Double {
            let error = center - 0.5
            // Stop an axis as soon as the ball enters its tolerance band.
            guard abs(error) > zone else { return 0 }
            let desired = max(-cap, min(cap, error * gain)) * (inverted ? -1 : 1)
            // Bound acceleration to avoid a jump when a detection moves.
            let step = 1.2 * dt
            return max(-cap, min(cap, max(previous - step, min(previous + step, desired))))
        }
        previous = MotorVelocity(
            pitch: axis(target.y, gain: 1.5, previous: previous.pitch, inverted: invertPitch),
            yaw: axis(target.x, gain: 1.8, previous: previous.yaw, inverted: invertYaw))
        previousTime = now
        return previous
    }
}
