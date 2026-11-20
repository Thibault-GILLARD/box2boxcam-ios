import Foundation

/// A direction or point in a gravity-aligned world frame: z points up, x and y are horizontal.
public struct PitchVector3: Codable, Sendable, Equatable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let up = PitchVector3(0, 0, 1)
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public var normalized: PitchVector3? {
        let l = length
        return l > 1e-9 && finite ? PitchVector3(x / l, y / l, z / l) : nil
    }
    public func dot(_ o: Self) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Self) -> Self { Self(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
    public static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Self, k: Double) -> Self { Self(a.x * k, a.y * k, a.z * k) }
    /// Horizontal angle, counter-clockwise seen from above.
    public var azimuth: Double { atan2(y, x) }
}

/// The camera at one instant: its optical axis in the world frame and a pinhole model of the
/// upright image. The image is assumed level (no roll), which the gimbal provides.
public struct CameraPose: Sendable {
    public let axis: PitchVector3
    /// Image right and image up, in the world frame.
    public let right: PitchVector3
    public let up: PitchVector3
    /// Focal length in pixels of the upright image, and its size in pixels.
    public let focal: Double
    public let width: Double
    public let height: Double

    /// Nil for a camera pointing straight up or down (no level image) or an invalid model.
    public init?(axis: PitchVector3, focal: Double, width: Double, height: Double) {
        guard let axis = axis.normalized, let right = axis.cross(.up).normalized,
              focal.isFinite, focal > 0, width > 0, height > 0 else { return nil }
        self.axis = axis
        self.right = right
        self.up = right.cross(axis)
        self.focal = focal; self.width = width; self.height = height
    }

    /// Focal length from a horizontal field of view measured on the long side of the sensor.
    public static func focal(longSideFieldOfViewDegrees fov: Double, zoom: Double, width: Double, height: Double) -> Double? {
        guard fov.isFinite, fov > 1, fov < 179, zoom.isFinite, zoom > 0 else { return nil }
        return max(width, height) / (2 * tan(fov * .pi / 360)) * zoom
    }

    /// World direction through a point of the image, normalized coordinates with y down.
    public func ray(_ point: HybridVector) -> PitchVector3 {
        let dx = (point.x - 0.5) * width / focal, dy = (point.y - 0.5) * height / focal
        return axis + right * dx - up * dy
    }

    /// Normalized image point of a world direction; nil when it is behind the camera.
    public func project(_ direction: PitchVector3) -> HybridVector? {
        let depth = direction.dot(axis)
        guard depth > 1e-6 else { return nil }
        let dx = direction.dot(right) / depth * focal, dy = -direction.dot(up) / depth * focal
        let point = HybridVector(0.5 + dx / width, 0.5 + dy / height)
        return point.finite ? point : nil
    }
}

/// A pitch located from the foot of each goal (and optionally the centre spot), seen by a camera
/// standing on a touchline. Ground points are expressed with the camera's foot at the origin and its
/// height as the unit length, so no pitch dimension is needed: the shape is scale free.
/// The two goals give the long axis and the length; the camera's distance to that axis gives the
/// half width, because the camera stands on a touchline.
public struct PitchCalibration: Codable, Sendable {
    /// Marked centre spot, when the user marked one (a consistency check only).
    public let centerSpot: HybridVector?
    public let leftGoal: HybridVector
    public let rightGoal: HybridVector
    public let middle: HybridVector
    /// Unit vector from the left goal to the right goal.
    public let along: HybridVector
    /// Unit vector from the camera toward the far touchline.
    public let away: HybridVector
    public let halfLength: Double
    /// Distance from the camera to the long axis: half the width if the camera is on a touchline.
    public let halfWidth: Double
    /// Distance between the marked centre spot and the middle of the goals, over half the length.
    /// Near zero for a consistent calibration; zero when no centre spot was marked.
    public let centerError: Double
    /// World azimuths of the middle of the pitch (the reference for relative azimuths) and of the goals.
    public let centerAzimuth: Double
    public let leftAzimuth: Double
    public let rightAzimuth: Double

    /// Where a ray meets the ground; nil at or above the horizon.
    public static func ground(_ ray: PitchVector3) -> HybridVector? {
        guard ray.finite, ray.z < -1e-4 else { return nil }
        let point = HybridVector(ray.x / -ray.z, ray.y / -ray.z)
        return point.finite ? point : nil
    }

    public init?(leftGoal: PitchVector3, rightGoal: PitchVector3, centerSpot: PitchVector3? = nil) {
        guard let l = Self.ground(leftGoal), let r = Self.ground(rightGoal) else { return nil }
        var c: HybridVector?
        if let centerSpot { guard let point = Self.ground(centerSpot) else { return nil }; c = point }
        let axis = r - l
        guard axis.length > 1e-3 else { return nil }
        let middle = (l + r) * 0.5
        let along = axis.unit
        var away = HybridVector(-along.y, along.x)
        var distance = middle.dot(away)
        if distance < 0 { away = away * -1; distance = -distance }
        guard distance > 1e-3 else { return nil }
        self.centerSpot = c; self.leftGoal = l; self.rightGoal = r
        self.middle = middle; self.along = along; self.away = away
        halfLength = axis.length / 2
        halfWidth = distance
        centerError = c.map { ($0 - middle).length / (axis.length / 2) } ?? 0
        centerAzimuth = atan2(middle.y, middle.x)
        leftAzimuth = leftGoal.azimuth
        rightAzimuth = rightGoal.azimuth
        behindGoal = false
    }

    /// Camera behind a goal, filming its half: the foot of the camera's own goal and of the far goal
    /// (middle, between the posts) give the long axis and the length; the width follows from the
    /// usual width-to-length ratio. The rectangle is then stored like the touchline one, with the
    /// goal line as `along` (left to right as seen by the camera) and the long axis as `away`:
    /// `halfLength` is half the pitch width, `halfWidth` half the pitch length, the camera's own line
    /// is its goal line, and `leftGoal` / `rightGoal` hold the corners of that goal line, whose
    /// azimuths bound the pan.
    public init?(nearGoal: PitchVector3, farGoal: PitchVector3, widthToLength: Double = 68.0 / 105.0) {
        guard var n = Self.ground(nearGoal), var f = Self.ground(farGoal), widthToLength > 0 else { return nil }
        // The camera's own goal is the closer one; swapped taps are fixed.
        if f.length < n.length { swap(&n, &f) }
        let axis = f - n
        guard axis.length > 1e-3 else { return nil }
        let away = axis.unit
        let along = HybridVector(away.y, -away.x)  // image right when facing the far goal
        let halfPitchWidth = axis.length * widthToLength / 2
        let left = n - along * halfPitchWidth, right = n + along * halfPitchWidth
        let middle = (n + f) * 0.5
        guard middle.finite, left.finite, right.finite else { return nil }
        self.centerSpot = nil; self.leftGoal = left; self.rightGoal = right
        self.middle = middle; self.along = along; self.away = away
        halfLength = halfPitchWidth
        halfWidth = axis.length / 2
        centerError = 0
        centerAzimuth = atan2(middle.y, middle.x)
        leftAzimuth = atan2(left.y, left.x)
        rightAzimuth = atan2(right.y, right.x)
        behindGoal = true
    }

    /// Built from the two goals seen from behind one of them, not from a touchline.
    public let behindGoal: Bool

    /// Two goal taps, in either order. Behind a goal both goals lie in nearly the same direction;
    /// more than 35° apart, the camera stands on a touchline or its extension (18 Nov 2026: in a
    /// corner, next to a goal), where the touchline model measures the width instead of guessing it.
    /// The goals are put in order, so the pan limits apply.
    public static func fromGoals(_ first: PitchVector3, _ second: PitchVector3, preferBehindGoal: Bool) -> PitchCalibration? {
        let separation = abs(PlayerPanLeash.wrapped(first.azimuth - second.azimuth))
        if preferBehindGoal, separation < 35 * .pi / 180 { return PitchCalibration(nearGoal: first, farGoal: second) }
        guard let pitch = PitchCalibration(leftGoal: first, rightGoal: second) else { return nil }
        return pitch.goalsInOrder ? pitch : PitchCalibration(leftGoal: second, rightGoal: first)
    }

    /// Position on the pitch: along the length (0 at halfway, negative toward the left goal) and
    /// across (0 on the long axis, −halfWidth on the camera's touchline, +halfWidth on the far one).
    public func pitchCoordinates(_ ground: HybridVector) -> (along: Double, across: Double) {
        let offset = ground - middle
        return (offset.dot(along), offset.dot(away))
    }

    /// Margins are fractions of the half length and half width.
    public func contains(_ ground: HybridVector, lengthMargin: Double = 0.12, widthMargin: Double = 0.15) -> Bool {
        let p = pitchCoordinates(ground)
        return abs(p.along) <= halfLength * (1 + lengthMargin) && abs(p.across) <= halfWidth * (1 + widthMargin)
    }

    /// A foot (or any ground contact) seen along this ray is on the pitch, margins included.
    /// A ray at or above the horizon is never on the pitch.
    public func containsFoot(_ ray: PitchVector3, lengthMargin: Double = 0.12, widthMargin: Double = 0.15) -> Bool {
        guard let point = Self.ground(ray) else { return false }
        return contains(point, lengthMargin: lengthMargin, widthMargin: widthMargin)
    }

    /// A ball (or anything) seen along this ray is behind the camera's own touchline, beyond the margin.
    /// Safe for airborne balls: their ground projection only moves away from the camera, so a ball in
    /// the air over the pitch never projects behind that line. A ray above the horizon is kept.
    public func isBehindNearTouchline(_ ray: PitchVector3, margin: Double = 0.1) -> Bool {
        guard let point = Self.ground(ray) else { return false }
        return pitchCoordinates(point).across < -halfWidth * (1 + margin)
    }

    public func groundPoint(along a: Double, across c: Double) -> HybridVector { middle + along * a + away * c }

    /// Pitch markings as ground polylines: outline, halfway line, centre circle, both penalty areas
    /// and goal areas. Sizes are those of a 105 × 68 m pitch, scaled to this length and width.
    public func markings(circleSegments: Int = 48) -> [[HybridVector]] {
        // Drawn in (long axis, cross axis) coordinates; behind a goal the long axis is `away`.
        let L = behindGoal ? halfWidth : halfLength, W = behindGoal ? halfLength : halfWidth
        func groundPoint(along a: Double, across c: Double) -> HybridVector {
            behindGoal ? self.groundPoint(along: c, across: a) : self.groundPoint(along: a, across: c)
        }
        func line(_ points: [(Double, Double)]) -> [HybridVector] { points.map { groundPoint(along: $0.0, across: $0.1) } }
        var result = [line([(-L, -W), (L, -W), (L, W), (-L, W), (-L, -W)]), line([(0, -W), (0, W)])]
        let radius = 2 * W * 9.15 / 68
        let segments = max(8, circleSegments)
        result.append((0...segments).map { k -> HybridVector in
            let t = Double(k) / Double(segments) * 2 * .pi
            return groundPoint(along: radius * cos(t), across: radius * sin(t))
        })
        for side in [-1.0, 1.0] {
            for (depth, width) in [(16.5, 40.32), (5.5, 18.32)] {
                let d = 2 * L * depth / 105, w = W * width / 68
                result.append(line([(side * L, -w), (side * (L - d), -w), (side * (L - d), w), (side * L, w)]))
            }
        }
        return result
    }

    /// Ground point back to a world direction from the camera (height 1).
    public static func direction(to ground: HybridVector) -> PitchVector3 { PitchVector3(ground.x, ground.y, -1) }

    /// Signed angle from the centre spot, in (−π, π]: positive toward the left goal for a level image.
    public func relativeAzimuth(_ azimuth: Double) -> Double {
        var value = (azimuth - centerAzimuth).truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi } else if value <= -.pi { value += 2 * .pi }
        return value
    }

    /// The left goal must be counter-clockwise of the right one; otherwise the marks were swapped
    /// or the image is not level.
    public var goalsInOrder: Bool { relativeAzimuth(leftAzimuth) > relativeAzimuth(rightAzimuth) }
}
