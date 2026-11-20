import AVFoundation
import SwiftUI
import UIKit

/// One accent (warm yellow, legible on sunlit grass) plus white; dark halos keep strokes readable.
enum OverlayStyle {
    static let accent = UIColor(red: 0.875, green: 1, blue: 0, alpha: 1)
    static let halo = UIColor.black.withAlphaComponent(0.32).cgColor
    static let player = UIColor(red: 0.416, green: 0.353, blue: 0.804, alpha: 1)
    static let jointConfidence = 0.55
}

@MainActor
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let ballBox: CGRect?
    let ballConfidence: Double?
    let proposalBoxes: [CGRect]
    let selectionLocation: BallTrailPoint?
    let onSelectBall: (CGPoint) -> Void
    let trail: [BallTrailPoint]
    let anticipatedTarget: BallTrailPoint?
    let showTrail: Bool
    let imageSize: CGSize
    let following: Bool
    let onRotation: (Int) -> Void
    let onInterfaceOrientation: (UIInterfaceOrientation) -> Void
    var ballConfirmed = false
    var hybrid: HybridDecision? = nil
    var scoredProposals: [BallCandidateRecord] = []
    var showDetections = true
    var showSkeletons = true
    var showOrientations = true
    var showDecision = true
    var zoomFactor: CGFloat = 1
    var onZoom: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    /// Calibrated pitch markings, normalized image coordinates.
    var pitchLines: [[CGPoint]] = []

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.disconnectPreview()
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.ballBox = ballBox
        view.ballConfidence = ballConfidence
        view.ballConfirmed = ballConfirmed
        view.proposalBoxes = proposalBoxes
        view.selectionLocation = selectionLocation
        view.onSelectBall = onSelectBall
        view.trail = trail
        view.anticipatedTarget = anticipatedTarget
        view.showTrail = showTrail
        view.imageSize = imageSize
        view.following = following
        view.onRotation = onRotation
        view.onInterfaceOrientation = onInterfaceOrientation
        view.hybrid = hybrid
        view.scoredProposals = scoredProposals
        view.showDetections = showDetections
        view.showSkeletons = showSkeletons
        view.showOrientations = showOrientations
        view.showDecision = showDecision
        view.zoomFactor = zoomFactor
        view.onZoom = onZoom
        view.pitchLines = pitchLines
        view.setNeedsLayout()
        view.reportDiagnosticUpdate()
    }
}

/// CADisplayLink retains its target; this proxy keeps the preview releasable.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: PreviewView?
    @objc func step(_ link: CADisplayLink) { owner?.step(link) }
}

final class PreviewView: UIView {
    // Keep annotations outside AVFoundation's video layer. Its internal layers
    // can be recreated when capture starts, rotates or changes camera.
    let previewLayer = AVCaptureVideoPreviewLayer()
    var ballBox: CGRect?
    var ballConfidence: Double?
    var ballConfirmed = false
    var proposalBoxes: [CGRect] = []
    var selectionLocation: BallTrailPoint?
    var onSelectBall: ((CGPoint) -> Void)?
    var trail: [BallTrailPoint] = []
    var anticipatedTarget: BallTrailPoint?
    var showTrail = true
    var imageSize = CGSize(width: 720, height: 1280)
    var following = false
    var onRotation: ((Int) -> Void)?
    var onInterfaceOrientation: ((UIInterfaceOrientation) -> Void)?
    var hybrid: HybridDecision?
    var scoredProposals: [BallCandidateRecord] = []
    var showDetections = true
    var showSkeletons = true
    var showOrientations = true
    var showDecision = true
    var zoomFactor: CGFloat = 1
    var onZoom: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    var pitchLines: [[CGPoint]] = []
    private let pitchLayer = CAShapeLayer()
    private var pinchStart: CGFloat = 1
    private var lastPinchUpdate = 0.0
    private var lastInterfaceOrientation: UIInterfaceOrientation?
    private var lastAngle: Int?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var rotationConnection: AVCaptureConnection?
    private var rotationDeviceID: String?
    private var rotationRevision: UInt64 = 0

    // Ball: a ring that glides between detections at display rate and fades out on loss.
    private let ballGroup = CALayer()
    private let ringHalo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var ringTarget: CGPoint?      // normalized
    private var ringShown = CGPoint.zero  // normalized
    private var ringRadiusTarget: CGFloat = 10
    private var ringRadius: CGFloat = 10
    private var ringPathRadius: CGFloat = -1
    private var ringVisible = false
    // Comet tail: opacity buckets from tail to head over a tapering filled ribbon.
    private let trailBuckets: [CAShapeLayer] = (0..<7).map { _ in CAShapeLayer() }
    private let trailGlow = CAShapeLayer()
    private let prediction = CAShapeLayer()
    private let footRings = CAShapeLayer()
    // Players: smoothed joints (17 + feet) matched between pose snapshots.
    private struct Body {
        var shown: [CGPoint]
        var target: [CGPoint]
        var confidence: [Double]
        var rays: [(angle: CGFloat, selected: Bool)]
        var height: Double
    }
    private var bodies: [Body] = []
    private let skeletonHalo = CAShapeLayer()
    private let skeleton = CAShapeLayer()
    private let joints = CAShapeLayer()
    private let skeletonGhost = CAShapeLayer()
    private let orientations = CAShapeLayer()
    private let ambiguousOrientations = CAShapeLayer()
    // Decision markers and utilities.
    private let decisionHalo = CAShapeLayer()
    private let hybridTargets = CAShapeLayer()
    private let playerTarget = CAShapeLayer()
    private let otherProposals = CAShapeLayer()
    private let selectionMarker = CAShapeLayer()
    private let centerReticle = CAShapeLayer()
    private let confidenceLabel = UILabel()
    private var scoreLabels: [UILabel] = []
    private var imageRect = CGRect.zero
    private var displayLink: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    #if DEBUG
    private var lastDiagnosticUpdate = -Double.infinity
    #endif
    private var annotationLayers: [CAShapeLayer] {
        [pitchLayer, footRings, skeletonGhost, skeletonHalo, skeleton, joints, ambiguousOrientations, orientations, otherProposals, trailGlow]
            + trailBuckets + [prediction, centerReticle, selectionMarker, decisionHalo, playerTarget, hybridTargets]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(previewLayer)
        for shape in annotationLayers {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
        }
        ballGroup.addSublayer(ringHalo); ballGroup.addSublayer(ring)
        ballGroup.opacity = 0
        layer.insertSublayer(ballGroup, below: decisionHalo)
        for shape in [ringHalo, ring] {
            shape.fillColor = UIColor.clear.cgColor; shape.lineCap = .round
        }
        ringHalo.strokeColor = OverlayStyle.halo; ringHalo.lineWidth = 6
        ring.lineWidth = 4
        ring.shadowColor = OverlayStyle.accent.cgColor; ring.shadowOpacity = 0
        ring.shadowRadius = 5; ring.shadowOffset = .zero
        trailGlow.strokeColor = OverlayStyle.accent.withAlphaComponent(0.2).cgColor
        pitchLayer.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
        pitchLayer.lineWidth = 1.5
        pitchLayer.shadowColor = UIColor.black.cgColor; pitchLayer.shadowOpacity = 0.6
        pitchLayer.shadowRadius = 1; pitchLayer.shadowOffset = .zero
        footRings.strokeColor = OverlayStyle.player.withAlphaComponent(0.85).cgColor
        footRings.fillColor = OverlayStyle.player.withAlphaComponent(0.14).cgColor
        footRings.lineWidth = 1.5
        for (index, bucket) in trailBuckets.enumerated() {
            bucket.fillColor = OverlayStyle.accent.cgColor
            bucket.lineWidth = 0
            bucket.opacity = Float(0.3 + 0.6 * Double(index + 1) / Double(trailBuckets.count))
        }
        prediction.strokeColor = OverlayStyle.accent.withAlphaComponent(0.7).cgColor
        prediction.lineWidth = 1.25
        prediction.lineDashPattern = [1, 4]
        centerReticle.lineWidth = 1.5
        centerReticle.shadowColor = UIColor.black.cgColor
        centerReticle.shadowOpacity = 0.65
        centerReticle.shadowRadius = 1
        centerReticle.shadowOffset = .zero
        otherProposals.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
        otherProposals.lineWidth = 1
        otherProposals.lineCap = .butt
        otherProposals.lineDashPattern = [3, 3]
        selectionMarker.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        selectionMarker.lineWidth = 1.25
        selectionMarker.lineDashPattern = [3, 3]
        skeletonHalo.strokeColor = OverlayStyle.halo; skeletonHalo.lineWidth = 4.5
        skeleton.strokeColor = OverlayStyle.player.withAlphaComponent(0.9).cgColor; skeleton.lineWidth = 2
        skeletonGhost.strokeColor = skeleton.strokeColor; skeletonGhost.lineWidth = 2
        skeletonGhost.opacity = 0
        joints.fillColor = UIColor.white.withAlphaComponent(0.92).cgColor
        joints.strokeColor = OverlayStyle.halo; joints.lineWidth = 1
        orientations.fillColor = OverlayStyle.accent.withAlphaComponent(0.9).cgColor
        ambiguousOrientations.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        for wedge in [orientations, ambiguousOrientations] { wedge.strokeColor = OverlayStyle.halo; wedge.lineWidth = 1 }
        decisionHalo.strokeColor = OverlayStyle.halo; decisionHalo.lineWidth = 3.5
        hybridTargets.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor; hybridTargets.lineWidth = 1.5
        playerTarget.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor; playerTarget.lineWidth = 1.25
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectBallFromTap))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchCamera))
        tap.require(toFail: pinch)
        addGestureRecognizer(tap); addGestureRecognizer(pinch)
        clipsToBounds = true
        confidenceLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        confidenceLabel.textColor = OverlayStyle.accent
        confidenceLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        confidenceLabel.textAlignment = .center
        confidenceLabel.layer.cornerRadius = 3
        confidenceLabel.clipsToBounds = true
        confidenceLabel.adjustsFontSizeToFitWidth = true
        confidenceLabel.minimumScaleFactor = 0.7
        confidenceLabel.isHidden = true
        addSubview(confidenceLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reportDiagnosticUpdate() {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastDiagnosticUpdate >= 2 else { return }
        lastDiagnosticUpdate = now
        print("[PitchLens aperçu] \(scoredProposals.count) proposition(s) · boîte \(ballBox != nil) · score \(ballConfidence ?? 0) · \(hybrid?.people.count ?? 0) joueur(s) · boîtes activées \(showDetections)")
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            invalidateRotationCoordinator()
            displayLink?.isPaused = true
        } else {
            setNeedsLayout()
        }
    }

    @objc private func selectBallFromTap(_ gesture: UITapGestureRecognizer) {
        guard window != nil,
              let point = FrameGeometry.normalizedPoint(gesture.location(in: self), image: imageSize, bounds: bounds) else { return }
        onSelectBall?(point)
    }

    @objc private func pinchCamera(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStart = zoomFactor }
        let now = CACurrentMediaTime()
        if gesture.state == .changed && now - lastPinchUpdate < 1.0/30 { return }
        lastPinchUpdate = now
        onZoom?(pinchStart * gesture.scale, gesture.state)
    }

    func disconnectPreview() {
        invalidateRotationCoordinator()
        displayLink?.invalidate(); displayLink = nil
        onZoom?(zoomFactor, .cancelled)
        onZoom = nil
        onSelectBall = nil
        onRotation = nil
        onInterfaceOrientation = nil
        previewLayer.session = nil
    }

    private func invalidateRotationCoordinator() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        rotationConnection = nil
        rotationDeviceID = nil
        rotationRevision += 1
        lastAngle = nil
        lastInterfaceOrientation = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshRotationCoordinator()
        reportInterfaceOrientation()
        applyPreviewRotation()
        let image = FrameGeometry.aspectFit(image: imageSize, bounds: bounds)
        let geometryChanged = image != imageRect
        imageRect = image
        func displayRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: image.minX + normalized.minX * image.width,
                   y: image.minY + normalized.minY * image.height,
                   width: normalized.width * image.width, height: normalized.height * image.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        // Explicit bounds also keep clipped full-screen previews renderable.
        for shape in annotationLayers { shape.frame = bounds }
        ballGroup.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
        updateBallTarget(snap: geometryChanged)
        updateBodies(snap: geometryChanged)
        let pitchPath = CGMutablePath()
        for line in pitchLines where line.count > 1 {
            pitchPath.move(to: display(line[0]))
            for point in line.dropFirst() { pitchPath.addLine(to: display(point)) }
        }
        pitchLayer.path = pitchPath
        if showTrail, let anticipatedTarget, let last = trail.last {
            let from = display(HybridVector(last.x, last.y))
            let to = display(HybridVector(anticipatedTarget.x, anticipatedTarget.y))
            let path = CGMutablePath()
            path.move(to: from); path.addLine(to: to)
            path.addEllipse(in: CGRect(x: to.x - 2, y: to.y - 2, width: 4, height: 4))
            prediction.path = path
        } else {
            prediction.path = nil
        }
        centerReticle.strokeColor = (following ? OverlayStyle.accent : UIColor.white.withAlphaComponent(0.7)).cgColor
        let center = display(HybridVector(0.5, 0.5))
        let arm = min(7, min(image.width, image.height) / 8)
        let reticle = CGMutablePath()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            reticle.move(to: CGPoint(x: center.x + dx * 2.5, y: center.y + dy * 2.5))
            reticle.addLine(to: CGPoint(x: center.x + dx * arm, y: center.y + dy * arm))
        }
        centerReticle.path = reticle
        let candidatesPath = CGMutablePath()
        for box in proposalBoxes where showDetections { candidatesPath.addRect(displayRect(box)) }
        otherProposals.path = candidatesPath
        if let point = selectionLocation {
            let center = display(HybridVector(point.x, point.y))
            selectionMarker.path = CGPath(ellipseIn: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22), transform: nil)
        } else { selectionMarker.path = nil }
        positionConfidenceLabel(image: image, displayRect: showDetections ? ballBox.map(displayRect) : nil)
        drawDecision()
        drawScores(image: image)
        renderAnimated()
        CATransaction.commit()
        if needsAnimation { startDisplayLink() }
    }

    private func display(_ point: HybridVector) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * imageRect.width, y: imageRect.minY + point.y * imageRect.height)
    }

    private func display(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * imageRect.width, y: imageRect.minY + point.y * imageRect.height)
    }

    // MARK: Targets (updated at analysis rate)

    private func updateBallTarget(snap: Bool) {
        let box = showTrail ? ballBox : nil
        guard let box, [box.midX, box.midY, box.width, box.height].allSatisfy(\.isFinite) else {
            ringTarget = nil
            if ringVisible { ringVisible = false; fade(ballGroup, to: 0, duration: 0.3) }
            return
        }
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = max(box.width * imageRect.width, box.height * imageRect.height) / 2
        ringRadiusTarget = max(9, radius * 1.3 + 4)
        let jump = hypot(center.x - ringShown.x, center.y - ringShown.y) > 0.25
        if !ringVisible || snap || jump {
            ringShown = center; ringRadius = ringRadiusTarget
        }
        ringTarget = center
        if !ringVisible { ringVisible = true; fade(ballGroup, to: 1, duration: 0.12) }
        ring.strokeColor = (ballConfirmed ? OverlayStyle.accent : UIColor.white.withAlphaComponent(0.6)).cgColor
    }

    private func updateBodies(snap: Bool) {
        let people = (showSkeletons || showOrientations) ? (hybrid?.people ?? []) : []
        var previous = bodies
        var next: [Body] = []
        for person in people where person.joints.count == 17 {
            let foot = person.foot
            var target = person.joints.map { CGPoint(x: $0.point.x, y: $0.point.y) }
            target.append(CGPoint(x: foot.x, y: foot.y))
            var confidence = person.joints.map(\.confidence)
            confidence.append(foot.finite ? 1 : 0)
            let rays = person.rays.map { (angle: CGFloat(atan2($0.direction.y, $0.direction.x)), selected: $0.selected) }
            let limit = max(0.04, person.height * 0.5)
            let match = snap ? nil : previous.indices.min { a, b in
                distance(previous[a].target[17], target[17]) < distance(previous[b].target[17], target[17])
            }.flatMap { distance(previous[$0].target[17], target[17]) <= limit ? $0 : nil }
            var body = Body(shown: target, target: target, confidence: confidence, rays: rays, height: person.height)
            if let match {
                let old = previous.remove(at: match)
                for i in 0..<18 where old.confidence[i] >= OverlayStyle.jointConfidence && old.shown[i].x.isFinite && old.shown[i].y.isFinite {
                    body.shown[i] = old.shown[i]
                }
            }
            next.append(body)
        }
        if !previous.isEmpty && showSkeletons {
            // Unmatched players crossfade out instead of vanishing.
            skeletonGhost.path = skeletonPath(previous.map(\.shown), previous.map(\.confidence)).lines
            skeletonGhost.removeAnimation(forKey: "fade")
            skeletonGhost.opacity = 1
            fade(skeletonGhost, to: 0, duration: 0.25)
        }
        bodies = next
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = hypot(a.x - b.x, a.y - b.y)
        return d.isFinite ? d : .infinity
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "fade")
    }

    // MARK: Display-rate interpolation

    private var needsAnimation: Bool {
        if let ringTarget, hypot((ringTarget.x - ringShown.x) * imageRect.width, (ringTarget.y - ringShown.y) * imageRect.height) > 0.3
            || abs(ringRadiusTarget - ringRadius) > 0.3 { return true }
        for body in bodies {
            for i in 0..<18 where body.confidence[i] >= OverlayStyle.jointConfidence {
                if hypot((body.target[i].x - body.shown[i].x) * imageRect.width,
                         (body.target[i].y - body.shown[i].y) * imageRect.height) > 0.3 { return true }
            }
        }
        return false
    }

    private func startDisplayLink() {
        guard window != nil else { return }
        if displayLink == nil {
            let proxy = DisplayLinkProxy(); proxy.owner = self
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastStep = CACurrentMediaTime()
        }
        if displayLink?.isPaused == true { displayLink?.isPaused = false; lastStep = CACurrentMediaTime() }
    }

    fileprivate func step(_ link: CADisplayLink) {
        let dt = max(0, min(0.1, link.timestamp - lastStep))
        lastStep = link.timestamp
        let ballGain = CGFloat(1 - exp(-dt / 0.045)), bodyGain = CGFloat(1 - exp(-dt / 0.06))
        if let ringTarget {
            ringShown.x += (ringTarget.x - ringShown.x) * ballGain
            ringShown.y += (ringTarget.y - ringShown.y) * ballGain
            ringRadius += (ringRadiusTarget - ringRadius) * ballGain
        }
        for b in bodies.indices {
            for i in 0..<18 where bodies[b].confidence[i] >= OverlayStyle.jointConfidence {
                bodies[b].shown[i].x += (bodies[b].target[i].x - bodies[b].shown[i].x) * bodyGain
                bodies[b].shown[i].y += (bodies[b].target[i].y - bodies[b].shown[i].y) * bodyGain
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderAnimated()
        CATransaction.commit()
        if !needsAnimation { link.isPaused = true }
    }

    private func renderAnimated() {
        let center = display(ringShown)
        if center.x.isFinite && center.y.isFinite { ballGroup.position = center }
        if abs(ringPathRadius - ringRadius) > 0.25 {
            ringPathRadius = ringRadius
            let path = ringPath(radius: ringRadius)
            ring.path = path; ringHalo.path = path
        }
        renderTrail()
        let paths = skeletonPath(bodies.map(\.shown), bodies.map(\.confidence))
        skeleton.path = showSkeletons ? paths.lines : nil
        skeletonHalo.path = skeleton.path
        joints.path = showSkeletons ? paths.dots : nil
        let chosen = CGMutablePath(), ambiguous = CGMutablePath(), feet = CGMutablePath()
        for body in bodies where body.confidence[17] > 0 {
            let foot = display(body.shown[17])
            guard foot.x.isFinite, foot.y.isFinite else { continue }
            // Ground ellipse under each player; the heading arrow starts at its rim.
            let rx = min(34, max(10, CGFloat(body.height) * imageRect.height * 0.2)), ry = rx * 0.36
            if showSkeletons { feet.addEllipse(in: CGRect(x: foot.x - rx, y: foot.y - ry, width: rx * 2, height: ry * 2)) }
            guard showOrientations else { continue }
            for ray in body.rays {
                let c = cos(ray.angle), s = sin(ray.angle)
                let rim = rx * ry / max(0.001, hypot(ry * c, rx * s))
                addWedge(ray.selected ? chosen : ambiguous, at: foot, angle: ray.angle, start: rim + 2, length: max(12, rx * 0.8))
            }
        }
        footRings.path = feet
        orientations.path = chosen; ambiguousOrientations.path = ambiguous
    }

    /// Thin ring with four short outward ticks, centred on the layer origin.
    private func ringPath(radius: CGFloat) -> CGPath {
        // Track-shaped capsule around the ball, as in the art direction.
        let rect = CGRect(x: -radius * 1.25, y: -radius, width: radius * 2.5, height: radius * 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func addWedge(_ path: CGMutablePath, at foot: CGPoint, angle: CGFloat, start: CGFloat, length: CGFloat) {
        let ux = cos(angle), uy = sin(angle), half = length * 0.42
        let base = CGPoint(x: foot.x + ux * start, y: foot.y + uy * start)
        let tip = CGPoint(x: foot.x + ux * (start + length), y: foot.y + uy * (start + length))
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        path.addLine(to: CGPoint(x: foot.x + ux * (start + length * 0.28), y: foot.y + uy * (start + length * 0.28)))
        path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        path.closeSubpath()
    }

    private static let edges = [(5,6),(5,7),(7,9),(6,8),(8,10),(5,11),(6,12),(11,12),(11,13),(13,15),(12,14),(14,16)]

    private func skeletonPath(_ points: [[CGPoint]], _ confidences: [[Double]]) -> (lines: CGPath, dots: CGPath) {
        let lines = CGMutablePath(), dots = CGMutablePath()
        let minimum = OverlayStyle.jointConfidence
        for (body, confidence) in zip(points, confidences) {
            for (a, b) in Self.edges where min(confidence[a], confidence[b]) >= minimum {
                let pa = display(body[a]), pb = display(body[b])
                guard pa.x.isFinite, pa.y.isFinite, pb.x.isFinite, pb.y.isFinite else { continue }
                lines.move(to: pa); lines.addLine(to: pb)
            }
            for i in 0..<17 where confidence[i] >= minimum {
                let p = display(body[i])
                guard p.x.isFinite, p.y.isFinite else { continue }
                dots.addEllipse(in: CGRect(x: p.x - 1.75, y: p.y - 1.75, width: 3.5, height: 3.5))
            }
        }
        return (lines, dots)
    }

    /// Catmull-Rom ribbon whose width and opacity grow from the oldest point to the ball.
    private func renderTrail() {
        var runs: [[CGPoint]] = [[]]
        if showTrail {
            for point in trail {
                if point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) {
                    runs[runs.count - 1].append(CGPoint(x: point.x, y: point.y))
                } else if !runs[runs.count - 1].isEmpty { runs.append([]) }
            }
        }
        // Attach the head to the gliding ring so the tail never detaches from it.
        if ringVisible, let ringTarget, var last = runs.last, let head = last.last,
           hypot(head.x - ringTarget.x, head.y - ringTarget.y) < 0.02 {
            last[last.count - 1] = ringShown; runs[runs.count - 1] = last
        }
        let total = max(1, runs.reduce(0) { $0 + $1.count } - 1)
        let headWidth = min(11, max(4, ringRadius * 0.8))
        let glow = CGMutablePath()
        let paths = trailBuckets.map { _ in CGMutablePath() }
        var offset = 0
        for run in runs {
            defer { offset += run.count }
            guard run.count >= 2 else { continue }
            let p = run.map { display($0) }
            var samples: [(CGPoint, CGFloat)] = []
            samples.reserveCapacity((p.count - 1) * 4 + 1)
            for i in 0..<(p.count - 1) {
                let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
                for s in 0..<4 {
                    let t = CGFloat(s) / 4, t2 = t * t, t3 = t2 * t
                    func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                        0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                    }
                    samples.append((CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)),
                                    (CGFloat(offset + i) + t) / CGFloat(total)))
                }
            }
            samples.append((p[p.count - 1], CGFloat(offset + p.count - 1) / CGFloat(total)))
            if ringVisible {
                // The tail stops at the ring so the ball itself stays uncovered.
                let c = display(ringShown)
                while let last = samples.last, hypot(last.0.x - c.x, last.0.y - c.y) < ringRadius { samples.removeLast() }
            }
            guard samples.count >= 2 else { continue }
            // Soft halo along the newest part of the tail.
            let recent = samples.filter { $0.1 > 0.35 }.map(\.0)
            if recent.count >= 2 { glow.addLines(between: recent) }
            func edge(_ j: Int) -> (CGPoint, CGPoint) {
                let a = samples[max(0, j - 1)].0, b = samples[min(samples.count - 1, j + 1)].0
                let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
                let width: CGFloat = 2.25  // constant-width line, no comet taper
                let nx = -(b.y - a.y) / length * width, ny = (b.x - a.x) / length * width
                let c = samples[j].0
                return (CGPoint(x: c.x + nx, y: c.y + ny), CGPoint(x: c.x - nx, y: c.y - ny))
            }
            var current = edge(0)
            for j in 0..<(samples.count - 1) {
                let following = edge(j + 1)
                let age = (samples[j].1 + samples[j + 1].1) / 2
                let bucket = min(trailBuckets.count - 1, max(0, Int(age * CGFloat(trailBuckets.count))))
                paths[bucket].addLines(between: [current.0, following.0, following.1, current.1])
                paths[bucket].closeSubpath()
                current = following
            }
        }
        for (bucket, path) in zip(trailBuckets, paths) { bucket.path = path }
        trailGlow.path = nil
    }

    // MARK: Static markers

    private func drawDecision() {
        let targetPath = CGMutablePath(), playersPath = CGMutablePath()
        if showDecision, let hybrid {
            if let target = hybrid.target, target.finite {
                let p = display(target)
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    targetPath.move(to: CGPoint(x: p.x + dx * 3, y: p.y + dy * 3))
                    targetPath.addLine(to: CGPoint(x: p.x + dx * 8, y: p.y + dy * 8))
                }
            }
            if let players = hybrid.playerTarget, players.finite {
                let p = display(players), r: CGFloat = 5
                playersPath.addLines(between: [CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x + r, y: p.y),
                                               CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x - r, y: p.y)])
                playersPath.closeSubpath()
            }
        }
        hybridTargets.path = targetPath; playerTarget.path = playersPath
        let halo = CGMutablePath(); halo.addPath(targetPath); halo.addPath(playersPath)
        decisionHalo.path = halo
    }

    private func drawScores(image: CGRect) {
        let proposals = showDetections ? Array(scoredProposals.sorted { $0.confidence > $1.confidence }.prefix(16)) : []
        while scoreLabels.count < proposals.count {
            let label = UILabel(); label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = OverlayStyle.accent; label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
            label.layer.cornerRadius = 2; label.clipsToBounds = true; addSubview(label); scoreLabels.append(label)
        }
        for (index, label) in scoreLabels.enumerated() {
            guard index < proposals.count else { label.isHidden = true; continue }
            let proposal = proposals[index]
            if let ballBox, abs(ballBox.midX - proposal.x) < 0.001 && abs(ballBox.midY - proposal.y) < 0.001 {
                label.isHidden = true; continue
            }
            label.text = String(format: " %.0f %% ", proposal.confidence * 100)
            let p = display(HybridVector(proposal.x - proposal.width / 2, proposal.y - proposal.height / 2))
            let size = label.sizeThatFits(CGSize(width: 90, height: 20))
            label.frame = CGRect(x: min(max(image.minX, p.x), image.maxX - size.width),
                y: min(max(image.minY, p.y - size.height), image.maxY - size.height), width: size.width, height: size.height)
            label.isHidden = false
        }
    }

    private func reportInterfaceOrientation() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              orientation != .unknown, lastInterfaceOrientation != orientation else { return }
        lastInterfaceOrientation = orientation
        Task { @MainActor [weak self] in
            // Interface orientation is independent of camera reconnections.
            // A removed preview has no window and cannot publish old state.
            guard let self, self.window?.windowScene?.interfaceOrientation == orientation else { return }
            self.onInterfaceOrientation?(orientation)
        }
    }

    private func refreshRotationCoordinator() {
        // The coordinator needs a live layer to resolve rotation relative to the
        // interface. Sensor mounting differs between the front/back cameras and
        // between iPhone generations, so interface orientation alone is insufficient.
        guard window != nil, let connection = previewLayer.connection,
              let input = connection.inputPorts.first(where: { $0.mediaType == .video })?.input as? AVCaptureDeviceInput else {
            return
        }
        let device = input.device
        guard rotationDeviceID != device.uniqueID || rotationConnection !== connection else { return }
        rotationObservation?.invalidate()
        rotationRevision += 1
        rotationDeviceID = device.uniqueID
        rotationConnection = connection
        lastAngle = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                   options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshRotationCoordinator()
                self.applyPreviewRotation()
                self.setNeedsLayout()
            }
        }
    }

    private func applyPreviewRotation() {
        guard window != nil, let coordinator = rotationCoordinator,
              let connection = previewLayer.connection, rotationConnection === connection,
              let angle = FrameGeometry.snappedRotationAngle(
                Double(coordinator.videoRotationAngleForHorizonLevelPreview), previous: lastAngle),
              connection.isVideoRotationAngleSupported(CGFloat(angle)) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        connection.videoRotationAngle = CGFloat(angle)
        if lastAngle != angle {
            lastAngle = angle
            let revision = rotationRevision
            // Deliver after layout, outside SwiftUI's view update transaction.
            // A callback from an earlier device/angle must not rotate new results.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil,
                      self.rotationRevision == revision, self.lastAngle == angle else { return }
                self.onRotation?(angle)
            }
        }
    }

    private func positionConfidenceLabel(image: CGRect, displayRect: CGRect?) {
        guard let displayRect, let confidence = ballConfidence, confidence.isFinite,
              confidence >= 0, confidence <= 1,
              displayRect.width > 0, displayRect.height > 0,
              displayRect.minX.isFinite, displayRect.minY.isFinite,
              displayRect.width.isFinite, displayRect.height.isFinite else {
            confidenceLabel.isHidden = true
            return
        }
        let visibleImage = image.intersection(bounds)
        guard !visibleImage.isNull, visibleImage.width > 4, visibleImage.height > 4,
              displayRect.intersects(visibleImage) else {
            confidenceLabel.isHidden = true
            return
        }
        let available = visibleImage.insetBy(dx: 2, dy: 2)
        confidenceLabel.text = String(format: "%.1f %% · brut", confidence * 100)
        confidenceLabel.accessibilityLabel = "Confiance du ballon : \(confidenceLabel.text ?? "")"
        let textSize = confidenceLabel.sizeThatFits(available.size)
        let width = min(textSize.width + 12, available.width)
        let height = min(textSize.height + 6, available.height)
        let gap: CGFloat = 3
        let above = displayRect.minY - height - gap
        let preferredY = above >= available.minY ? above : displayRect.maxY + gap
        confidenceLabel.frame = CGRect(
            x: min(max(displayRect.minX, available.minX), available.maxX - width),
            y: min(max(preferredY, available.minY), available.maxY - height),
            width: width, height: height
        )
        confidenceLabel.isHidden = false
    }
}
