import AVFoundation
import Foundation
import Photos

struct MatchRecording: Identifiable, Codable, Sendable {
    let id: String
    let startedAt: Date
    let durationSeconds: Double
    let directory: URL
    let hasAudio: Bool
    let interrupted: Bool
    let error: String?
    /// Session summary at start (e.g. « 7V7 · TOUT LE TERRAIN »); absent in older recordings.
    var sessionLabel: String? = nil
    var videoURL: URL { directory.appendingPathComponent("match.mov") }
    var logsURL: URL { directory.appendingPathComponent("events.jsonl") }
    var reportURL: URL { directory.appendingPathComponent("recording.json") }
    var highlightsURL: URL { directory.appendingPathComponent("highlights.json") }
    var shareURLs: [URL] { [videoURL, logsURL, reportURL, highlightsURL].filter { FileManager.default.fileExists(atPath: $0.path) } }
    /// Empty file written once the video is in Photos, so it is not added twice.
    private var photosMarkerURL: URL { directory.appendingPathComponent("saved-to-photos") }
    var isSavedToPhotos: Bool { FileManager.default.fileExists(atPath: photosMarkerURL.path) }

    static func stored(in root: URL? = nil) -> [MatchRecording] {
        guard let root = root ?? (try? rootDirectory()),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("recording.json")),
                  let report = try? JSONDecoder().decode(MatchRecordingReport.self, from: data) else { return nil }
            // Use the current container URL, since iOS may move it on reinstall.
            return MatchRecording(id: report.recording.id, startedAt: report.recording.startedAt,
                durationSeconds: report.recording.durationSeconds, directory: folder,
                hasAudio: report.recording.hasAudio, interrupted: report.recording.interrupted, error: report.recording.error,
                sessionLabel: report.recording.sessionLabel)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    static func rootDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("MatchRecordings", isDirectory: true)
    }

    func saveToPhotos() async throws {
        let asset = AVURLAsset(url: videoURL)
        guard (try? await asset.load(.isPlayable)) == true else {
            throw NSError(domain: "PitchLens.Recording", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Cette vidéo est absente ou incomplète. Les fichiers restent partageables."])
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "PitchLens.Recording", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Autorise l’ajout aux Photos dans les réglages de l’iPhone."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
        FileManager.default.createFile(atPath: photosMarkerURL.path, contents: Data())
    }
}

struct MatchRecordingReport: Codable, Sendable {
    let recording: MatchRecording
    let appBuild: String
    let camera: String
    let videoRotation: Int
    let videoStartPTS: Double?
    let logs: MatchLogSummary
    let notes: [String]
}

struct RecordingConfiguration: Codable, Sendable {
    let profile: String
    let speedRadiansPerSecond: Double
    let confidenceThreshold: Double
    let centerTolerance: Double
    let anticipationSeconds: Double
    let following: Bool
    let invertYaw: Bool
    let invertPitch: Bool
    // Present only when on, so configuration events with these settings off are unchanged.
    var localSearchWindow: Bool? = nil
    var ignoreStaticCandidates: Bool? = nil
    var shortExposure: Bool? = nil
    var hybridConfidenceWeighting: Bool? = nil
    /// Lowest ball score the hybrid policy considers (the threshold slider); present in hybrid mode only.
    var hybridBallFloor: Double? = nil
    var hybridStayWithGroup: Bool? = nil
    var angleLimits: Bool? = nil
    var autoZoom: Bool? = nil
    var autoHighlights: Bool? = nil
    /// Home-screen session (« match », « solo », « libre »); absent when no session is active.
    var sessionMode: String? = nil
    var matchFormat: Int? = nil
    /// « full » (camera on the touchline at halfway) or « half » (camera behind a goal).
    var coverage: String? = nil
    var cityStade: Bool? = nil
}

/// Mode chosen on the home screen. Format, coverage and city stade are recorded only:
/// they do not change tracking yet.
struct SessionSetup: Equatable, Sendable {
    enum Mode: String, Sendable { case match, solo, libre }
    enum Coverage: String, Sendable { case full, half }
    var mode: Mode
    var matchFormat: Int? = nil
    var coverage: Coverage? = nil
    var cityStade: Bool? = nil

    static func match(format: Int, coverage: Coverage, cityStade: Bool) -> SessionSetup {
        SessionSetup(mode: .match, matchFormat: format, coverage: coverage, cityStade: cityStade)
    }

    /// Settings forced for the session (restored afterwards); nil leaves the advanced settings untouched.
    var preset: (useHybrid: Bool, stayWithGroup: Bool)? {
        switch mode {
        case .match: (true, true)
        // Solo: hybrid without group logic, so the lone player takes over when the ball is lost.
        case .solo: (true, false)
        case .libre: nil
        }
    }

    /// Small pitches (five, city stade) fit only in the ultra wide (×0.5) lens.
    var prefersUltraWide: Bool { mode == .match && (cityStade == true || matchFormat == 5) }

    var summary: String {
        switch mode {
        case .match:
            let format = matchFormat ?? 7
            var text = "\(format)V\(format) · " + (coverage == .half ? "UNE MOITIÉ" : "TOUT LE TERRAIN")
            if cityStade == true { text += " · CITY STADE" }
            return text
        case .solo: return "SOLO · BALLON"
        case .libre: return "LIBRE"
        }
    }
}

/// Logged with hybridDecision (at most 5 per second) while automatic zoom is on and following.
struct RecordingAutoZoom: Codable, Sendable {
    let factor: Double
    let base: Double
    let relative: Double
    let reason: String
}

struct RecordedBallBox: Codable, Sendable {
    let x: Double, y: Double, width: Double, height: Double, confidence: Double
}

struct RecordingAnalysis: Codable, Sendable {
    let frame: LiveFrameRecord
    let proposals: [RecordedBallBox]
    let trackedX: Double?
    let trackedY: Double?
    let pitchCommand: Double
    let yawCommand: Double
    let following: Bool
    let maximumSpeed: Double
}

struct RecordingMotorCommand: Codable, Sendable {
    let pitch: Double
    let yaw: Double
    let maximumSpeed: Double
}

/// NSObject delegate stays off the MainActor; callbacks transfer only immutable values.
final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let onStart: @Sendable (Double?) -> Void
    let onFinish: @Sendable (String?, Bool) -> Void
    init(onStart: @escaping @Sendable (Double?) -> Void,
         onFinish: @escaping @Sendable (String?, Bool) -> Void) {
        self.onStart = onStart; self.onFinish = onFinish
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    startPTS: CMTime, from connections: [AVCaptureConnection]) {
        let seconds = CMTimeGetSeconds(startPTS)
        onStart(seconds.isFinite ? seconds : nil)
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let successful = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        onFinish(error?.localizedDescription, successful)
    }
}
