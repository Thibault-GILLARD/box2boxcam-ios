import Foundation

public struct HighlightMarker: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case manual, fastBall, ballReacquired }
    /// Seconds from the start of the video.
    public var time: Double
    public var kind: Kind
    public var label: String
    public init(time: Double, kind: Kind) {
        self.time = time; self.kind = kind
        switch kind {
        case .manual: label = "Moment marqué"
        case .fastBall: label = "Ballon rapide"
        case .ballReacquired: label = "Ballon retrouvé"
        }
    }
}

/// Two automatic rules on signals already computed per analysis, at most one marker every 8 s:
/// sustained fast ball (smoothed speed >= 0.8 frame/s for 0.5 s) and a confident track
/// returning after >= 3 s without one (only after a first track was seen).
public struct HighlightDetector: Sendable {
    public static let minimumInterval = 8.0
    public static let fastSpeed = 0.8
    public static let fastDuration = 0.5
    public static let longLoss = 3.0
    private var previous: (Double, HybridVector)?
    private var speed = 0.0
    private var fastSince: Double?
    private var lastConfident: Double?
    private var lastMarker = -Double.infinity

    public init() {}
    public mutating func reset() { self = Self() }

    /// - Parameter ball: confidently tracked ball position (camera-compensated when available), else nil.
    public mutating func update(timestamp: Double, ball: HybridVector?) -> HighlightMarker.Kind? {
        guard timestamp.isFinite else { return nil }
        var event: HighlightMarker.Kind?
        if let ball, ball.finite {
            if let lastConfident, timestamp - lastConfident >= Self.longLoss { event = .ballReacquired }
            lastConfident = timestamp
            if let (time, point) = previous, timestamp > time, timestamp - time <= 0.5,
               (ball - point).length <= 0.25 {
                let dt = timestamp - time
                let alpha = 1 - exp(-dt / 0.3)
                speed += ((ball - point).length / dt - speed) * alpha
            } else { speed = 0; fastSince = nil }
            previous = (timestamp, ball)
            if speed >= Self.fastSpeed {
                if fastSince == nil { fastSince = timestamp }
                if timestamp - fastSince! >= Self.fastDuration, event == nil { event = .fastBall }
            } else { fastSince = nil }
        } else { previous = nil; speed = 0; fastSince = nil }
        guard let event, timestamp - lastMarker >= Self.minimumInterval else { return nil }
        lastMarker = timestamp
        fastSince = nil
        return event
    }
}
