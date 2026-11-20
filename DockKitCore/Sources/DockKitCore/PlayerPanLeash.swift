import Foundation

/// Keeps a pan driven by the players alone close to where the ball last drove the camera.
///
/// Film of 18 Nov 2026, 20:35: with the ball visible but without weight, players mode led the target
/// toward people standing next to the camera and panned at full speed from +3° to −80° in 4 s,
/// away from the play. Here the allowed range around the last ball direction starts at 30° and
/// widens by 2° per second without the ball (play can move), up to 80°. Azimuths are world
/// angles in radians, counter-clockwise seen from above; rates use the same sign.
public struct PlayerPanLeash: Sendable {
    public var baseRange = 30 * Double.pi / 180
    public var growthPerSecond = 2 * Double.pi / 180
    public var maximumRange = 80 * Double.pi / 180
    /// World azimuth of the camera the last time the ball drove it; nil until then.
    public private(set) var anchor: Double?
    private var ballLostAt: Double?

    public init() {}

    public mutating func reset() { anchor = nil; ballLostAt = nil }

    /// Current allowed half range, nil while the ball drives or before it ever did.
    public func range(now: Double) -> Double? {
        guard anchor != nil, let ballLostAt else { return nil }
        return min(maximumRange, baseRange + growthPerSecond * max(0, now - ballLostAt))
    }

    /// The azimuth rate allowed for this command. Moving back toward the anchor is always free.
    public mutating func limit(azimuthRate: Double, azimuth: Double, ballDriving: Bool, now: Double) -> Double {
        guard azimuthRate.isFinite, azimuth.isFinite, now.isFinite else { return azimuthRate.isFinite ? azimuthRate : 0 }
        if ballDriving { anchor = azimuth; ballLostAt = nil; return azimuthRate }
        guard let anchor else { return azimuthRate }
        if ballLostAt == nil { ballLostAt = now }
        let half = range(now: now) ?? baseRange
        return AngleLimits.clamp(velocity: azimuthRate, position: Self.wrapped(azimuth - anchor), lower: -half, upper: half)
    }

    /// Angle in (−π, π].
    public static func wrapped(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi } else if value <= -.pi { value += 2 * .pi }
        return value
    }
}
