import Foundation
import CoreGraphics

public enum FrameGeometry {
    /// Vision's EXIF orientations support quarter turns. Keep the preview on the
    /// same turn, with a small hysteresis band around the 45-degree boundaries.
    public static func snappedRotationAngle(_ angle: Double, previous: Int? = nil) -> Int? {
        guard angle.isFinite else { return nil }
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let normalized = wrapped < 0 ? wrapped + 360 : wrapped
        if let previous, [0, 90, 180, 270].contains(previous) {
            let difference = abs(normalized - Double(previous))
            let distance = min(difference, 360 - difference)
            if distance <= 50 { return previous }
        }
        return (Int((normalized / 90).rounded()) * 90) % 360
    }

    /// Clockwise rotation to match AVCaptureVideoPreviewLayer.videoRotationAngle.
    public static func rotate(_ box: CGRect, angle: Int) -> CGRect {
        switch angle {
        case 90: return CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
        case 180: return CGRect(x: 1 - box.maxX, y: 1 - box.maxY, width: box.width, height: box.height)
        case 270: return CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
        default: return box
        }
    }

    /// Convert a touch in the preview into upright image coordinates; reject bars.
    public static func normalizedPoint(_ point: CGPoint, image: CGSize, bounds: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, image.width.isFinite, image.height.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let fitted = aspectFit(image: image, bounds: bounds)
        guard fitted.width > 0, fitted.height > 0, fitted.contains(point) else { return nil }
        return CGPoint(x: (point.x - fitted.minX) / fitted.width, y: (point.y - fitted.minY) / fitted.height)
    }

    public static func aspectFit(image: CGSize, bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let width = image.width * scale, height = image.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
    public static func zoomedPoint(_ point: HybridVector, from oldZoom: Double, to newZoom: Double) -> HybridVector {
        guard oldZoom.isFinite, newZoom.isFinite, oldZoom > 0, newZoom > 0 else { return point }
        return HybridVector(0.5,0.5) + (point - HybridVector(0.5,0.5)) * (newZoom/oldZoom)
    }

    public static func validField(_ points: [HybridVector]) -> Bool {
        guard points.count == 4, points.allSatisfy(\.finite) else { return false }
        var crosses: [Double] = []
        for i in 0..<4 {
            let a = points[(i+1)%4] - points[i], b = points[(i+2)%4] - points[(i+1)%4]
            crosses.append(a.x*b.y-a.y*b.x)
        }
        return crosses.allSatisfy { $0 > 0.002 } || crosses.allSatisfy { $0 < -0.002 }
    }

}
