import AVFoundation
import Combine
import CoreMotion
import Foundation

enum CameraFacing: String, CaseIterable, Identifiable, Sendable {
    case back, front
    var id: String { rawValue }
    var title: String { self == .back ? "Arrière" : "Frontale" }
    var devicePosition: AVCaptureDevice.Position { self == .back ? .back : .front }
    var activeMessage: String { self == .back ? "Caméra arrière active" : "Caméra frontale active" }
}

/// Crosses the detector queue / MainActor boundary without accumulating UI work.
/// Every mutable field is protected by the lock; the transferred frame is Sendable.
private final class DetectionResultMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: BallDetectionFrame?
    private var deliveryPending = false

    func offer(_ frame: BallDetectionFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latest = frame
        guard !deliveryPending else { return false }
        deliveryPending = true
        return true
    }

    func takeLatest() -> BallDetectionFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = latest
        latest = nil
        deliveryPending = false
        return frame
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        latest = nil
        // A scheduled delivery still exists. Let it consume the next frame,
        // rather than permitting a second pending MainActor task after a reset.
    }
}

@MainActor
final class CameraController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Autorisation caméra en attente"
    var onUnavailable: (() -> Void)?
    var onDetection: ((BallDetectionFrame) -> Void)?
    var onGeometryChange: (() -> Void)?
    @Published private(set) var rotationAngle = 90
    @Published private(set) var imageSize = CGSize(width: 720, height: 1280)
    @Published private(set) var detectorProfile = BallDetectorProfile.smallV006
    @Published private(set) var facing = CameraFacing.back
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maximumZoom: CGFloat = 6
    @Published private(set) var isZooming = false
    /// True while the back ultra wide (×0.5) lens is the active camera.
    @Published private(set) var isUltraWide = false
    /// Horizontal field of view of the active format, on the sensor's long side (degrees, 0 until known).
    @Published private(set) var fieldOfView: Double = 0
    private let detector = BallDetector()
    private let resultMailbox = DetectionResultMailbox()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var movieDelegate: MovieRecordingDelegate?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pitchlens.camera")
    private var requestID = UUID()
    private var detectionGeneration = UUID()
    private var wantsRunning = false
    private var requestedFacing = CameraFacing.back
    /// Back camera only: use the ultra wide lens when the iPhone has one (small pitches).
    private var requestedUltraWide = false
    private var switchID: UUID?
    private var configurationSequence: UInt64 = 0
    private var appliedConfigurationSequence: UInt64 = 0
    private var minimumDetectionTimestamp = Double.infinity
    private var lastDeliveredDetectionTimestamp = -Double.infinity
    private var notifications: [NSObjectProtocol] = []
    /// Upper bound for auto exposure while the short exposure setting is on, against motion blur.
    nonisolated static let shortExposureLimit = CMTime(value: 1, timescale: 250)
    private var shortExposure = false

    private struct SessionConfiguration: Sendable {
        let facing: CameraFacing?
        let running: Bool
        let error: String?
    }

    /// Capture-clock seconds (sample and movie timestamps) to host-clock seconds (systemUptime).
    nonisolated func hostSeconds(captureSeconds: Double) -> Double {
        BallDetector.hostSeconds(CMTime(seconds: captureSeconds, preferredTimescale: 1_000_000_000), session: session)
    }

    init() {
        detector.captureSession = session
        let resultMailbox = self.resultMailbox
        detector.onResult = { [weak self, resultMailbox] frame in
            guard resultMailbox.offer(frame) else { return }
            Task { @MainActor [weak self, resultMailbox] in
                guard let frame = resultMailbox.takeLatest(),
                      let self, self.wantsRunning, self.isRunning, !self.isSwitchingCamera,
                      self.detectionGeneration == frame.generation,
                      frame.capturedAt.isFinite, frame.capturedAt >= self.minimumDetectionTimestamp,
                      frame.capturedAt > self.lastDeliveredDetectionTimestamp else { return }
                self.lastDeliveredDetectionTimestamp = frame.capturedAt
                if self.imageSize != frame.imageSize { self.imageSize = frame.imageSize }
                self.onDetection?(frame)
            }
        }
        for name in [Notification.Name.AVCaptureSessionWasInterrupted,
                     .AVCaptureSessionRuntimeError, .AVCaptureSessionDidStopRunning,
                     .AVCaptureSessionDidStartRunning, .AVCaptureSessionInterruptionEnded] {
            notifications.append(NotificationCenter.default.addObserver(
                forName: name, object: session, queue: .main
            ) { [weak self] notification in
                let reason = String(describing: notification.userInfo ?? [:])
                Task { @MainActor [weak self] in
                    guard let self, !self.isSwitchingCamera else { return }
                    if name == .AVCaptureSessionDidStartRunning || name == .AVCaptureSessionInterruptionEnded {
                        guard self.wantsRunning else { return }
                        self.isRunning = self.session.isRunning
                        if self.isRunning { self.message = self.facing.activeMessage }
                        self.resetDetector(enabled: self.isRunning)
                        return
                    }
                    // Ignore a delayed stop notification from a previous session.
                    if name == .AVCaptureSessionDidStopRunning, self.session.isRunning { return }
                    self.isZooming = false
                    self.isRunning = false
                    self.resetDetector(enabled: false)
                    self.message = "Caméra interrompue : \(reason)"
                    if self.wantsRunning { self.onUnavailable?() }
                }
            })
        }
    }

    func start() async {
        isZooming = false
        let token = UUID()
        requestID = token
        switchID = nil
        isSwitchingCamera = false
        wantsRunning = true
        isRunning = false
        resetDetector(enabled: false)
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard token == requestID else { return }
        guard allowed else {
            message = "Accès caméra refusé. Autorise-le dans Réglages > PitchLens DockKit."
            onUnavailable?()
            return
        }
        let captureSession = session
        let movieOutput = movieOutput
        let detector = detector
        let target = requestedFacing
        let ultraWide = requestedUltraWide
        configurationSequence += 1
        let sequence = configurationSequence
        let result: SessionConfiguration = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.configure(captureSession, detector: detector,
                                                              movieOutput: movieOutput, facing: target, ultraWide: ultraWide, startIfNeeded: true))
            }
        }
        applyFacing(result, sequence: sequence)
        guard token == requestID else { return }
        if result.error != nil { requestedFacing = result.facing ?? facing }
        isRunning = result.running
        message = result.error.map { "Échec caméra : \($0)" }
            ?? (result.running ? facing.activeMessage : "La caméra n'a pas démarré")
        resetDetector(enabled: result.running)
        if !result.running { onUnavailable?() }
    }

    func stop() {
        requestID = UUID()
        isZooming = false
        switchID = nil
        isSwitchingCamera = false
        wantsRunning = false
        isRunning = false
        resetDetector(enabled: false)
        message = "Caméra suspendue"
        let captureSession = session
        let movieOutput = movieOutput
        queue.async {
            if movieOutput.isRecording { movieOutput.stopRecording() }
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    /// Chooses the back lens for the next configuration; reconfigures now if the camera runs.
    func setUltraWide(_ enabled: Bool) async {
        guard enabled != requestedUltraWide else { return }
        requestedUltraWide = enabled
        guard wantsRunning else { return }
        await setFacing(requestedFacing, force: true)
    }

    func setFacing(_ newFacing: CameraFacing, force: Bool = false) async {
        guard !isSwitchingCamera,
              force || newFacing != requestedFacing || newFacing != facing else { return }
        let token = UUID()
        requestID = token
        switchID = token
        requestedFacing = newFacing
        isSwitchingCamera = true
        isRunning = false
        resetDetector(enabled: false)
        onGeometryChange?()
        message = "Changement de caméra…"
        defer {
            if switchID == token {
                switchID = nil
                isSwitchingCamera = false
            }
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard token == requestID, switchID == token else { return }
        guard allowed else {
            requestedFacing = facing
            message = "Accès caméra refusé. Autorise-le dans Réglages > PitchLens DockKit."
            if wantsRunning { onUnavailable?() }
            return
        }
        let captureSession = session
        let movieOutput = movieOutput
        let detector = detector
        let shouldResume = wantsRunning
        let ultraWide = requestedUltraWide
        configurationSequence += 1
        let sequence = configurationSequence
        let result: SessionConfiguration = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.configure(captureSession, detector: detector,
                                                              movieOutput: movieOutput, facing: newFacing, ultraWide: ultraWide, startIfNeeded: shouldResume))
            }
        }
        // A stop can supersede this operation while its input change finishes.
        // Publish the actual input, but never revive that stopped capture session.
        applyFacing(result, sequence: sequence)
        if result.error != nil, sequence == configurationSequence, requestedFacing == newFacing {
            requestedFacing = result.facing ?? facing
        }
        guard token == requestID, switchID == token else { return }
        switchID = nil
        isSwitchingCamera = false
        isRunning = shouldResume && result.running
        if let error = result.error {
            message = "Changement impossible : \(error)"
                + (isRunning ? " · \(facing.activeMessage)" : "")
        } else {
            message = isRunning ? facing.activeMessage : "Caméra \(facing.title.lowercased()) sélectionnée"
        }
        resetDetector(enabled: isRunning)
        if shouldResume, !isRunning { onUnavailable?() }
    }

    private func applyFacing(_ result: SessionConfiguration, sequence: UInt64) {
        guard sequence >= appliedConfigurationSequence else { return }
        appliedConfigurationSequence = sequence
        if let actualFacing = result.facing { facing = actualFacing }
        let session = session
        queue.async {
            guard let device = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device else { return }
            let zoom = device.videoZoomFactor, maximum = min(6,device.maxAvailableVideoZoomFactor)
            let ultraWide = device.deviceType == .builtInUltraWideCamera
            let fieldOfView = Double(device.activeFormat.videoFieldOfView)
            Task { @MainActor in
                self.zoomFactor = zoom; self.maximumZoom = maximum; self.isUltraWide = ultraWide; self.fieldOfView = fieldOfView
            }
        }
        // configure() sets the session preset, which resets the cap to the format default.
        if shortExposure { applyExposureLimit(true) }
    }

    func setShortExposure(_ enabled: Bool) {
        guard shortExposure != enabled else { return }
        shortExposure = enabled
        applyExposureLimit(enabled)
    }

    /// Auto exposure and ISO stay automatic; only the longest exposure is capped.
    /// Off restores the device default (.invalid) for the current format.
    private func applyExposureLimit(_ enabled: Bool) {
        let session = session
        queue.async {
            guard let device = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device,
                  device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose else { return }
            do {
                try device.lockForConfiguration()
                let format = device.activeFormat
                device.activeMaxExposureDuration = enabled ? CMTimeClampToRange(Self.shortExposureLimit,
                    range: CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration)) : .invalid
                device.unlockForConfiguration()
            } catch { Task { @MainActor in self.message = "Exposition courte indisponible : \(error.localizedDescription)" } }
        }
    }

    func beginZoom() {
        guard isRunning, !isSwitchingCamera else { return }
        isZooming = true
        // Only motor following pauses. Keep detections visible while pinching,
        // even if UIKit cancels the gesture during a view/session transition.
    }
    func setZoom(_ factor: CGFloat) {
        guard factor.isFinite, isZooming else { return }
        let session = session
        queue.async {
            guard let device = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device else { return }
            do {
                try device.lockForConfiguration()
                let actual = max(device.minAvailableVideoZoomFactor, min(factor,min(6,device.maxAvailableVideoZoomFactor)))
                device.videoZoomFactor = actual
                device.unlockForConfiguration()
                Task { @MainActor in self.zoomFactor = actual }
            } catch { Task { @MainActor in self.message = "Zoom indisponible : \(error.localizedDescription)" } }
        }
    }
    /// Automatic zoom: a device ramp (never a jump) that keeps analysis and motor following running.
    /// Steps under 1 % are skipped unless forced, so the camera queue is not locked every frame.
    /// A pinch sets videoZoomFactor directly, which cancels any ramp in progress.
    func rampAutoZoom(to factor: CGFloat, force: Bool = false) {
        guard factor.isFinite, factor > 0, isRunning, !isSwitchingCamera, !isZooming,
              force || abs(log(factor / max(0.01, zoomFactor))) >= 0.01 else { return }
        let session = session
        queue.async {
            guard let device = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device else { return }
            do {
                try device.lockForConfiguration()
                let actual = max(device.minAvailableVideoZoomFactor, min(factor, min(6, device.maxAvailableVideoZoomFactor)))
                device.ramp(toVideoZoomFactor: actual, withRate: 1)  // rate: doublings per second
                device.unlockForConfiguration()
                Task { @MainActor in if !self.isZooming { self.zoomFactor = actual } }
            } catch { Task { @MainActor in self.message = "Zoom automatique indisponible : \(error.localizedDescription)" } }
        }
    }
    func endZoom(completion: @escaping @MainActor (CGFloat) -> Void) {
        let token = requestID
        let session = session
        queue.async {
            let actual = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device.videoZoomFactor ?? 1
            Task { @MainActor in
                guard token == self.requestID else { return }
                self.zoomFactor = actual
                self.isZooming = false
                completion(actual)
                self.resetDetector(enabled: self.wantsRunning)
            }
        }
    }

    func setPreviewRotation(_ angle: Int) {
        guard rotationAngle != angle else { return }
        let wasPortrait = rotationAngle == 90 || rotationAngle == 270
        let isPortrait = angle == 90 || angle == 270
        rotationAngle = angle
        if wasPortrait != isPortrait { imageSize = CGSize(width: imageSize.height, height: imageSize.width) }
        resetDetector(enabled: wantsRunning)
        onGeometryChange?()
    }

    func setDetectorProfile(_ profile: BallDetectorProfile) {
        guard detectorProfile != profile else { return }
        detectorProfile = profile
        resetDetector(enabled: wantsRunning)
        onGeometryChange?()
    }

    func setHybridEnabled(_ enabled: Bool) { detector.setHybridEnabled(enabled) }
    func setLocalSearchWindow(enabled: Bool, followThreshold: Double) {
        detector.setLocalSearchWindow(enabled: enabled, followThreshold: followThreshold)
    }
    func setStaticCandidateFilter(enabled: Bool) { detector.setStaticCandidateFilter(enabled: enabled) }

    private func resetDetector(enabled: Bool) {
        let shouldEnable = enabled && wantsRunning && isRunning && !isSwitchingCamera
        #if DEBUG
        print("[PitchLens] Analyse \(shouldEnable ? "active" : "arrêtée") · rotation \(rotationAngle)° · zoom en cours \(isZooming)")
        #endif
        detectionGeneration = UUID()
        minimumDetectionTimestamp = shouldEnable ? ProcessInfo.processInfo.systemUptime : .infinity
        lastDeliveredDetectionTimestamp = -Double.infinity
        resultMailbox.clear()
        detector.configure(enabled: shouldEnable, generation: detectionGeneration,
                           profile: detectorProfile, rotationAngle: rotationAngle)
    }

    func captureDiagnosticFrame() async throws -> BallDiagnosticSnapshot {
        guard isRunning, !isSwitchingCamera else {
            throw NSError(domain: "PitchLens.Snapshot", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "La caméra doit être active"])
        }
        let token = detectionGeneration
        let snapshot: BallDiagnosticSnapshot = try await withCheckedThrowingContinuation { continuation in
            detector.captureDiagnosticFrame { continuation.resume(with: $0) }
        }
        guard isRunning, !isSwitchingCamera, token == detectionGeneration else {
            throw NSError(domain: "PitchLens.Snapshot", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Caméra modifiée pendant la capture ; réessaie"])
        }
        return snapshot
    }

    func startMovie(to url: URL, delegate: MovieRecordingDelegate) async throws -> Bool {
        let audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard isRunning, wantsRunning, !isSwitchingCamera else {
            throw NSError(domain: "PitchLens.Recording", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "La caméra doit être active pour filmer."])
        }
        movieDelegate = delegate
        let captureSession = session, output = movieOutput, angle = rotationAngle
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !output.isRecording, captureSession.outputs.contains(where: { $0 === output }),
                          let connection = output.connection(with: .video), connection.isActive else {
                        throw NSError(domain: "PitchLens.Recording", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Enregistrement vidéo indisponible ; réessaie."])
                    }
                    captureSession.beginConfiguration()
                    if audioAllowed, !captureSession.inputs.contains(where: {
                        ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true
                    }), let microphone = AVCaptureDevice.default(for: .audio),
                       let input = try? AVCaptureDeviceInput(device: microphone), captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                    }
                    captureSession.commitConfiguration()
                    connection.automaticallyAdjustsVideoMirroring = false
                    if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                    if connection.isVideoRotationAngleSupported(CGFloat(angle)) { connection.videoRotationAngle = CGFloat(angle) }
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                    if output.availableVideoCodecTypes.contains(.hevc) {
                        output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                    }
                    output.maxRecordedDuration = .invalid
                    output.maxRecordedFileSize = 0
                    output.minFreeDiskSpaceLimit = 512 * 1024 * 1024
                    output.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
                    let hasAudio = output.connection(with: .audio)?.isActive == true
                    output.startRecording(to: url, recordingDelegate: delegate)
                    continuation.resume(returning: hasAudio)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stopMovie() {
        let output = movieOutput
        queue.async { if output.isRecording { output.stopRecording() } }
    }

    nonisolated private static func configure(_ session: AVCaptureSession, detector: BallDetector,
                                             movieOutput: AVCaptureMovieFileOutput,
                                             facing: CameraFacing, ultraWide: Bool, startIfNeeded: Bool) -> SessionConfiguration {
        var errorMessage: String?
        do {
            try configureInput(session, detector: detector, movieOutput: movieOutput, facing: facing, ultraWide: ultraWide)
        } catch { errorMessage = error.localizedDescription }
        // Input replacement creates a new connection: reapply orientation/mirroring
        // and query formats only after the output is attached to the active camera.
        for output in session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }) {
            if let connection = output.connection(with: .video) {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            }
            let formats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelFormatType_32BGRA]
            if let format = formats.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) {
                // Vision accepts native YCbCr buffers. Avoid AVCapture converting
                // every frame to BGRA before Vision scales it for the model.
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            }
        }
        if errorMessage == nil, startIfNeeded, !session.isRunning { session.startRunning() }
        let actualFacing = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .first(where: { $0.device.hasMediaType(.video) }).flatMap { input -> CameraFacing? in
                switch input.device.position {
                case .back: return .back
                case .front: return .front
                default: return nil
                }
            }
        return SessionConfiguration(facing: actualFacing,
                                    running: session.isRunning && actualFacing != nil,
                                    error: errorMessage)
    }

    nonisolated private static func configureInput(_ session: AVCaptureSession, detector: BallDetector,
                                                  movieOutput: AVCaptureMovieFileOutput, facing: CameraFacing, ultraWide: Bool) throws {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera, .builtInUltraWideCamera],
            mediaType: .video, position: facing.devicePosition).devices
        // Falls back to the wide lens on iPhones without an ultra wide camera.
        let ultraWideDevice = ultraWide && facing == .back
            ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : nil
        guard let device = ultraWideDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: facing.devicePosition) ?? devices.first else {
            throw NSError(domain: "PitchLens.Camera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Caméra \(facing.title.lowercased()) indisponible"])
        }
        let previousInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        // Same side but another lens (wide ↔ ultra wide) also needs a new input.
        let replacing = previousInputs.count != 1 || previousInputs.first?.device.uniqueID != device.uniqueID
        let newInput = replacing ? try AVCaptureDeviceInput(device: device) : nil
        let previousPreset = session.sessionPreset
        var addedOutput: AVCaptureVideoDataOutput?
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            if let newInput {
                for input in previousInputs { session.removeInput(input) }
                // The old fixed resolution can be unsupported by the new camera.
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                guard session.canAddInput(newInput) else {
                    throw NSError(domain: "PitchLens.Camera", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Entrée caméra indisponible"])
                }
                session.addInput(newInput)
            }
            let presets: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .high]
            guard let preset = presets.first(where: { session.canSetSessionPreset($0) }) else {
                throw NSError(domain: "PitchLens.Camera", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Résolution caméra indisponible"])
            }
            session.sessionPreset = preset
            if !session.outputs.contains(where: { $0 is AVCaptureVideoDataOutput }) {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(detector, queue: detector.queue)
                guard session.canAddOutput(output) else {
                    throw NSError(domain: "PitchLens.Camera", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Analyse caméra indisponible"])
                }
                session.addOutput(output)
                addedOutput = output
            }
            if !session.outputs.contains(where: { $0 === movieOutput }), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
        } catch {
            if let addedOutput { session.removeOutput(addedOutput) }
            if let newInput {
                if session.inputs.contains(where: { $0 === newInput }) { session.removeInput(newInput) }
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                for input in previousInputs {
                    guard session.canAddInput(input) else {
                        throw NSError(domain: "PitchLens.Camera", code: 5,
                                      userInfo: [NSLocalizedDescriptionKey: "Ancienne caméra impossible à restaurer"])
                    }
                    session.addInput(input)
                }
            }
            if session.canSetSessionPreset(previousPreset) { session.sessionPreset = previousPreset }
            throw error
        }
    }

    deinit {
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
    }
}

/// Direction of the back camera's optical axis in a gravity-aligned frame (z up), from the
/// iPhone's motion sensors. Independent of the gimbal, whose angle telemetry is not validated.
final class CameraAttitude: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [(time: Double, axis: PitchVector3)] = []

    init() { queue.maxConcurrentOperationCount = 1; queue.name = "pitchlens.attitude" }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        // The corrected frame limits gyro drift over a match; both have z vertical.
        let frame: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames()
            .contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let motion, let axis = Self.cameraAxis(motion) else { return }
            self.lock.lock()
            self.samples.append((motion.timestamp, axis))
            if let last = self.samples.last { self.samples.removeAll { last.time - $0.time > 2 } }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    /// The sample closest to `time` (same clock as capture timestamps: seconds since boot),
    /// or the latest one; nil when no recent sample exists.
    func axis(at time: Double? = nil) -> PitchVector3? {
        lock.lock(); defer { lock.unlock() }
        guard let latest = samples.last else { return nil }
        guard let time, time.isFinite else { return latest.axis }
        let best = samples.min { abs($0.time - time) < abs($1.time - time) }
        return best.map { abs($0.time - time) <= 0.5 ? $0.axis : latest.axis }
    }

    /// The back camera looks along the device's −z axis. CoreMotion's matrix maps between the device
    /// and reference frames; the direction is chosen so that gravity lands on the reference −z.
    static func cameraAxis(_ motion: CMDeviceMotion) -> PitchVector3? {
        let m = motion.attitude.rotationMatrix
        func apply(_ v: PitchVector3, transpose: Bool) -> PitchVector3 {
            transpose
                ? PitchVector3(m.m11 * v.x + m.m21 * v.y + m.m31 * v.z, m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                               m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
                : PitchVector3(m.m11 * v.x + m.m12 * v.y + m.m13 * v.z, m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
                               m.m31 * v.x + m.m32 * v.y + m.m33 * v.z)
        }
        let gravity = PitchVector3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        let transpose = apply(gravity, transpose: true).z < apply(gravity, transpose: false).z
        return apply(PitchVector3(0, 0, -1), transpose: transpose).normalized
    }
}
