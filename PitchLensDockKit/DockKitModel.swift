import Combine
import AVFoundation
import DockKit
import Foundation
import UIKit

@MainActor
final class DockKitModel: ObservableObject {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let message: String
    }

    let camera = CameraController()
    @Published private(set) var accessoryName: String?
    @Published private(set) var hardware = "—"
    @Published private(set) var firmware = "—"
    @Published private(set) var connectionMessage = "En attente de l'Osmo"
    @Published private(set) var motorStatus: MotorController.Status = .unprepared
    @Published private(set) var telemetry = "Aucune télémétrie reçue"
    @Published private(set) var limitsDescription = "—"
    @Published private(set) var logs: [LogEntry] = []
    @Published var speed = 0.20 {
        didSet {
            let bounded = speed.isFinite ? min(0.30, max(0.05, speed)) : 0.20
            if speed != bounded { speed = bounded; return }
            UserDefaults.standard.set(speed, forKey: "pitchlens.motorSpeed")
            appendLog(String(format: "Vitesse maximale : %.2f rad/s", speed))
            logRecordingConfiguration()
        }
    }
    @Published var pulseSeconds = 0.4
    // Osmo axis calibration confirmed by the user with both cameras.
    @Published var invertYaw = true { didSet { Self.save(invertYaw, "invertYaw"); logRecordingConfiguration() } }
    @Published var invertPitch = true { didSet { Self.save(invertPitch, "invertPitch"); logRecordingConfiguration() } }
    @Published private(set) var isFollowing = false
    @Published private(set) var isChangingCamera = false
    @Published private(set) var detectorReady = false
    @Published private(set) var ballBox: CGRect?
    @Published private(set) var ballConfidence: Double?
    @Published private(set) var proposalBoxes: [CGRect] = []
    @Published private(set) var scoredProposals: [BallCandidateRecord] = []
    @Published private(set) var hybridDecision: HybridDecision?
    /// What currently steers the camera, published only when it changes (the recording HUD observes it).
    enum CameraDriver: Equatable { case none, ball, players }
    @Published private(set) var cameraDriver = CameraDriver.none
    /// Mode chosen on the home screen; logged with the recording configuration.
    @Published private(set) var session: SessionSetup?
    // Pitch calibration: centre spot and both goals marked on the preview (full pitch, camera on the touchline).
    enum CalibrationStep: Equatable {
        case idle, leftGoal, rightGoal, review
        /// Behind a goal (« une moitié ») the marks are the camera's own goal, then the far one.
        func instruction(behindGoal: Bool) -> String {
            switch self {
            case .idle: ""
            case .leftGoal: behindGoal ? "1/2 — Touche le pied de ta cage" : "1/2 — Touche le pied de la cage de gauche"
            case .rightGoal: behindGoal ? "2/2 — Touche le pied de la cage d’en face" : "2/2 — Touche le pied de la cage de droite"
            case .review: "Le terrain tombe juste ?"
            }
        }
        var marking: Bool { self == .leftGoal || self == .rightGoal }
    }
    @Published private(set) var calibrationStep = CalibrationStep.idle
    /// Accepted calibration, used to ignore people off the pitch and to stop the pan beyond the goals.
    @Published private(set) var pitchCalibration: PitchCalibration?
    @Published private(set) var pendingCalibration: PitchCalibration?
    @Published private(set) var calibrationMessage = ""
    /// Projected pitch markings, normalized image coordinates; empty when hidden.
    @Published private(set) var pitchLines: [[CGPoint]] = []
    let attitude = CameraAttitude()
    private var calibrationRays: [PitchVector3] = []
    /// When the markings started to appear, for the drawing animation.
    private var pitchRevealStart: Double?
    private var calibrationWaitTask: Task<Void, Never>?
    private var pitchLinesTask: Task<Void, Never>?
    private var pitchFilterCounts = (kept: 0, removed: 0)
    /// The accepted pitch removed nearly every player for 10 s: it is still drawn but no longer filters.
    @Published private(set) var pitchFilterSuspended = false
    private var nearlyEmptyPitchWindows = 0
    /// Short message about the pitch shown on the filming screen (cleared when a calibration starts).
    @Published private(set) var pitchNotice: String?
    private var lastPitchFilterLog = -Double.infinity
    @Published private(set) var hybridPerformance = "Analyse des joueurs en attente"
    @Published var useHybrid = true {
        didSet {
            guard useHybrid != oldValue else { return }
            Self.save(useHybrid, "useHybrid")
            stop(message: "Mode changé ; relance le suivi")
            hybridPolicy.reset(); hybridDecision = nil; hybridReference = nil
            camera.setHybridEnabled(useHybrid)
            recordingWriter?.append("trackingMode", at: ProcessInfo.processInfo.systemUptime,
                value: ["mode": useHybrid ? "hybrid" : "ball"])
            logRecordingConfiguration()
        }
    }
    @Published var showDetectionBoxes = true { didSet { Self.save(showDetectionBoxes, "showDetectionBoxes") } }
    @Published var showSkeletons = true { didSet { Self.save(showSkeletons, "showSkeletons") } }
    @Published var showBodyOrientations = true { didSet { Self.save(showBodyOrientations, "showBodyOrientations") } }
    @Published var showDecisionTarget = true { didSet { Self.save(showDecisionTarget, "showDecisionTarget") } }
    @Published var hybridAcquire = 0.70 { didSet { Self.save(hybridAcquire, "hybridAcquire") } }
    @Published var hybridRetain = 0.25 { didSet { Self.save(hybridRetain, "hybridRetain") } }
    // Experimental, not validated on device: off leaves the hybrid ball reliability unchanged.
    @Published var hybridConfidenceWeighting = false {
        didSet {
            guard hybridConfidenceWeighting != oldValue else { return }
            Self.save(hybridConfidenceWeighting, "hybridConfidenceWeighting")
            logRecordingConfiguration()
        }
    }
    // Experimental, not validated on device: off leaves the player-guided framing unchanged.
    @Published var hybridStayWithGroup = false {
        didSet {
            guard hybridStayWithGroup != oldValue else { return }
            Self.save(hybridStayWithGroup, "hybridStayWithGroup")
            logRecordingConfiguration()
        }
    }
    private var hybridPolicy = HybridCameraPolicy()
    private var hybridReference: UUID?
    private var lastHybridLog = -Double.infinity
    @Published private(set) var selectionLocation: BallTrailPoint?
    @Published private(set) var ballMessage = "Chargement du détecteur de ballon…"
    @Published private(set) var followMessage = "Suivi arrêté"
    @Published private(set) var followVelocity = MotorVelocity.zero
    @Published private(set) var detectionDiagnostic = "En attente de la première analyse"
    @Published private(set) var detectionPerformance = "Mesure des analyses…"
    @Published private(set) var ballTrail: [BallTrailPoint] = []
    @Published var showBallTrail = true { didSet { Self.save(showBallTrail, "showBallTrail") } }
    @Published private(set) var ballMotionDescription = "Vitesse apparente en attente"
    @Published var deadZone = 0.005 { didSet { Self.save(deadZone, "deadZone"); logRecordingConfiguration() } }
    @Published var confidenceThreshold = 0.25 {
        didSet {
            Self.save(confidenceThreshold, "confidenceThreshold")
            logRecordingConfiguration()
            if useLocalSearchWindow { applyLocalSearchWindow() }
        }
    }
    // Experimental, not validated on device: off keeps whole-frame analysis unchanged.
    @Published var useLocalSearchWindow = false {
        didSet {
            guard useLocalSearchWindow != oldValue else { return }
            Self.save(useLocalSearchWindow, "useLocalSearchWindow")
            applyLocalSearchWindow(); logRecordingConfiguration()
        }
    }
    // Experimental, not validated on device: off passes every candidate unchanged.
    @Published var ignoreStaticCandidates = false {
        didSet {
            guard ignoreStaticCandidates != oldValue else { return }
            Self.save(ignoreStaticCandidates, "ignoreStaticCandidates")
            camera.setStaticCandidateFilter(enabled: ignoreStaticCandidates)
            logRecordingConfiguration()
        }
    }
    // Experimental, not validated on device: off leaves auto exposure at the device default.
    @Published var useShortExposure = false {
        didSet {
            guard useShortExposure != oldValue else { return }
            Self.save(useShortExposure, "useShortExposure")
            camera.setShortExposure(useShortExposure)
            logRecordingConfiguration()
        }
    }
    // Experimental, not validated on device: off never changes the tracking command.
    @Published var useAngleLimits = false {
        didSet {
            guard useAngleLimits != oldValue else { return }
            Self.save(useAngleLimits, "useAngleLimits")
            logRecordingConfiguration()
        }
    }
    /// Stand angles (radians) recorded by the user. Not persisted: cleared on every (re)connection,
    /// because DockKit does not document an absolute reference for angularPositions.
    @Published private(set) var leftYawLimit: Double?
    @Published private(set) var rightYawLimit: Double?
    @Published private(set) var lowPitchLimit: Double?
    @Published private(set) var standPosition: (pitch: Double, yaw: Double)?
    enum AngleLimitSide { case left, right, low }
    // Experimental, not validated on device: off leaves the zoom to the user only.
    @Published var useAutoZoom = false {
        didSet {
            guard useAutoZoom != oldValue else { return }
            Self.save(useAutoZoom, "useAutoZoom")
            if !useAutoZoom, let base = autoZoomBase { camera.rampAutoZoom(to: base, force: true) }
            autoZoomBase = nil
            logRecordingConfiguration()
        }
    }
    private var autoZoom = AutoZoomPolicy()
    /// The user's wide zoom; nil until the next automatic step re-reads it (after a pinch or camera change).
    private var autoZoomBase: CGFloat?
    // Off by default: the manual « À revoir » button does not depend on it.
    @Published var autoHighlights = false {
        didSet {
            guard autoHighlights != oldValue else { return }
            Self.save(autoHighlights, "autoHighlights")
            highlightDetector.reset()
            logRecordingConfiguration()
        }
    }
    private var highlightDetector = HighlightDetector()
    private var highlights: [HighlightMarker] = []
    @Published private(set) var highlightCount = 0
    @Published private(set) var diagnosticSnapshot: BallDiagnosticSnapshot?
    @Published private(set) var diagnosticImage: UIImage?
    @Published private(set) var isCapturing = false
    @Published private(set) var captureMessage = ""
    enum RecordingState { case idle, starting, recording, stopping }
    @Published private(set) var recordingState = RecordingState.idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var recordingMessage = ""
    @Published private(set) var recordings: [MatchRecording] = MatchRecording.stored()
    var isRecordingMatch: Bool { recordingState != .idle }
    var canRecord: Bool { isActive && camera.isRunning && !isChangingCamera && !camera.isSwitchingCamera && !isCapturing && !isRecordingMatch }
    private var recordingWriter: MatchLogWriter?
    private var recordingID: String?
    private var recordingDirectory: URL?
    private var recordingStartedAt = Date()
    private var recordingStartPTS: Double?
    private var recordingStartedHostTime: Double?
    private var recordingRotation = 90
    private var recordingFacing = "back"
    private var recordingSessionLabel: String?
    private var recordingHasAudio = false
    private var recordingInterrupted = false
    private var recordingTimer: Task<Void, Never>?
    private var recordingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastAnalysisArrival: TimeInterval?
    @Published var anticipateBall = true {
        didSet { Self.save(anticipateBall, "anticipateBall"); refreshAnticipatedTarget(); logRecordingConfiguration() }
    }
    @Published var anticipationSeconds = 0.03 {
        didSet { Self.save(anticipationSeconds, "anticipationSeconds"); refreshAnticipatedTarget(); logRecordingConfiguration() }
    }
    @Published private(set) var anticipatedTarget: BallTrailPoint?
    private var observation = BallObservationState()
    @Published private(set) var detectionSummary = "Détecteur en attente"
    private var latestTrackedBall: TrackedBall?
    private var freshnessTask: Task<Void, Never>?
    private var lastDetectionLog = -Double.infinity
    private var policy = BallFollowPolicy()
    private var latestTarget: BallTarget?
    private var followTask: Task<Void, Never>?
    private var lastDetectionTime: TimeInterval?
    private var detectorError: String?

    private var controller: MotorController?
    private var accessory: DockAccessory?
    private var observer: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var cameraTask: Task<Void, Never>?
    private var epoch = UUID()
    private var isActive = false
    private var cameraObservation: AnyCancellable?

    // Osmo remote takeover: trigger (DockKit tracking toggled by the accessory), joystick, DockKit errors.
    private enum RemotePause: Equatable { case trigger, recovery }
    private var remotePause: RemotePause?
    private var remotePauseSince: TimeInterval = 0
    private var resumeRequestedAt: TimeInterval?
    private var reclaimTicks = 0
    private var releaseTicks = 0
    private var lastTriggerResumeAt = -Double.infinity
    private var lastDriftLog = -Double.infinity
    private let journal = JournalFile()
    private var triggerWatchEnabled = true
    /// Consecutive automatic retries after DockKit errors; reset once following runs again.
    private var recoveryAttempts = 0
    private var lastKeepAlive = -Double.infinity
    private var lastIdleRetry = -Double.infinity
    private var panLeash = PlayerPanLeash()
    private var lastLeashLog = -Double.infinity
    /// Following was on when a pinch started: it resumes when the zoom ends.
    private var resumeAfterZoom = false
    private var motionHistory: [(time: TimeInterval, pitch: Double, yaw: Double)] = []
    private var commandHistory: [(time: TimeInterval, speed: Double)] = []
    private var eventsTask: Task<Void, Never>?
    private var listenStartedAt: TimeInterval = 0

    var canMove: Bool {
        isActive && accessory != nil && controller != nil && camera.isRunning
            && !isChangingCamera && !camera.isSwitchingCamera && !camera.isZooming
            && motorStatus == .ready && !isFollowing
    }
    var canFollow: Bool { canMove && detectorReady }
    /// Overlay state only: the shown ball is the one steering the camera (hybrid) or a confirmed track.
    var ballDrivesCamera: Bool {
        useHybrid ? (hybridDecision.map { $0.selectedBall != nil && $0.ballWeight >= 0.5 } ?? false) : latestTrackedBall != nil
    }
    var followStartBlocker: String? {
        if !isActive { return "App inactive" }
        if accessory == nil || controller == nil { return "Connecte l’Osmo via DockKit" }
        if !camera.isRunning { return "En attente de la caméra" }
        if isChangingCamera || camera.isSwitchingCamera { return "Changement de caméra…" }
        if motorStatus == .preparing || motorStatus == .stopping { return "Préparation du contrôle moteur…" }
        if motorStatus != .ready { return "Active le contrôle manuel" }
        if !detectorReady { return "En attente du détecteur" }
        return nil
    }

    init() {
        Self.restorePresetBackup()
        if UserDefaults.standard.object(forKey: "pitchlens.motorSpeed") != nil {
            let saved = UserDefaults.standard.double(forKey: "pitchlens.motorSpeed")
            speed = saved.isFinite ? min(0.30, max(0.05, saved)) : 0.20
        }
        // Property observers do not run here; camera-side settings are applied explicitly below.
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool? { defaults.object(forKey: "pitchlens." + key) as? Bool }
        func value(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            (defaults.object(forKey: "pitchlens." + key) as? Double).flatMap { $0.isFinite ? min(range.upperBound, max(range.lowerBound, $0)) : nil }
        }
        if let raw = defaults.string(forKey: "pitchlens.detectorProfile"), let profile = BallDetectorProfile(rawValue: raw) {
            camera.setDetectorProfile(profile)
        }
        useHybrid = flag("useHybrid") ?? useHybrid
        useLocalSearchWindow = flag("useLocalSearchWindow") ?? useLocalSearchWindow
        ignoreStaticCandidates = flag("ignoreStaticCandidates") ?? ignoreStaticCandidates
        useShortExposure = flag("useShortExposure") ?? useShortExposure
        hybridConfidenceWeighting = flag("hybridConfidenceWeighting") ?? hybridConfidenceWeighting
        hybridStayWithGroup = flag("hybridStayWithGroup") ?? hybridStayWithGroup
        useAngleLimits = flag("useAngleLimits") ?? useAngleLimits
        useAutoZoom = flag("useAutoZoom") ?? useAutoZoom
        autoHighlights = flag("autoHighlights") ?? autoHighlights
        showBallTrail = flag("showBallTrail") ?? showBallTrail
        showDetectionBoxes = flag("showDetectionBoxes") ?? showDetectionBoxes
        showSkeletons = flag("showSkeletons") ?? showSkeletons
        showBodyOrientations = flag("showBodyOrientations") ?? showBodyOrientations
        showDecisionTarget = flag("showDecisionTarget") ?? showDecisionTarget
        anticipateBall = flag("anticipateBall") ?? anticipateBall
        invertYaw = flag("invertYaw") ?? invertYaw
        invertPitch = flag("invertPitch") ?? invertPitch
        confidenceThreshold = value("confidenceThreshold", 0.15...0.75) ?? confidenceThreshold
        deadZone = value("deadZone", 0...0.05) ?? deadZone
        anticipationSeconds = value("anticipationSeconds", 0...0.06) ?? anticipationSeconds
        hybridAcquire = value("hybridAcquire", 0.50...0.95) ?? hybridAcquire
        hybridRetain = value("hybridRetain", 0.10...0.40) ?? hybridRetain
        camera.setHybridEnabled(useHybrid)
        camera.setStaticCandidateFilter(enabled: ignoreStaticCandidates)
        camera.setShortExposure(useShortExposure)
        applyLocalSearchWindow()
        camera.onUnavailable = { [weak self] in
            guard let self, self.isActive else { return }
            self.appendLog("Caméra indisponible ; arrêt demandé.")
            self.clearBallObservation()
            self.resetDetectionMetrics()
            self.detectorReady = false
            self.stop(message: "Caméra interrompue ; relance le suivi")
            self.stopRecording(interrupted: true)
        }
        camera.onDetection = { [weak self] frame in self?.receive(frame) }
        camera.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.clearBallObservation()
            self.resetDetectionMetrics()
            self.detectorReady = false
            self.ballMessage = "Nouvelle analyse en attente…"
            if self.isFollowing {
                self.stop(message: "Orientation ou modèle modifié ; relance le suivi")
            }
        }
        cameraObservation = camera.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        appendLog("iOS \(Self.osVersion) ; diagnostic DockKit prêt.")
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        attitude.start()
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                self.expireStaleObservation()
                self.superviseRemote()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        motorStatus = .unprepared
        let token = UUID()
        epoch = token
        let previousController = controller
        cameraTask = Task { [weak self] in
            guard let self else { return }
            await self.camera.start()
        }
        observer = Task { [weak self] in
            // Let the old connection's final zero finish before adopting another.
            await previousController?.waitUntilIdle()
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            self.controller = nil
            self.connectionMessage = "En attente de l'Osmo — appairage NFC DockKit"
            await self.listen(token: token)
        }
    }

    /// Subscribes to DockKit dock/undock events. Restarted by `superviseRemote` while no Osmo shows up.
    private func listen(token: UUID) async {
            listenStartedAt = ProcessInfo.processInfo.systemUptime
            self.appendLog("Écoute des connexions DockKit.")
            do {
                for await event in try DockAccessoryManager.shared.accessoryStateChanges {
                    guard self.epoch == token, !Task.isCancelled else { break }
                    self.appendLog("État DockKit : \(event.state)")
                    if event.state == .docked, let newAccessory = event.accessory {
                        if self.accessory == newAccessory { self.handleRedock(); continue }
                        await self.detach()
                        guard self.epoch == token, !Task.isCancelled else { break }
                        self.attach(newAccessory)
                    } else if event.state == .undocked,
                              event.accessory == nil || event.accessory == self.accessory {
                        await self.detach()
                        guard self.epoch == token else { break }
                        self.connectionMessage = "Osmo déconnecté"
                    }
                }
                if self.epoch == token, !Task.isCancelled {
                    await self.detach()
                    self.connectionMessage = "Écoute DockKit terminée ; relance la connexion"
                }
            } catch {
                guard self.epoch == token, !Task.isCancelled else { return }
                await self.detach()
                guard self.epoch == token else { return }
                self.connectionMessage = "Échec de la connexion DockKit"
                self.appendLog("ÉCHEC écoute DockKit : \(error)")
            }
    }

    func suspend() {
        guard isActive else { return }
        isActive = false
        attitude.stop()
        // The motion reference restarts with a new arbitrary heading: the pitch would be turned
        // somewhere else (18 Nov: every player « off the pitch » for 10 minutes after an NFC pairing).
        if pitchCalibration != nil || calibrationStep != .idle {
            clearCalibration()
            pitchNotice = "Terrain effacé : l’app a été quittée. Refais-le si besoin."
        }
        stopRecording(interrupted: true)
        cancelFollowing(message: isFollowing ? "App interrompue ; relance le suivi" : followMessage)
        freshnessTask?.cancel()
        freshnessTask = nil
        clearBallObservation()
        resetDetectionMetrics()
        detectorReady = false
        epoch = UUID()
        motorStatus = .closed
        observer?.cancel()
        observer = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        clearRemote()
        cameraTask?.cancel()
        camera.stop()
        controller?.close()
        accessory = nil
        accessoryName = nil
        connectionMessage = "Session suspendue"
        appendLog("App inactive ; commandes annulées et arrêt demandé.")
    }

    func reconnect() {
        suspend()
        activate()
    }

    func prepareManualControl() { cancelFollowing(); controller?.prepareManualControl() }
    func stop(message: String = "Suivi arrêté") {
        clearRemote()
        cancelFollowing(message: message)
        controller?.stop()
    }
    func enableSystemTracking() {
        guard isActive, camera.isRunning else { return }
        cancelFollowing()
        controller?.enableSystemTracking()
    }

    /// Suivre button: starts following, or first takes the motors back when the Osmo or a DockKit
    /// error left them (the follow starts by itself once control is back). Returns a blocker to show.
    func requestFollowing() -> String? {
        if canFollow { startFollowing(); return nil }
        let recoverable: [MotorController.Status] = [.failed, .systemTracking, .unprepared]
        if isActive, accessory != nil, let controller, camera.isRunning, !isFollowing,
           !isChangingCamera, !camera.isSwitchingCamera, !camera.isZooming, recoverable.contains(motorStatus) {
            appendLog("Suivre : reprise du contrôle moteur (état \(motorStatus.rawValue)).")
            remotePause = nil
            controller.prepareManualControl()
            resumeRequestedAt = ProcessInfo.processInfo.systemUptime
            followMessage = "Reprise du contrôle moteur…"
            return nil
        }
        return followStartBlocker ?? "réessaie"
    }

    func startFollowing() {
        guard canFollow else {
            followMessage = followStartBlocker ?? "Suivi déjà actif"
            appendLog("Suivi non démarré : \(followMessage)")
            return
        }
        guard controller?.startFollowing() == true else {
            followMessage = "Démarrage refusé ; réactive le contrôle manuel"
            appendLog(followMessage)
            return
        }
        isFollowing = true
        logRecordingConfiguration()
        policy.reset()
        panLeash.reset()
        appendLog(useHybrid ? "Suivi hybride démarré : ballon continu, relais joueurs et orientations." : "Suivi ballon démarré : visée au centre, accélération limitée, arrêt sur perte.")
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isFollowing, self.isActive, self.camera.isRunning else { return }
                self.followTick()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func cancelFollowing(message: String = "Suivi arrêté") {
        followTask?.cancel()
        followTask = nil
        isFollowing = false
        logRecordingConfiguration()
        policy.reset()
        followVelocity = .zero
        followMessage = message
    }

    private func receive(_ frame: BallDetectionFrame) {
        lastDetectionTime = frame.capturedAt
        let now = ProcessInfo.processInfo.systemUptime
        lastAnalysisArrival = now
        let age = now - frame.capturedAt
        // Record outcome at the end of every path, including stale/error results.
        defer {
            if let writer = recordingWriter {
                let outcome: String
                if frame.error != nil { outcome = "detector_error" }
                else if !age.isFinite || age < 0 || age > policy.maximumAge { outcome = "stale_or_invalid_time" }
                else if useHybrid {
                    outcome = hybridDecision?.target == nil ? "hybrid_waiting" : ((hybridDecision?.ballWeight ?? 0) >= 0.5 ? "hybrid_ball" : "hybrid_players")
                }
                else if latestTrackedBall != nil { outcome = "accepted" }
                else if observation.status == .rejected { outcome = "spatial_rejection" }
                else if observation.status == .confirming { outcome = "confirming" }
                else if frame.candidates.contains(where: { $0.confidence >= frame.profile.floor }) { outcome = "below_follow_threshold_or_outside_selected_region" }
                else { outcome = "no_raw_proposal_above_display_floor" }
                let boxes = frame.candidates.filter {
                    [$0.x, $0.y, $0.width, $0.height, $0.confidence].allSatisfy(\.isFinite)
                }.map { RecordedBallBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height, confidence: $0.confidence) }
                writer.append("analysis", at: frame.capturedAt, value: RecordingAnalysis(
                    frame: LiveFrameRecord(frame: frame, now: now, threshold: confidenceThreshold,
                        outcome: outcome, manuallySelected: selectionLocation != nil),
                    proposals: boxes, trackedX: useHybrid ? hybridDecision?.ballPoint?.x : latestTrackedBall?.x,
                    trackedY: useHybrid ? hybridDecision?.ballPoint?.y : latestTrackedBall?.y,
                    pitchCommand: followVelocity.pitch, yawCommand: followVelocity.yaw,
                    following: isFollowing, maximumSpeed: speed))
            }
        }
        let frequency = frame.analysesPerSecond.map { String(format: "%.1f analyses/s", $0) } ?? "Mesure des analyses…"
        detectionPerformance = String(format: "%@ · analyse %.0f ms · retard %.0f ms", frequency, frame.latency * 1000, age * 1000)
        let shutter = frame.captureTelemetry.exposureSeconds.map { String(format: " · exposition %.0f ms", $0 * 1000) } ?? ""
        detectionDiagnostic = "Caméra" + shutter + " · images ignorées \(frame.captureTelemetry.droppedFrames)"
        let score = frame.scoreDescription.map { "score ballon disponible \($0)" } ?? "aucun score ballon disponible"
        detectionDiagnostic += "\n" + String(format: "%@ · %@\nImage %.0f × %.0f · rotation %d° · %@\nAnalyse %.0f ms · âge %.0f ms\n%d proposition(s) · %@ · seuil %.0f %%\nObjets proposés : %@",
            frame.profile.title, frequency, frame.imageSize.width, frame.imageSize.height,
            frame.rotationAngle, frame.pixelFormatDescription, frame.latency * 1000, age * 1000, frame.candidateCount,
            score, confidenceThreshold * 100, frame.otherObjects.isEmpty ? "aucun" : frame.otherObjects)
        if useHybrid {
            if let people = frame.hybridPeople {
                detectionDiagnostic += String(format: "\nJoueurs : %d · âge %.0f ms · %@",
                    people.people.count, (now-people.timestamp)*1000, people.error ?? "analyse disponible")
            } else { detectionDiagnostic += "\nJoueurs : analyse en attente" }
        }
        if now - lastDetectionLog >= 2 {
            lastDetectionLog = now
            appendLog("Détection : \(detectionDiagnostic.replacingOccurrences(of: "\n", with: "; "))")
        }
        if let error = frame.error {
            detectorReady = false
            clearBallObservation()
            detectionPerformance = "Détecteur indisponible"
            ballMessage = "Détecteur indisponible : \(error)"
            if detectorError != error { appendLog("ÉCHEC détecteur : \(error)"); detectorError = error }
            if isFollowing { stop(message: "Erreur du détecteur ; relance le suivi après résolution") }
            return
        }
        detectorError = nil
        detectorReady = true
        guard age.isFinite, age >= 0, age <= policy.maximumAge else {
            clearBallObservation()
            ballMessage = String(format: "Image non exploitable pour le suivi · âge %.0f ms", age * 1000)
            detectionSummary = String(format: "%@ · image trop ancienne : %.0f ms", frame.profile.title, age * 1000)
            if isFollowing { followTick() }
            return
        }
        if useHybrid {
            if hybridReference != frame.hybridReferenceID {
                hybridPolicy.reset(); hybridReference = frame.hybridReferenceID
            }
            hybridPolicy.acquireReliability = hybridAcquire
            hybridPolicy.retainReliability = hybridRetain
            hybridPolicy.confidenceWeighting = hybridConfidenceWeighting
            // The user's threshold slider is the hybrid ball floor (library default 0.10).
            hybridPolicy.minimumBallConfidence = confidenceThreshold
            hybridPolicy.stayWithGroup = hybridStayWithGroup
            hybridDecision = hybridPolicy.update(candidates: ballsOnPitch(frame.candidates, at: frame.capturedAt), people: peopleOnPitch(peopleInPlay(frame.hybridPeople)),
                cameraCenter: frame.hybridCameraCenter, motionValid: frame.hybridMotionValid,
                timestamp: frame.capturedAt, now: now,
                imageAspectRatio: frame.imageSize.width / max(1, frame.imageSize.height))
            if let people = frame.hybridPeople {
                hybridPerformance = people.error ?? String(format: "Joueurs/poses %.0f ms · âge %.0f ms",
                    people.analysisMilliseconds, (now - people.timestamp) * 1000)
            }
            let zoomed = useAutoZoom ? updateAutoZoom(timestamp: frame.capturedAt) : nil
            if let hybridDecision, frame.capturedAt - lastHybridLog >= 0.2 {
                recordingWriter?.append("hybridDecision", at: frame.capturedAt, value: hybridDecision)
                if let zoomed { recordingWriter?.append("autoZoom", at: frame.capturedAt, value: zoomed) }
                lastHybridLog = frame.capturedAt
            }
        }
        observation.update(candidates: ballsOnPitch(frame.candidates, at: frame.capturedAt), timestamp: frame.capturedAt,
                           now: now, minimumConfidence: confidenceThreshold,
                           displayMinimumConfidence: frame.profile.floor)
        let tracked = observation.trackedBall
        proposalBoxes = frame.candidates.filter { $0.confidence >= frame.profile.floor }
            .sorted { $0.confidence > $1.confidence }.prefix(12).map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2, width: $0.width, height: $0.height)
            }
        scoredProposals = frame.candidates.filter { $0.confidence >= frame.profile.floor }.map(BallCandidateRecord.init)
        publishRawDetection()
        ballTrail = observation.points
        latestTrackedBall = tracked
        if let tracked {
            let accepted = tracked.detection
            latestTarget = BallTarget(x: tracked.x, y: tracked.y, confidence: accepted.confidence,
                                      timestamp: tracked.timestamp)
            ballMotionDescription = String(format: "À l’écran, lissé : H %+.0f %%/s · V %+.0f %%/s",
                                           tracked.velocityX * 100, tracked.velocityY * 100)
            ballMessage = String(format: "Ballon suivi %.0f %% · analyse %.0f ms", accepted.confidence * 100, frame.latency * 1000)
        } else {
            latestTarget = nil
            ballMotionDescription = "Vitesse en attente d’une position confirmée"
            switch observation.status {
            case .rejected: ballMessage = "Saut incohérent ignoré ; position du ballon en attente"
            case .confirming: ballMessage = "Confirmation du ballon sur plusieurs images…"
            default: ballMessage = frame.box == nil ? "Aucun ballon proposé par le modèle" : "Aucune position confirmée au-dessus du seuil"
            }
        }
        let rawScore: String
        if let raw = observation.rawDetection { rawScore = String(format: "Brut %.0f %%", raw.confidence * 100) }
        else if observation.selectionLocation != nil { rawScore = "Cible choisie absente" }
        else { rawScore = "Brut : aucun ballon" }
        let trackingStatus: String
        if tracked != nil { trackingStatus = "suivi confirmé" }
        else if observation.status == .rejected { trackingStatus = "saut rejeté" }
        else if observation.status == .confirming { trackingStatus = "confirmation…" }
        else { trackingStatus = "suivi en attente" }
        detectionSummary = "\(frame.profile.title) · \(rawScore) · \(trackingStatus)"
        refreshAnticipatedTarget(now: now)
        if useHybrid, let decision = hybridDecision {
            ballTrail = decision.trail.map { BallTrailPoint(x: $0.x, y: $0.y, timestamp: frame.capturedAt) }
            if let accepted = decision.selectedBall {
                ballBox = CGRect(x: accepted.x - accepted.width / 2, y: accepted.y - accepted.height / 2,
                                 width: accepted.width, height: accepted.height)
                ballConfidence = accepted.confidence
            }
            detectionSummary = String(format: "%@ · continuité %.0f %% · ballon %.0f %%", decision.mode,
                decision.reliability * 100, decision.ballWeight * 100)
        }
        if autoHighlights, recordingState == .recording {
            // Camera-compensated in hybrid mode, so panning with the ball is not "speed".
            let ball: HybridVector? = useHybrid
                ? hybridDecision.flatMap { decision in
                    decision.measured && decision.ballWeight >= 0.85
                        ? decision.ballPoint.map { $0 + frame.hybridCameraCenter - HybridVector(0.5, 0.5) } : nil }
                : tracked.map { HybridVector($0.x, $0.y) }
            if let kind = highlightDetector.update(timestamp: frame.capturedAt, ball: ball) {
                addHighlight(kind, at: frame.capturedAt)
            }
        }
        let driver: CameraDriver = useHybrid
            ? (hybridDecision.map { $0.target == nil ? .none : ($0.ballWeight >= 0.5 ? .ball : .players) } ?? .none)
            : (latestTrackedBall != nil ? .ball : .none)
        if cameraDriver != driver { cameraDriver = driver }
        // Only a newly accepted measurement can supply a nonzero motor target.
        if isFollowing { followTick() }
    }

    /// One policy step per hybrid analysis while following; the device ramps smoothly.
    private func updateAutoZoom(timestamp: Double) -> RecordingAutoZoom? {
        guard isFollowing, let decision = hybridDecision, camera.isRunning,
              !camera.isZooming, !camera.isSwitchingCamera, !isChangingCamera else { return nil }
        if autoZoomBase == nil {
            let base = max(1, camera.zoomFactor)
            autoZoomBase = base
            autoZoom = AutoZoomPolicy(maximum: min(2, Double(camera.maximumZoom / base)))
        }
        guard let base = autoZoomBase else { return nil }
        let ball = decision.measured && decision.reliability >= 0.7 ? decision.ballPoint : nil
        let relative = autoZoom.step(timestamp: timestamp, ball: ball,
                                     feet: decision.people.map(\.foot), focus: decision.target)
        camera.rampAutoZoom(to: base * CGFloat(relative))
        return RecordingAutoZoom(factor: Double(base) * relative, base: Double(base),
                                 relative: relative, reason: autoZoom.reason)
    }

    func markHighlight() {
        addHighlight(.manual, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Times use the host clock, like videoStartPTS: time - videoStartPTS is the video position.
    private func addHighlight(_ kind: HighlightMarker.Kind, at timestamp: Double) {
        guard recordingState == .recording, let start = recordingStartPTS ?? recordingStartedHostTime,
              timestamp.isFinite else { return }
        let marker = HighlightMarker(time: max(0, timestamp - start), kind: kind)
        highlights.append(marker)
        highlightCount = highlights.count
        recordingWriter?.append("highlight", at: timestamp, value: marker)
        writeHighlights()
        appendLog(String(format: "À revoir : %@ à %.1f s", marker.label, marker.time))
    }

    private func writeHighlights() {
        guard let directory = recordingDirectory else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(highlights).write(to: directory.appendingPathComponent("highlights.json"), options: .atomic)
    }

    var hasAngleLimits: Bool { (leftYawLimit != nil && rightYawLimit != nil) || lowPitchLimit != nil }

    func setAngleLimit(_ side: AngleLimitSide) {
        guard let position = standPosition else { return }
        switch side {
        case .left: leftYawLimit = position.yaw
        case .right: rightYawLimit = position.yaw
        case .low: lowPitchLimit = position.pitch
        }
        appendLog(String(format: "Limite d’angle : %@ à %.1f°", side == .left ? "gauche" : side == .right ? "droite" : "basse",
                         (side == .low ? position.pitch : position.yaw) * 180 / .pi))
    }

    func clearAngleLimits(reason: String = "Limites d’angle effacées.") {
        let had = leftYawLimit != nil || rightYawLimit != nil || lowPitchLimit != nil
        leftYawLimit = nil; rightYawLimit = nil; lowPitchLimit = nil
        if had { appendLog(reason) }
    }

    /// Outward velocity only is reduced, from the last reported stand angles. The last report is
    /// used even when old: a still stand may not stream positions, and blocking would trap it.
    private func limitedVelocity(_ raw: MotorVelocity) -> MotorVelocity {
        // Automatic zoom magnifies the image error; scale the command back so the motor gain stays the same.
        var velocity = raw
        if useAutoZoom, let base = autoZoomBase, camera.zoomFactor > base {
            let scale = Double(base / camera.zoomFactor)
            velocity = MotorVelocity(pitch: raw.pitch * scale, yaw: raw.yaw * scale)
        }
        var yaw = velocity.yaw, pitch = velocity.pitch
        if useAngleLimits, hasAngleLimits, let position = standPosition {
            if let left = leftYawLimit, let right = rightYawLimit {
                yaw = AngleLimits.clampYaw(velocity: yaw, yaw: position.yaw, limits: (left, right))
            }
            if let low = lowPitchLimit {
                // The follow policy lowers the camera with a positive error times this sign.
                pitch = AngleLimits.clampPitch(velocity: pitch, pitch: position.pitch, lowLimit: low,
                                               downSign: invertPitch ? -1 : 1)
            }
        }
        yaw = calibratedYaw(yaw)
        yaw = leashedYaw(yaw)
        return MotorVelocity(pitch: pitch, yaw: yaw)
    }

    /// Hybrid following: a pan driven by the players alone stays near the last ball direction
    /// (see PlayerPanLeash). Needs the phone's motion sensors; free without them.
    private func leashedYaw(_ yaw: Double) -> Double {
        guard useHybrid, isFollowing, let axis = attitude.axis() else { return yaw }
        let now = ProcessInfo.processInfo.systemUptime
        let ballDriving = (hybridDecision?.ballWeight ?? 0) >= 0.85 && hybridDecision?.ballPoint != nil
        let yawSign = invertYaw ? -1.0 : 1.0
        let rate = -yawSign * yaw
        let limited = panLeash.limit(azimuthRate: rate, azimuth: axis.azimuth, ballDriving: ballDriving, now: now)
        if abs(limited) < abs(rate) - 1e-6, now - lastLeashLog >= 3, let range = panLeash.range(now: now) {
            lastLeashLog = now
            appendLog(String(format: "Panoramique joueurs retenu à %.0f° du dernier ballon.", range * 180 / .pi))
        }
        return -yawSign * limited
    }

    private func publishRawDetection() {
        selectionLocation = observation.selectionLocation
        ballBox = observation.rawDetection.map {
            CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2, width: $0.width, height: $0.height)
        }
        ballConfidence = observation.rawDetection?.confidence
    }

    private func controlTarget(now: TimeInterval) -> BallTarget? {
        guard let tracked = latestTrackedBall else { return nil }
        if anticipateBall {
            return tracked.target(now: now, lead: anticipationSeconds)
        }
        return latestTarget
    }

    private func refreshAnticipatedTarget(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard anticipateBall, let tracked = latestTrackedBall, tracked.hasVelocity,
              let target = tracked.target(now: now, lead: anticipationSeconds) else {
            anticipatedTarget = nil
            return
        }
        anticipatedTarget = BallTrailPoint(x: target.x, y: target.y, timestamp: tracked.timestamp)
    }

    private func clearBallObservation() {
        hybridPolicy.reset(); hybridDecision = nil; hybridReference = nil
        scoredProposals = []
        latestTarget = nil
        latestTrackedBall = nil
        anticipatedTarget = nil
        ballBox = nil
        ballConfidence = nil
        proposalBoxes = []
        selectionLocation = nil
        observation.reset()
        detectionSummary = "Détecteur en attente"
        ballTrail = []
        ballMotionDescription = "Vitesse apparente en attente"
        if cameraDriver != .none { cameraDriver = .none }
    }

    private func resetDetectionMetrics() {
        lastAnalysisArrival = nil
        lastDetectionTime = nil
        detectionPerformance = "Mesure des analyses…"
        detectionDiagnostic = "En attente de la première analyse"
    }

    // Expire the overlay even when motor following is stopped or capture stalls.
    private func expireStaleObservation() {
        let now = ProcessInfo.processInfo.systemUptime
        observation.expire(now: now)
        if !useHybrid { publishRawDetection() }
        if let time = lastDetectionTime, now - time > policy.maximumAge {
            clearBallObservation()
            ballMessage = "Détection interrompue ; nouvelle image en attente"
        }
        if !useHybrid && ballTrail != observation.points { ballTrail = observation.points }
        if let target = latestTarget, now - target.timestamp > policy.maximumAge {
            clearBallObservation()
            ballMessage = "Détection interrompue ; nouvelle image en attente"
        }
        refreshAnticipatedTarget(now: now)
        if let arrival = lastAnalysisArrival, now - arrival > 1 {
            detectionPerformance = "Analyses interrompues"
        }
    }

    func selectBall(_ point: CGPoint) {
        guard camera.isRunning, !isChangingCamera, !camera.isSwitchingCamera else { return }
        if useHybrid { hybridPolicy.selectBall(HybridVector(point.x, point.y)); hybridDecision = nil }
        observation.selectBall(x: point.x, y: point.y)
        latestTarget = nil; latestTrackedBall = nil; anticipatedTarget = nil
        ballTrail = []; policy.reset()
        publishRawDetection()
        detectionSummary = "Ballon choisi · confirmation en attente"
        if isFollowing { followTick() }
    }

    func clearBallSelection() {
        clearBallObservation()
        policy.reset()
        if isFollowing { followTick() }
    }

    func setDetectorProfile(_ profile: BallDetectorProfile) {
        camera.setDetectorProfile(profile)
        UserDefaults.standard.set(profile.rawValue, forKey: "pitchlens.detectorProfile")
        appendLog("Modèle : \(profile.title) · \(profile.description)")
        logRecordingConfiguration()
    }

    func setCameraFacing(_ facing: CameraFacing) async {
        guard !isRecordingMatch else { recordingMessage = "Arrête la vidéo pour changer de caméra."; return }
        guard facing != camera.facing, !isChangingCamera, !camera.isSwitchingCamera else { return }
        isChangingCamera = true
        defer { isChangingCamera = false }
        stop(message: "Caméra modifiée ; relance le suivi")
        autoZoomBase = nil
        await controller?.waitUntilIdle()
        guard isActive else { return }
        await camera.setFacing(facing)
        appendLog("Caméra : \(camera.facing.title)")
    }

    func startRecording() {
        guard canRecord else { return }
        recordingState = .starting
        recordingDuration = 0
        recordingMessage = "Préparation de l’enregistrement…"
        recordingInterrupted = false
        recordingStartPTS = nil
        recordingHasAudio = false
        recordingStartedHostTime = nil
        recordingStartedAt = Date()
        recordingRotation = camera.rotationAngle
        recordingFacing = camera.facing.rawValue
        recordingSessionLabel = session?.summary
        highlights = []; highlightCount = 0; highlightDetector.reset()
        let id = UUID().uuidString
        recordingID = id
        Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try MatchRecording.rootDirectory().appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.recordingDirectory = directory
                self.recordingWriter = try MatchLogWriter(url: directory.appendingPathComponent("events.jsonl"))
                self.recordingWriter?.append("configuration", at: ProcessInfo.processInfo.systemUptime,
                    value: self.recordingConfiguration)
                self.recordingWriter?.append("trackingMode", at: ProcessInfo.processInfo.systemUptime,
                    value: ["mode": self.useHybrid ? "hybrid" : "ball"])
                if let pitch = self.pitchCalibration {
                    self.recordingWriter?.append("pitchCalibration", at: ProcessInfo.processInfo.systemUptime, value: pitch)
                }
                let initial = MatchRecording(id: id, startedAt: self.recordingStartedAt, durationSeconds: 0,
                    directory: directory, hasAudio: false, interrupted: true,
                    error: "Enregistrement interrompu avant finalisation ; le fichier peut être partiel.",
            sessionLabel: self.recordingSessionLabel)
                try self.writeRecordingReport(initial, logs: MatchLogSummary(writtenEvents: 0, droppedEvents: 0, error: nil))
                let delegate = MovieRecordingDelegate(onStart: { [weak self] pts in
                    Task { @MainActor [weak self] in
                        guard let self, self.recordingID == id else { return }
                        // Same host clock as the analysis timestamps (see BallDetector.captureSession).
                        let pts = pts.map { self.camera.hostSeconds(captureSeconds: $0) }
                        self.recordingStartPTS = pts
                        if let pts { self.recordingWriter?.setVideoStartPTS(pts) }
                        self.recordingStartedHostTime = ProcessInfo.processInfo.systemUptime
                        self.writeRecoveryReport(id: id)
                        if self.recordingState == .stopping { self.camera.stopMovie(); return }
                        self.recordingState = .recording
                        self.recordingMessage = "Enregistrement en cours"
                        self.appendLog("Vidéo démarrée ; horodatage initial \(pts.map { String(format: "%.6f", $0) } ?? "absent").")
                        self.recordingTimer = Task { [weak self] in
                            while !Task.isCancelled {
                                guard let self, self.recordingState == .recording,
                                      let began = self.recordingStartedHostTime else { return }
                                self.recordingDuration = ProcessInfo.processInfo.systemUptime - began
                                if Int(self.recordingDuration) % 10 == 0 { self.writeRecoveryReport(id: id) }
                                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                            }
                        }
                    }
                }, onFinish: { [weak self] error, successful in
                    Task { @MainActor [weak self] in await self?.finishRecording(id: id, error: error, successful: successful) }
                })
                let hasAudio = try await self.camera.startMovie(to: directory.appendingPathComponent("match.mov"), delegate: delegate)
                guard self.recordingID == id else { return }
                self.recordingHasAudio = hasAudio
                self.writeRecoveryReport(id: id)
                if self.recordingState == .stopping { self.camera.stopMovie() }
            } catch {
                await self.finishRecording(id: id, error: error.localizedDescription, successful: false)
            }
        }
    }

    func stopRecording(interrupted: Bool = false) {
        guard isRecordingMatch else { return }
        recordingInterrupted = recordingInterrupted || interrupted
        recordingState = .stopping
        recordingMessage = "Enregistrement de la vidéo…"
        recordingTimer?.cancel()
        if recordingBackgroundTask == .invalid {
            recordingBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finaliser le match") { [weak self] in
                Task { @MainActor [weak self] in self?.camera.stopMovie() }
            }
        }
        camera.stopMovie()
    }

    private var recordingConfiguration: RecordingConfiguration {
        RecordingConfiguration(profile: camera.detectorProfile.description, speedRadiansPerSecond: speed,
            confidenceThreshold: confidenceThreshold, centerTolerance: deadZone,
            anticipationSeconds: anticipateBall ? anticipationSeconds : 0, following: isFollowing,
            invertYaw: invertYaw, invertPitch: invertPitch,
            localSearchWindow: useLocalSearchWindow ? true : nil,
            ignoreStaticCandidates: ignoreStaticCandidates ? true : nil,
            shortExposure: useShortExposure ? true : nil,
            hybridConfidenceWeighting: hybridConfidenceWeighting ? true : nil,
            hybridBallFloor: useHybrid ? confidenceThreshold : nil,
            hybridStayWithGroup: hybridStayWithGroup ? true : nil,
            angleLimits: useAngleLimits ? true : nil,
            autoZoom: useAutoZoom ? true : nil,
            autoHighlights: autoHighlights ? true : nil,
            sessionMode: session?.mode.rawValue, matchFormat: session?.matchFormat,
            coverage: session?.coverage?.rawValue, cityStade: session?.cityStade)
    }

    // MARK: Session presets

    /// Settings a preset changed, with the values it set: on exit each one is restored only if
    /// the user did not change it meanwhile. Persisted so a killed app restores them at launch.
    private struct PresetBackup: Codable {
        var useHybrid: Bool, stayWithGroup: Bool
        var presetHybrid: Bool, presetStayWithGroup: Bool
    }
    private static let presetBackupKey = "pitchlens.presetBackup"

    func beginSession(_ setup: SessionSetup) {
        endSession(restoreLens: false)
        session = setup
        let ultraWide = setup.prefersUltraWide
        Task { await camera.setUltraWide(ultraWide) }
        if ultraWide { appendLog("Session : objectif ultra grand-angle (×0,5) demandé.") }
        if let preset = setup.preset {
            let backup = PresetBackup(useHybrid: useHybrid, stayWithGroup: hybridStayWithGroup,
                presetHybrid: preset.useHybrid, presetStayWithGroup: preset.stayWithGroup)
            if let data = try? JSONEncoder().encode(backup) { UserDefaults.standard.set(data, forKey: Self.presetBackupKey) }
            useHybrid = preset.useHybrid
            hybridStayWithGroup = preset.stayWithGroup
        }
        appendLog("Session : \(setup.summary)\(setup.preset.map { " · hybride \($0.useHybrid ? "oui" : "non"), rester avec le groupe \($0.stayWithGroup ? "oui" : "non")" } ?? " · réglages inchangés")")
        logRecordingConfiguration()
    }

    func endSession(restoreLens: Bool = true) {
        clearCalibration()
        pitchNotice = nil
        if restoreLens { Task { await camera.setUltraWide(false) } }
        if let data = UserDefaults.standard.data(forKey: Self.presetBackupKey),
           let backup = try? JSONDecoder().decode(PresetBackup.self, from: data) {
            UserDefaults.standard.removeObject(forKey: Self.presetBackupKey)
            if useHybrid == backup.presetHybrid { useHybrid = backup.useHybrid }
            if hybridStayWithGroup == backup.presetStayWithGroup { hybridStayWithGroup = backup.stayWithGroup }
            appendLog("Fin de session : réglages avancés rétablis.")
        }
        if session != nil { session = nil; logRecordingConfiguration() }
    }

    /// At launch (observers do not run in init): restore stored settings left by an interrupted session.
    private static func restorePresetBackup() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: presetBackupKey),
              let backup = try? JSONDecoder().decode(PresetBackup.self, from: data) else { return }
        defaults.removeObject(forKey: presetBackupKey)
        if (defaults.object(forKey: "pitchlens.useHybrid") as? Bool ?? true) == backup.presetHybrid {
            defaults.set(backup.useHybrid, forKey: "pitchlens.useHybrid")
        }
        if (defaults.object(forKey: "pitchlens.hybridStayWithGroup") as? Bool ?? false) == backup.presetStayWithGroup {
            defaults.set(backup.stayWithGroup, forKey: "pitchlens.hybridStayWithGroup")
        }
    }

    /// UI events worth keeping in the shared log (font fallback, navigation).
    func note(_ message: String) { appendLog(message) }

    private func applyLocalSearchWindow() {
        camera.setLocalSearchWindow(enabled: useLocalSearchWindow, followThreshold: confidenceThreshold)
    }

    private func logRecordingConfiguration() {
        recordingWriter?.append("configuration", at: ProcessInfo.processInfo.systemUptime, value: recordingConfiguration)
    }

    private func writeRecoveryReport(id: String) {
        guard recordingID == id, let directory = recordingDirectory else { return }
        let recoverable = MatchRecording(id: id, startedAt: recordingStartedAt, durationSeconds: recordingDuration,
            directory: directory, hasAudio: recordingHasAudio, interrupted: true,
            error: "Enregistrement interrompu avant finalisation ; le fichier peut être partiel.",
            sessionLabel: recordingSessionLabel)
        try? writeRecordingReport(recoverable, logs: MatchLogSummary(writtenEvents: 0, droppedEvents: 0, error: nil))
    }

    private func writeRecordingReport(_ recording: MatchRecording, logs: MatchLogSummary) throws {
        let report = MatchRecordingReport(recording: recording,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            camera: recordingFacing, videoRotation: recordingRotation, videoStartPTS: recordingStartPTS,
            logs: logs, notes: [
                "Video and audio are written independently of the Vision inference queue.",
                "Since build 45, analysis timestamps and videoStartPTS use the host clock (seconds since boot), converted from the capture clock; subtract videoStartPTS to align boxes with the video. With audio the video follows the microphone clock, so the alignment can drift by about 0.1 s over 30 min.",
                "Logs contain received analyses, not a detection for every encoded video frame. Boxes use normalized centers and the per-frame upright rotation.",
                "hybridDecision events include continuity, ball weight, selected target, player skeletons and orientation hypotheses. They are limited to 5 events per second and keep their capture timestamps.",
                "Recording orientation is fixed at start; preview orientation may change. Compressed video pixels may differ from original analyzed camera pixels.",
                "Disk writes are streamed with a bounded queue; dropped log events are counted. No recording is uploaded automatically."
            ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: recording.reportURL, options: .atomic)
    }

    private func finishRecording(id: String, error: String?, successful: Bool) async {
        guard recordingID == id else { return }
        // Claim this completion before awaiting to prevent duplicate callbacks.
        recordingID = nil
        recordingState = .stopping
        recordingTimer?.cancel(); recordingTimer = nil
        appendLog(error.map { "Fin vidéo : \($0)" } ?? "Vidéo arrêtée.")
        writeHighlights()
        let summary = await recordingWriter?.finish() ?? MatchLogSummary(writtenEvents: 0, droppedEvents: 0, error: nil)
        recordingWriter = nil
        if let directory = recordingDirectory {
            let asset = AVURLAsset(url: directory.appendingPathComponent("match.mov"))
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
            let measured = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? recordingDuration
            let recording = MatchRecording(id: id, startedAt: recordingStartedAt, durationSeconds: measured,
                directory: directory, hasAudio: audioTracks.map { !$0.isEmpty } ?? recordingHasAudio,
                interrupted: recordingInterrupted || !successful || error != nil, error: error ?? summary.error,
                sessionLabel: recordingSessionLabel)
            do {
                try writeRecordingReport(recording, logs: summary)
                recordings = MatchRecording.stored()
                recordingMessage = successful ? "Vidéo et logs enregistrés\(recording.hasAudio ? " avec son" : " sans son")."
                    : "Enregistrement interrompu : \(error ?? "consulte les logs"). Fichiers conservés."
                if let error = summary.error { recordingMessage += " Logs incomplets : \(error)" }
            } catch { recordingMessage = "Vidéo conservée ; journal final incomplet : \(error.localizedDescription)" }
        }
        recordingDirectory = nil
        recordingState = .idle
        if recordingBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(recordingBackgroundTask)
            recordingBackgroundTask = .invalid
        }
    }

    func captureDiagnosticFrame() async {
        guard !isCapturing, !isRecordingMatch else { return }
        stop()
        isCapturing = true
        captureMessage = "Capture de l’image analysée…"
        defer { isCapturing = false }
        do {
            let snapshot = try await camera.captureDiagnosticFrame()
            diagnosticSnapshot = snapshot
            diagnosticImage = UIImage(contentsOfFile: snapshot.imageURL.path)
            captureMessage = "Capture enregistrée ; image et résultats pris au même instant."
            appendLog("Capture diagnostic : \(snapshot.frame.profile.title), angle \(snapshot.frame.rotationAngle)°, score \(snapshot.frame.confidence), fichier \(snapshot.imageURL.lastPathComponent).")
        } catch {
            captureMessage = error.localizedDescription
            appendLog("ÉCHEC capture diagnostic : \(error)")
        }
    }

    private func followTick() {
        let now = ProcessInfo.processInfo.systemUptime
        policy.deadZone = deadZone
        policy.maximumSpeed = speed
        policy.minimumConfidence = useHybrid ? 0 : confidenceThreshold
        policy.invertYaw = invertYaw
        policy.invertPitch = invertPitch
        let hybridTarget = useHybrid ? hybridDecision?.motorTarget(now: now) : nil
        let fresh = useHybrid ? hybridTarget != nil : (latestTarget.map { now - $0.timestamp <= policy.maximumAge && $0.confidence >= confidenceThreshold } ?? false)
        if !fresh && !useHybrid {
            latestTarget = nil
            latestTrackedBall = nil
            anticipatedTarget = nil
            if let time = lastDetectionTime, now - time > policy.maximumAge { ballMessage = "Détection interrompue ; vitesse nulle" }
        }
        let target = useHybrid ? hybridTarget : (fresh ? controlTarget(now: now) : nil)
        let velocity = limitedVelocity(policy.velocity(for: target, now: now))
        followVelocity = velocity
        commandHistory.append((now, hypot(velocity.pitch, velocity.yaw)))
        commandHistory.removeAll { now - $0.time > 3 }
        recordingWriter?.append("motorCommand", at: now,
            value: RecordingMotorCommand(pitch: velocity.pitch, yaw: velocity.yaw, maximumSpeed: speed))
        let tolerance = min(0.10, max(0, deadZone))
        let centered = target.map {
            abs($0.x - 0.5) <= tolerance && abs($0.y - 0.5) <= tolerance
        } ?? false
        if useHybrid {
            followMessage = fresh ? (hybridDecision?.mode ?? "Suivi hybride") : "Aucun indice récent ; mouvement arrêté"
        } else if !fresh {
            followMessage = "Ballon perdu ; mouvement arrêté"
        } else {
            followMessage = centered ? "Ballon centré" : (anticipateBall ? "Recentrage avec anticipation" : "Recentrage lissé du ballon")
        }
        if controller?.updateFollowingVelocity(velocity) != true {
            cancelFollowing(message: "Commande refusée ; réactive le contrôle manuel")
            appendLog(followMessage)
        }
    }

    func zoomCamera(_ factor: CGFloat, state: UIGestureRecognizer.State) {
        guard camera.isRunning, !isChangingCamera else { return }
        if state == .began {
            // 18 Nov 2026: a pinch at 14:03 stopped following for 2 min 20 s. It now resumes after the gesture.
            resumeAfterZoom = isFollowing || resumeRequestedAt != nil
            stop(message: resumeAfterZoom ? "Zoom manuel ; le suivi reprend après le geste" : "Zoom manuel")
            clearBallObservation(); detectorReady = false
            camera.beginZoom()
        }
        guard camera.isZooming else { return }
        camera.setZoom(factor)
        if state == .ended || state == .cancelled || state == .failed {
            camera.endZoom { [weak self] actual in
                guard let self else { return }
                self.clearBallObservation(); self.detectorReady = false
                // The pinch overrides automatic zoom; its result is the new wide base.
                self.autoZoomBase = nil
                self.appendLog(String(format: "Zoom manuel ×%.2f ; nouvelle analyse en attente.",actual))
                if self.resumeAfterZoom {
                    self.resumeAfterZoom = false
                    self.resumeRequestedAt = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }

    enum Direction { case left, right, up, down }

    func move(_ direction: Direction) {
        guard canMove else { return }
        let yawSign = invertYaw ? -1.0 : 1.0
        let pitchSign = invertPitch ? -1.0 : 1.0
        let velocity: MotorVelocity
        switch direction {
        case .left: velocity = MotorVelocity(yaw: -speed * yawSign)
        case .right: velocity = MotorVelocity(yaw: speed * yawSign)
        case .up: velocity = MotorVelocity(pitch: -speed * pitchSign)
        case .down: velocity = MotorVelocity(pitch: speed * pitchSign)
        }
        controller?.pulse(velocity, duration: .milliseconds(Int64(pulseSeconds * 1_000)))
    }

    var diagnosticText: String {
        let header = "PitchLens DockKit\niOS: \(Self.osVersion)\nAccessoire: \(accessoryName ?? "absent")\nMatériel: \(hardware)\nFirmware: \(firmware)\nLimites: \(limitsDescription)\nTélémétrie: \(telemetry)\nDétection: \(ballMessage)\nSuivi: \(followMessage)\nTolérance au centre: \(deadZone), seuil: \(confidenceThreshold), vitesse: \(speed)\n"
        return header + logs.map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.message)" }.joined(separator: "\n")
    }

    private func attach(_ accessory: DockAccessory) {
        self.accessory = accessory
        accessoryName = accessory.identifier.name
        hardware = accessory.hardwareModel ?? "Non communiqué"
        firmware = accessory.firmwareVersion ?? "Non communiqué"
        connectionMessage = "Osmo connecté"
        standPosition = nil
        clearAngleLimits(reason: "Nouvelle connexion : limites d’angle effacées, à redéfinir.")
        appendLog(String(format: "Connecté après %.1f s d’écoute : ", ProcessInfo.processInfo.systemUptime - listenStartedAt)
                  + "\(accessory.identifier.name), modèle \(hardware), firmware \(firmware).")
        triggerWatchEnabled = true
        do {
            let limits = try accessory.limits
            limitsDescription = "pitch: \(String(describing: limits.pitch)); yaw: \(String(describing: limits.yaw))"
            appendLog("Limites annoncées : \(limitsDescription)")
        } catch {
            limitsDescription = "Non disponibles"
            appendLog("Lecture des limites impossible : \(error)")
        }
        let newController = MotorController(transport: DockKitTransport(accessory: accessory))
        let connectionEpoch = epoch
        newController.onStatus = { [weak self] status in
            guard let self, self.epoch == connectionEpoch else { return }
            self.motorStatus = status
            if status == .failed {
                if self.isFollowing || self.remotePause != nil || self.resumeRequestedAt != nil {
                    self.resumeRequestedAt = nil
                    self.remotePause = .recovery
                    self.remotePauseSince = ProcessInfo.processInfo.systemUptime
                }
                self.cancelFollowing(message: "Erreur DockKit ; consulte le journal")
            } else if status == .closed {
                self.cancelFollowing(message: self.isFollowing ? "Commandes suspendues ; relance le suivi" : self.followMessage)
            }
        }
        newController.onLog = { [weak self] message in self?.appendLog(message) }
        controller = newController
        newController.prepareManualControl()
        observeMotion(accessory, token: connectionEpoch)
    }

    private func detach() async {
        clearRemote()
        cancelFollowing(message: isFollowing ? "Osmo déconnecté ; relance le suivi" : followMessage)
        clearBallObservation()
        telemetryTask?.cancel()
        telemetryTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        let previous = controller
        previous?.close()
        accessory = nil
        accessoryName = nil
        motorStatus = .unprepared
        telemetry = "Aucune télémétrie reçue"
        standPosition = nil
        clearAngleLimits(reason: "Osmo déconnecté : limites d’angle effacées.")
        await previous?.waitUntilIdle()
        // A foreground transition may have already replaced this controller.
        if controller === previous { controller = nil }
    }

    private func observeMotion(_ accessory: DockAccessory, token: UUID) {
        telemetry = "En attente de la télémétrie"
        telemetryTask = Task { [weak self] in
            do {
                var lastLog = Date.distantPast
                for await state in try accessory.motionStates {
                    guard let self, self.epoch == token, self.accessory == accessory,
                          !Task.isCancelled else { break }
                    let position = state.angularPositions
                    let velocity = state.angularVelocities
                    if position.x.isFinite, position.y.isFinite {
                        self.standPosition = (position.x, position.y)
                        let now = ProcessInfo.processInfo.systemUptime
                        self.motionHistory.append((now, position.x, position.y))
                        self.motionHistory.removeAll { now - $0.time > 3 }
                    }
                    self.telemetry = String(format: "Angles : pitch %.1f° / yaw %.1f°\nVitesses : pitch %.3f / yaw %.3f rad/s",
                                            position.x * 180 / .pi, position.y * 180 / .pi, velocity.x, velocity.y)
                    if let error = state.error { self.appendLog("Erreur télémétrie : \(error)") }
                    if Date().timeIntervalSince(lastLog) >= 1 {
                        self.appendLog("Télémétrie : \(self.telemetry.replacingOccurrences(of: "\n", with: "; "))")
                        lastLog = Date()
                    }
                }
            } catch {
                guard let self, self.epoch == token, self.accessory == accessory,
                      !Task.isCancelled else { return }
                self.telemetry = "Télémétrie indisponible sur cet accessoire"
                self.appendLog("ÉCHEC télémétrie : \(error)")
            }
        }
    }

    private func observeEvents(_ accessory: DockAccessory, token: UUID) {
        eventsTask = Task { [weak self] in
            do {
                for await event in try accessory.accessoryEvents {
                    guard let self, self.epoch == token, self.accessory == accessory, !Task.isCancelled else { break }
                    self.appendLog("Événement Osmo : \(event)")
                }
            } catch {
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                self.appendLog("Événements Osmo indisponibles : \(error)")
            }
        }
    }

    private func clearRemote() {
        remotePause = nil
        resumeRequestedAt = nil
        recoveryAttempts = 0
    }

    /// The Osmo announced itself again while attached: commands usually fail until it does it once
    /// more, so a pending retry runs now and a failed motor is taken back.
    private func handleRedock() {
        appendLog("Osmo ré-annoncé par DockKit ; reprise du contrôle.")
        guard let controller else { return }
        if remotePause == .recovery { remotePauseSince = -Double.infinity }
        else if motorStatus == .failed || motorStatus == .unprepared, resumeRequestedAt == nil {
            lastIdleRetry = ProcessInfo.processInfo.systemUptime
            controller.prepareManualControl()
        }
    }

    /// Net angle travelled by the stand over the last `window` seconds (radians), nil without fresh telemetry.
    private func measuredTravel(now: TimeInterval, window: TimeInterval) -> Double? {
        guard let last = motionHistory.last, now - last.time < 0.4,
              let first = motionHistory.first(where: { $0.time >= now - window }),
              last.time - first.time >= window * 0.6 else { return nil }
        // Telemetry angles jump by 360° (pitch −355° for +5°): compare wrapped differences.
        return hypot(PlayerPanLeash.wrapped(last.pitch - first.pitch), PlayerPanLeash.wrapped(last.yaw - first.yaw))
    }

    /// Runs every 100 ms. The Osmo can take over: its trigger toggles DockKit tracking (seen as
    /// system tracking switched back on), its joystick moves the stand beyond what the app commanded,
    /// and a DockKit error stops the commands. Following pauses, then resumes on its own.
    private func superviseRemote() {
        let now = ProcessInfo.processInfo.systemUptime
        guard isActive else { return }
        guard let controller, accessory != nil else {
            clearRemote()
            return
        }
        // Trigger watch (polling DockKit's system tracking state) and the Osmo event stream are off:
        // with them on (builds 40–41) the Osmo undocked by itself about 6 s after each connection.
        // Joystick: journal only for now (a pause on this signal stopped following for nothing).
        if isFollowing, now - lastDriftLog >= 2, let travel = measuredTravel(now: now, window: 0.6) {
            let commanded = commandHistory.filter { $0.time >= now - 0.6 }.reduce(0) { $0 + $1.speed * 0.1 }
            if travel - commanded > 8 * .pi / 180 {
                lastDriftLog = now
                appendLog(String(format: "Écart moteur : %.1f° parcourus pour %.1f° commandés en 0,6 s.",
                                 travel * 180 / .pi, commanded * 180 / .pi))
            }
        }
        // After an error the Osmo often re-announces itself (« Docked ») and refuses commands
        // (notSupportedByDevice) for 1 to 25 s, then accepts them again (18 Nov 2026): retry
        // without limit, every 1 to 3 s, until following runs again or the user pauses.
        if remotePause == .recovery, now - remotePauseSince >= min(3, Double(max(1, recoveryAttempts))) {
            remotePause = nil
            recoveryAttempts += 1
            appendLog(recoveryAttempts == 1 ? "Erreur DockKit pendant le suivi : reprise du contrôle et du suivi."
                                            : "Osmo pas encore prêt : nouvel essai \(recoveryAttempts).")
            followMessage = "Osmo en reconnexion ; le suivi reprend tout seul"
            controller.prepareManualControl()
            resumeRequestedAt = now
        }
        // Not following: take control back quietly, so the arrows and the next « Suivre » work.
        if motorStatus == .failed, remotePause == nil, resumeRequestedAt == nil, now - lastIdleRetry >= 3 {
            lastIdleRetry = now
            controller.prepareManualControl()
        }
        if motorStatus == .ready, !isFollowing, now - lastKeepAlive >= 1, controller.keepAlive() {
            lastKeepAlive = now
        }
        if let requested = resumeRequestedAt {
            if isFollowing {
                resumeRequestedAt = nil
                recoveryAttempts = 0
            } else if canFollow {
                resumeRequestedAt = nil
                recoveryAttempts = 0
                startFollowing()
            } else if now - requested > 5 {
                resumeRequestedAt = nil
                followMessage = "Reprise impossible : \(followStartBlocker ?? "état moteur") ; touche Suivre"
                appendLog(followMessage)
            }
        }
    }

    private static func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: "pitchlens." + key)
    }

    private func appendLog(_ message: String) {
        #if DEBUG
        print("[PitchLens] \(message)")
        #endif
        recordingWriter?.append("event", at: ProcessInfo.processInfo.systemUptime, value: message)
        journal.write(message)
        logs.append(LogEntry(message: message))
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: Pitch calibration

extension DockKitModel {
    /// Back camera with motion sensors: the only setup where the image direction is known.
    var canCalibrate: Bool { attitude.isAvailable && camera.facing == .back && camera.fieldOfView > 0 }

    /// Match on one half: the camera stands behind a goal, so the marks are its goal then the far one.
    var calibratesBehindGoal: Bool { session?.coverage == .half }

    func cameraPose(at time: Double? = nil) -> CameraPose? {
        let size = camera.imageSize
        guard let axis = attitude.axis(at: time),
              let focal = CameraPose.focal(longSideFieldOfViewDegrees: camera.fieldOfView, zoom: Double(camera.zoomFactor),
                                           width: size.width, height: size.height) else { return nil }
        return CameraPose(axis: axis, focal: focal, width: size.width, height: size.height)
    }

    func beginCalibration() {
        guard canCalibrate else {
            calibrationMessage = "Calibrage indisponible : caméra arrière et capteurs de mouvement nécessaires."
            return
        }
        if isFollowing { stop(message: "Calibrage en cours") }
        calibrationRays = []
        pendingCalibration = nil
        pitchRevealStart = nil
        pitchNotice = nil
        calibrationStep = .leftGoal
        calibrationMessage = calibratesBehindGoal
            ? "La cage devant toi : au milieu, entre les deux poteaux, là où elle touche le sol. Ne bouge pas de ta place."
            : "Au milieu, entre les deux poteaux, là où la cage touche le sol. Ne bouge pas de ta place."
        startPitchLines()
        appendLog(calibratesBehindGoal ? "Calibrage du terrain commencé (derrière un but)." : "Calibrage du terrain commencé.")
    }

    /// From the home screen: the camera may still be starting, so wait for it (5 s at most).
    func beginCalibrationWhenReady() {
        calibrationWaitTask?.cancel()
        calibrationWaitTask = Task { [weak self] in
            for _ in 0..<50 {
                guard let self, !Task.isCancelled else { return }
                if self.canCalibrate { self.beginCalibration(); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            self?.beginCalibration()  // reports why it is unavailable
        }
    }

    /// Taps go to the calibration while it runs, otherwise to the ball selection.
    func handlePreviewTap(_ point: CGPoint) {
        switch calibrationStep {
        case .leftGoal, .rightGoal: markCalibrationPoint(point)
        case .review: break
        case .idle: selectBall(point)
        }
    }

    private func markCalibrationPoint(_ point: CGPoint) {
        guard let pose = cameraPose() else {
            calibrationMessage = "Orientation du téléphone inconnue ; réessaie dans un instant."
            return
        }
        let ray = pose.ray(HybridVector(Double(point.x), Double(point.y)))
        guard PitchCalibration.ground(ray) != nil else {
            calibrationMessage = "Ce point est au-dessus de l’horizon : touche le sol."
            return
        }
        calibrationRays.append(ray)
        if calibrationRays.count == 1 {
            calibrationStep = .rightGoal
            calibrationMessage = calibratesBehindGoal
                ? "Ta cage notée. Vise la cage d’en face, au milieu, au pied, sans changer de place (zoome si besoin)."
                : "Cage de gauche notée. Tourne-toi vers l’autre cage sans changer de place."
        } else { finishMarks() }
    }

    private func finishMarks() {
        let halfMode = calibratesBehindGoal
        guard calibrationRays.count == 2,
              let pitch = PitchCalibration.fromGoals(calibrationRays[0], calibrationRays[1], preferBehindGoal: halfMode) else {
            calibrationRays = []
            calibrationStep = .leftGoal
            calibrationMessage = halfMode
                ? "Terrain impossible avec ces deux points ; recommence par ta cage."
                : "Terrain impossible avec ces deux points ; recommence par la cage de gauche."
            appendLog("Calibrage du terrain refusé : points incohérents.")
            return
        }
        // The model follows the goals' directions, not the menu: behind a goal or on a touchline.
        let behindGoal = pitch.behindGoal
        pendingCalibration = pitch
        pitchRevealStart = ProcessInfo.processInfo.systemUptime
        calibrationStep = .review
        calibrationMessage = behindGoal
            ? "Largeur estimée d’après la longueur : vérifie les lignes de côté, puis valide."
            : (halfMode ? "Caméra sur le côté : largeur mesurée depuis ta place. Vérifie les lignes, puis valide."
                        : "Tourne le téléphone pour voir tout le terrain, puis valide.")
        let (length, width) = behindGoal ? (2 * pitch.halfWidth, 2 * pitch.halfLength) : (2 * pitch.halfLength, 2 * pitch.halfWidth)
        appendLog(String(format: "Calibrage proposé (%@) : longueur %.1f, largeur %.1f (en hauteurs de caméra), buts dans l’ordre %@.",
                         behindGoal ? "derrière un but" : "depuis une ligne de touche", length, width, pitch.goalsInOrder ? "oui" : "non"))
        refreshPitchLines()
    }

    func acceptCalibration() {
        guard let pitch = pendingCalibration else { return }
        pitchCalibration = pitch
        pendingCalibration = nil
        calibrationStep = .idle
        calibrationMessage = ""
        pitchFilterCounts = (0, 0)
        pitchFilterSuspended = false
        nearlyEmptyPitchWindows = 0
        pitchNotice = nil
        recordingWriter?.append("pitchCalibration", at: ProcessInfo.processInfo.systemUptime, value: pitch)
        appendLog("Calibrage validé : joueurs hors du terrain ignorés, pas de panoramique au-delà des buts.")
        refreshPitchLines()
    }

    /// Leaves the marking; a calibration accepted before stays in use.
    func cancelCalibration() {
        calibrationWaitTask?.cancel()
        calibrationRays = []
        pendingCalibration = nil
        calibrationStep = .idle
        calibrationMessage = ""
        if pitchCalibration == nil { stopPitchLines() } else { refreshPitchLines() }
    }

    /// The user removes the pitch: following goes on without it.
    func removeCalibration() {
        clearCalibration()
        pitchNotice = nil
    }

    func clearCalibration() {
        let had = pitchCalibration != nil || calibrationStep != .idle
        cancelCalibration()
        pitchCalibration = nil
        pitchFilterSuspended = false
        nearlyEmptyPitchWindows = 0
        stopPitchLines()
        if had { appendLog("Calibrage du terrain effacé.") }
    }

    private func startPitchLines() {
        pitchLinesTask?.cancel()
        pitchLinesTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshPitchLines()
                do { try await Task.sleep(for: .milliseconds(66)) } catch { return }
            }
        }
    }

    private func stopPitchLines() {
        pitchLinesTask?.cancel(); pitchLinesTask = nil
        pitchLines = []
    }

    /// Lines of the calibration under review, or of the accepted one, drawn from the current attitude.
    /// Each ground segment is subdivided so the parts behind the camera can be dropped.
    private func refreshPitchLines() {
        guard let pose = cameraPose() else {
            if !pitchLines.isEmpty { pitchLines = [] }
            return
        }
        var lines: [[CGPoint]] = []
        // A cross on each goal already marked, so the first tap stays visible while turning.
        for ray in calibrationStep.marking ? calibrationRays : [] {
            guard let ground = PitchCalibration.ground(ray),
                  let p = pose.project(PitchCalibration.direction(to: ground)) else { continue }
            let r = 0.018
            lines.append([CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y + r)])
            lines.append([CGPoint(x: p.x - r, y: p.y + r), CGPoint(x: p.x + r, y: p.y - r)])
        }
        guard let pitch = pendingCalibration ?? pitchCalibration else { pitchLines = lines; return }
        if pitchLinesTask == nil { startPitchLines() }
        // The markings draw themselves over 1.5 s after the second tap.
        let reveal = pitchRevealStart.map { min(1, (ProcessInfo.processInfo.systemUptime - $0) / 1.5) } ?? 1
        for full in pitch.markings() {
            let polyline = reveal >= 1 ? full : Array(full.prefix(max(2, Int(ceil(Double(full.count) * reveal)))))
            var current: [CGPoint] = []
            for (a, b) in zip(polyline, polyline.dropFirst()) {
                for k in 0..<16 {
                    let t = Double(k) / 16
                    let ground = a * (1 - t) + b * t
                    if let p = pose.project(PitchCalibration.direction(to: ground)), abs(p.x - 0.5) < 3, abs(p.y - 0.5) < 3 {
                        current.append(CGPoint(x: p.x, y: p.y))
                    } else if current.count > 1 { lines.append(current); current = [] } else { current = [] }
                }
            }
            if let last = polyline.last, let p = pose.project(PitchCalibration.direction(to: last)) {
                current.append(CGPoint(x: p.x, y: p.y))
            }
            if current.count > 1 { lines.append(current) }
        }
        pitchLines = lines
    }

    /// Tall bodies cut by the bottom of the image stand next to the camera (substitutes, spectators):
    /// on 18 Nov 2026 they pulled the players target away from the play, with or without a pitch.
    func peopleInPlay(_ snapshot: HybridPeopleSnapshot?) -> HybridPeopleSnapshot? {
        guard var snapshot else { return nil }
        snapshot.people.removeAll(where: \.isCutOffNearCamera)
        return snapshot
    }

    /// People whose feet fall outside the calibrated pitch (spectators, substitutes, the next pitch)
    /// are removed before the hybrid policy. Ankles are used when the pose found them.
    func peopleOnPitch(_ snapshot: HybridPeopleSnapshot?) -> HybridPeopleSnapshot? {
        guard let pitch = pitchCalibration, !pitchFilterSuspended, var snapshot,
              let pose = cameraPose(at: snapshot.timestamp) else { return snapshot }
        let before = snapshot.people.count
        snapshot.people = snapshot.people.filter { person in
            let ankles = person.joints.count == 17 ? [person.joints[15], person.joints[16]].filter { $0.confidence >= 0.4 && $0.point.finite } : []
            let foot = ankles.isEmpty ? person.foot : ankles.map(\.point).reduce(.zero, +) / Double(ankles.count)
            return pitch.containsFoot(pose.ray(foot))
        }
        pitchFilterCounts.kept += snapshot.people.count
        pitchFilterCounts.removed += before - snapshot.people.count
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPitchFilterLog >= 5 {
            lastPitchFilterLog = now
            if pitchFilterCounts.kept + pitchFilterCounts.removed > 0 {
                appendLog("Terrain : \(pitchFilterCounts.removed) détection(s) de personnes hors terrain ignorée(s), \(pitchFilterCounts.kept) gardée(s) (5 s).")
                recordingWriter?.append("pitchFilter", at: snapshot.timestamp,
                    value: ["kept": pitchFilterCounts.kept, "removed": pitchFilterCounts.removed])
            }
            // Safety net: two windows in a row keeping under 10 % of many detections mean a wrong pitch
            // (badly placed, or turned after a restart), not an empty one. Following needs the players.
            let total = pitchFilterCounts.kept + pitchFilterCounts.removed
            nearlyEmptyPitchWindows = total >= 60 && pitchFilterCounts.kept * 10 < total ? nearlyEmptyPitchWindows + 1 : 0
            if nearlyEmptyPitchWindows >= 2 {
                pitchFilterSuspended = true
                pitchNotice = "Terrain ignoré : il écartait presque tous les joueurs. Refais-le ou efface-le."
                appendLog("Terrain ignoré : moins de 10 % des personnes gardées pendant 10 s ; filtre suspendu.")
            }
            pitchFilterCounts = (0, 0)
        }
        return snapshot
    }

    /// Ball candidates whose contact point is behind the camera's own touchline (spare balls by the
    /// bench, a warm-up at the side) are dropped. Elsewhere an airborne ball may project off the pitch,
    /// so nothing else is filtered.
    func ballsOnPitch(_ candidates: [BallCandidate], at time: Double) -> [BallCandidate] {
        guard let pitch = pitchCalibration, !pitchFilterSuspended, !candidates.isEmpty,
              let pose = cameraPose(at: time) else { return candidates }
        return candidates.filter { !pitch.isBehindNearTouchline(pose.ray(HybridVector($0.x, $0.y + $0.height / 2))) }
    }

    /// No pan beyond either goal (plus 4°). Turning left raises the azimuth; a left command is −yawSign.
    func calibratedYaw(_ yaw: Double) -> Double {
        guard let pitch = pitchCalibration, !pitchFilterSuspended, pitch.goalsInOrder, let axis = attitude.axis() else { return yaw }
        let margin = 4 * Double.pi / 180
        let yawSign = invertYaw ? -1.0 : 1.0
        let azimuthRate = -yawSign * yaw
        let limited = AngleLimits.clamp(velocity: azimuthRate, position: pitch.relativeAzimuth(axis.azimuth),
                                        lower: pitch.relativeAzimuth(pitch.rightAzimuth) - margin,
                                        upper: pitch.relativeAzimuth(pitch.leftAzimuth) + margin)
        return -yawSign * limited
    }
}

/// The session journal on disk (Documents/Logs, ten most recent launches), also when not filming.
@MainActor
final class JournalFile {
    private var handle: FileHandle?
    private let clock: DateFormatter

    init() {
        clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
        let manager = FileManager.default
        guard let documents = try? manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        let directory = documents.appendingPathComponent("Logs", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in old.dropFirst(9) { try? manager.removeItem(at: file) }
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("journal-\(name.string(from: Date())).txt")
        manager.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ message: String) {
        try? handle?.write(contentsOf: Data((clock.string(from: Date()) + " " + message + "\n").utf8))
    }
}
