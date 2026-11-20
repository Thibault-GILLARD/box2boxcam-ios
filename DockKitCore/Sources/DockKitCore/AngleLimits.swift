import Foundation

/// Pan (and optional low tilt) limits on the stand's own angular positions, in radians.
/// Only the outward velocity is reduced: linearly inside the soft zone, zero at or beyond
/// a limit. Moving back toward the allowed range is never restricted.
/// Assumes a positive velocity increases the reported position (DockKit's convention).
public enum AngleLimits {
    public static let softZone = 5 * Double.pi / 180

    /// - Parameters: lower/upper are optional bounds; nil leaves that side free.
    public static func clamp(velocity: Double, position: Double,
                             lower: Double?, upper: Double?, softZone: Double = softZone) -> Double {
        guard velocity.isFinite, position.isFinite else { return 0 }
        let zone = max(1e-6, softZone)
        if velocity > 0, let upper, upper.isFinite {
            return velocity * max(0, min(1, (upper - position) / zone))
        }
        if velocity < 0, let lower, lower.isFinite {
            return velocity * max(0, min(1, (position - lower) / zone))
        }
        return velocity
    }

    /// Yaw stays between the two stored limits, whichever order they were recorded in.
    public static func clampYaw(velocity: Double, yaw: Double, limits: (Double, Double)) -> Double {
        clamp(velocity: velocity, position: yaw, lower: min(limits.0, limits.1), upper: max(limits.0, limits.1))
    }

    /// Low tilt limit; `downSign` is the sign of a pitch velocity that lowers the camera.
    public static func clampPitch(velocity: Double, pitch: Double, lowLimit: Double, downSign: Double) -> Double {
        downSign < 0 ? clamp(velocity: velocity, position: pitch, lower: lowLimit, upper: nil)
                     : clamp(velocity: velocity, position: pitch, lower: nil, upper: lowLimit)
    }
}
