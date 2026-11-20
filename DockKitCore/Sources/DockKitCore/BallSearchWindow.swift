import Foundation
import CoreGraphics

/// Square detector input taken at native resolution around the tracked ball.
/// `rect` is normalized, top-left origin, upright image, like BallCandidate.
public struct BallSearchWindow: Sendable, Equatable {
    public static let nativeSide: CGFloat = 960
    public static let fullFrame = BallSearchWindow(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    public let rect: CGRect
    public var isFullFrame: Bool { self == Self.fullFrame }

    /// min(960, shorter side) native pixels, centred on the point, kept inside the image.
    public static func centred(x: Double, y: Double, imageWidth: Double, imageHeight: Double) -> BallSearchWindow {
        guard [x, y, imageWidth, imageHeight].allSatisfy(\.isFinite), imageWidth > 0, imageHeight > 0 else {
            return .fullFrame
        }
        let side = min(Double(nativeSide), imageWidth, imageHeight)
        let width = side / imageWidth, height = side / imageHeight
        let left = min(1 - width, max(0, min(1, max(0, x)) - width / 2))
        let top = min(1 - height, max(0, min(1, max(0, y)) - height / 2))
        return BallSearchWindow(rect: CGRect(x: left, y: top, width: width, height: height))
    }

    /// Vision regionOfInterest: normalized, bottom-left origin, upright image.
    public var visionRegion: CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Vision reports boxes relative to the region of interest (bottom-left origin).
    /// Returns the same box relative to the whole upright image, still bottom-left.
    public func fullImageVisionBox(_ box: CGRect) -> CGRect {
        let region = visionRegion
        return CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                      width: box.width * region.width, height: box.height * region.height)
    }
}

/// Chooses the next analysis window from a detector-side BallTrajectoryTracker,
/// fed with the same full-image proposals and threshold as the app's tracker.
public struct BallSearchWindowPolicy: Sendable {
    /// Only a confirmed track measured this recently can drive a local window.
    public static let maximumMeasurementAge: TimeInterval = 0.15
    /// Every 5th analysis covers the whole image, to find a new or missed ball.
    public static let fullFrameInterval = 5
    /// Consecutive local analyses without a proposal above threshold before a full one.
    public static let maximumLocalMisses = 2
    public private(set) var tracker = BallTrajectoryTracker()
    private var localStreak = 0
    private var localMisses = 0

    public init() {}

    public mutating func reset() {
        tracker.reset(); localStreak = 0; localMisses = 0
    }

    public func window(imageWidth: Double, imageHeight: Double, timestamp: TimeInterval) -> BallSearchWindow {
        guard localStreak < Self.fullFrameInterval - 1, localMisses < Self.maximumLocalMisses,
              let ball = tracker.state, timestamp.isFinite, timestamp >= ball.timestamp,
              timestamp - ball.timestamp <= Self.maximumMeasurementAge else { return .fullFrame }
        let dt = timestamp - ball.timestamp
        return .centred(x: ball.x + ball.velocityX * dt, y: ball.y + ball.velocityY * dt,
                        imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Candidates must already be mapped to full-image, top-left coordinates.
    public mutating func record(_ window: BallSearchWindow, candidates: [BallCandidate],
                                timestamp: TimeInterval, now: TimeInterval, minimumConfidence: Double) {
        if window.isFullFrame {
            localStreak = 0; localMisses = 0
        } else {
            localStreak += 1
            localMisses = candidates.contains { $0.confidence >= minimumConfidence } ? 0 : localMisses + 1
        }
        _ = tracker.update(candidates: candidates, timestamp: timestamp, now: now,
                           minimumConfidence: minimumConfidence)
    }
}
