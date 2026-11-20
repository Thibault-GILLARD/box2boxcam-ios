import AVFoundation
import CoreImage
import CoreML
import Vision

/// Background registration uses camera pixels, not commanded motor velocity.
final class CameraMotionEstimator {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previous: CGImage?
    private(set) var center = HybridVector(0.5, 0.5)
    private(set) var referenceID = UUID()
    func reset() { previous = nil; center = HybridVector(0.5, 0.5); referenceID = UUID() }
    func update(pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Bool {
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let scale = 384 / image.extent.width
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let current = context.createCGImage(resized, from: resized.extent) else { reset(); return false }
        defer { previous = current }
        guard let old = previous, old.width == current.width, old.height == current.height else { return true }
        do {
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: old)
            try VNImageRequestHandler(cgImage: current).perform([request])
            guard let observation = request.results?.first, observation.confidence >= 0.2 else { reset(); return false }
            let transform = observation.alignmentTransform
            let shift = HybridVector(Double(transform.tx) / Double(current.width), -Double(transform.ty) / Double(current.height))
            guard shift.finite, shift.length < 0.18 else { reset(); return false }
            center = center - shift
            return true
        } catch { reset(); return false }
    }
}

/// Exactly one retained pose frame. The ball inference queue never waits for it.
final class HybridVisionProcessor {
    private let queue = DispatchQueue(label: "pitchlens.people-pose", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var generation = UUID()
    private var busy = false
    private var lastScheduled = -Double.infinity
    private var latestFrame: HybridPeopleSnapshot?
    private var peopleRequest: VNCoreMLRequest?
    private var poseRequest: VNCoreMLRequest?
    private struct Track {
        var foot: HybridVector
        var height: Double
        var samples: [(Double, HybridVector)]
        var direction: HybridVector?
        var directionTime: Double
    }
    private var tracks: [Track] = [] // Accessed only by the pose queue.

    func configure(reference: UUID) {
        lock.lock(); generation = reference; latestFrame = nil; lastScheduled = -.infinity; lock.unlock()
        queue.async { self.tracks = [] }
    }
    func latest(reference: UUID) -> HybridPeopleSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return generation == reference ? latestFrame : nil
    }
    func submit(pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                center: HybridVector, timestamp: Double, reference: UUID, horizontalFOV: Double = 60) {
        let minimumInterval = ProcessInfo.processInfo.thermalState.rawValue >= 2 ? 0.6 : 0.25
        lock.lock()
        guard generation == reference, !busy, timestamp - lastScheduled >= minimumInterval else { lock.unlock(); return }
        busy = true; lastScheduled = timestamp
        lock.unlock()
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            let result: HybridPeopleSnapshot = autoreleasepool {
                do {
                    try self.loadModels()
                    let upright = CIImage(cvPixelBuffer: pixels).oriented(orientation)
                    guard let image = self.context.createCGImage(upright, from: upright.extent) else {
                        throw NSError(domain: "PitchLens.Hybrid", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image joueurs indisponible"])
                    }
                    let people = try self.infer(image: image, center: center, timestamp: timestamp, horizontalFOV: horizontalFOV)
                    return HybridPeopleSnapshot(timestamp: timestamp, cameraCenter: center, people: people,
                        analysisMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
                } catch {
                    return HybridPeopleSnapshot(timestamp: timestamp, cameraCenter: center, people: [],
                        analysisMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, error: error.localizedDescription)
                }
            }
            self.lock.lock()
            if self.generation == reference { self.latestFrame = result }
            self.busy = false
            self.lock.unlock()
        }
    }
    private func loadModels() throws {
        func load(_ name: String) throws -> VNCoreMLRequest {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                throw NSError(domain: "PitchLens.Hybrid", code: 2, userInfo: [NSLocalizedDescriptionKey: "Modèle absent : \(name)"])
            }
            let configuration = MLModelConfiguration(); configuration.computeUnits = .all
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration)))
            request.imageCropAndScaleOption = .scaleFit
            return request
        }
        if peopleRequest == nil { peopleRequest = try load("PitchLensPeople") }
        if poseRequest == nil { poseRequest = try load("PitchLensPose") }
    }
    private func infer(image: CGImage, center: HybridVector, timestamp: Double, horizontalFOV: Double) throws -> [HybridPerson] {
        guard let peopleRequest, let poseRequest else { return [] }
        try VNImageRequestHandler(cgImage: image).perform([peopleRequest])
        let observations = (peopleRequest.results as? [VNRecognizedObjectObservation] ?? []).filter {
            guard let label = $0.labels.first(where: { $0.identifier == "person" }) else { return false }
            return Double($0.confidence * label.confidence) >= 0.25
        }.sorted { $0.boundingBox.height > $1.boundingBox.height }.prefix(32)
        let width = Double(image.width), height = Double(image.height), offset = center - HybridVector(0.5, 0.5)
        var result: [HybridPerson] = [], nextTracks: [Track] = [], usedTracks = Set<Int>()
        for (index, observation) in observations.enumerated() {
            let b = observation.boundingBox
            var person = HybridPerson(x: b.midX, y: 1 - b.midY, width: b.width, height: b.height,
                confidence: Double(observation.confidence * (observation.labels.first(where: { $0.identifier == "person" })?.confidence ?? 0)))
            // Bound live pose cost; every person still counts in the consensus denominator.
            if index < 12 {
                let rectangle = CGRect(x: b.minX * width, y: (1 - b.maxY) * height,
                    width: b.width * width, height: b.height * height).insetBy(dx: -b.height * height * 0.30, dy: -b.height * height * 0.30)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
                if let crop = image.cropping(to: rectangle), rectangle.width >= 8, rectangle.height >= 12 {
                    try VNImageRequestHandler(cgImage: crop).perform([poseRequest])
                    if let array = (poseRequest.results as? [VNCoreMLFeatureValueObservation])?.first?.featureValue.multiArrayValue {
                        person.joints = Self.decodePose(array, crop: rectangle, width: width, height: height,
                                                      target: HybridVector(b.midX, 1 - b.midY))
                    }
                }
            }
            let torso = person.joints.count == 17 ? [5,6,11,12].map { person.joints[$0] } : []
            let validTorso = torso.count == 4 && torso.allSatisfy { $0.confidence >= 0.55 && $0.point.finite }
            let anchor = validTorso ? (torso[2].point + torso[3].point)/2 : person.foot
            let bodyHeight = validTorso ? ((torso[2].point + torso[3].point - torso[0].point - torso[1].point)/2).y * height : person.height * height
            let worldFoot = anchor + offset
            let oldIndex = tracks.indices.filter { !usedTracks.contains($0) && timestamp - (tracks[$0].samples.last?.0 ?? 0) <= 0.4 }.min {
                (tracks[$0].foot - worldFoot).length < (tracks[$1].foot - worldFoot).length
            }
            var track = Track(foot: worldFoot, height: person.height, samples: [], direction: nil, directionTime: -.infinity)
            if let oldIndex, (tracks[oldIndex].foot - worldFoot).length < max(person.height, tracks[oldIndex].height) * 1.8 {
                usedTracks.insert(oldIndex); track = tracks[oldIndex]
            }
            track.foot = worldFoot; track.height = person.height
            track.samples.append((timestamp, worldFoot)); track.samples = Array(track.samples.suffix(7))
            let movement = HybridBodyGeometry.motionEvidence(track.samples, width: width, height: height, bodyHeight: max(8,bodyHeight))
            let priorStrength = exp(-(timestamp - track.directionTime) / 0.3)
            person.rays = HybridBodyGeometry.rays(joints: person.joints, width: width, height: height,
                motion: movement?.direction, motionStrength: movement?.strength ?? 0, previous: track.direction, previousStrength: priorStrength,
                motionAngularStrength: movement?.angularStrength ?? 0, horizontalFOV: horizontalFOV)
            if let chosen = person.rays.first(where: \.selected) { track.direction = chosen.direction; track.directionTime = timestamp }
            nextTracks.append(track); result.append(person)
        }
        tracks = nextTracks
        return result
    }

    static func decodePose(_ array: MLMultiArray, crop: CGRect, width: Double, height: Double,
                           target: HybridVector) -> [HybridJoint] {
        guard array.shape.map(\.intValue) == [1, 300, 57] else { return [] }
        let scale = min(384 / crop.width, 384 / crop.height)
        let padx = (384 - crop.width * scale) / 2, pady = (384 - crop.height * scale) / 2
        func value(_ row: Int, _ column: Int) -> Double { array[[0, NSNumber(value: row), NSNumber(value: column)]].doubleValue }
        var chosen: Int?, distance = Double.infinity
        for row in 0..<300 where value(row, 4) >= 0.15 {
            let x = ((value(row, 0) + value(row, 2)) / 2 - padx) / scale + crop.minX
            let y = ((value(row, 1) + value(row, 3)) / 2 - pady) / scale + crop.minY
            let d = hypot(x - target.x * width, y - target.y * height)
            if d < distance { distance = d; chosen = row }
        }
        guard let chosen, distance <= crop.height * 0.6 else { return [] }
        return (0..<17).map { joint in
            let x = ((value(chosen, 6 + joint * 3) - padx) / scale + crop.minX) / width
            let y = ((value(chosen, 7 + joint * 3) - pady) / scale + crop.minY) / height
            return HybridJoint(x, y, value(chosen, 8 + joint * 3))
        }
    }
}
