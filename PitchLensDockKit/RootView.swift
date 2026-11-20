import Combine
import SwiftUI
import UIKit

/// The few model values the redesigned screens show, republished only when they change.
/// Screens observe this instead of the model, whose analysis results change 30 times per second.
@MainActor
final class AppStatus: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var latestRecording: MatchRecording?
    @Published private(set) var recordingState = DockKitModel.RecordingState.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var highlights = 0
    @Published private(set) var following = false
    @Published private(set) var driver = DockKitModel.CameraDriver.none
    @Published private(set) var session: SessionSetup?
    @Published private(set) var recordingMessage = ""
    @Published private(set) var calibrationStep = DockKitModel.CalibrationStep.idle
    @Published private(set) var calibrationMessage = ""
    @Published private(set) var calibrated = false
    @Published private(set) var pitchNotice: String?
    private var subscriptions = Set<AnyCancellable>()

    init(model: DockKitModel) {
        model.$accessoryName.map { $0 != nil }.removeDuplicates().assign(to: &$connected)
        model.$recordings.map(\.first).assign(to: &$latestRecording)
        model.$recordingState.removeDuplicates().assign(to: &$recordingState)
        model.$recordingDuration.map { $0.rounded(.down) }.removeDuplicates().assign(to: &$elapsed)
        model.$highlightCount.removeDuplicates().assign(to: &$highlights)
        model.$isFollowing.removeDuplicates().assign(to: &$following)
        model.$cameraDriver.removeDuplicates().assign(to: &$driver)
        model.$session.removeDuplicates().assign(to: &$session)
        model.$recordingMessage.removeDuplicates().assign(to: &$recordingMessage)
        model.$calibrationStep.removeDuplicates().assign(to: &$calibrationStep)
        model.$calibrationMessage.removeDuplicates().assign(to: &$calibrationMessage)
        model.$pitchCalibration.map { $0 != nil }.removeDuplicates().assign(to: &$calibrated)
        model.$pitchNotice.removeDuplicates().assign(to: &$pitchNotice)
        model.$isFollowing.combineLatest(model.$recordingState)
            .map { following, state in following || state != .idle }
            .removeDuplicates()
            .sink { UIApplication.shared.isIdleTimerDisabled = $0 }
            .store(in: &subscriptions)
    }
}

@MainActor
struct RootView: View {
    let model: DockKitModel
    @StateObject private var status: AppStatus
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = Screen.home
    @State private var showSettings = false
    @State private var showRecordings = false

    enum Screen: Equatable { case home, match, recording(kickoff: Bool) }

    init(model: DockKitModel) {
        self.model = model
        _status = StateObject(wrappedValue: AppStatus(model: model))
    }

    var body: some View {
        ZStack {
            PL.ground.ignoresSafeArea()
            switch screen {
            case .home:
                HomeView(status: status, onMatch: { screen = .match },
                    onSolo: { start(SessionSetup(mode: .solo), kickoff: true) },
                    onLibre: { start(SessionSetup(mode: .libre), kickoff: false) },
                    onSettings: { showSettings = true },
                    onRecordings: { model.stop(); showRecordings = true },
                    onBuildPitch: {
                        // Libre session: no tracking preset, works handheld without the gimbal.
                        start(SessionSetup(mode: .libre), kickoff: false)
                        model.beginCalibrationWhenReady()
                    })
            case .match:
                MatchSetupView(onBack: { screen = .home },
                    onKickoff: { start($0, kickoff: true) })
            case .recording(let kickoff):
                RecordingScreen(model: model, status: status, kickoff: kickoff, onExit: {
                    model.stop()
                    model.endSession()
                    screen = .home
                })
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { AdvancedSettingsView(model: model) }
        .sheet(isPresented: $showRecordings) { RecordingLibrary(recordings: model.recordings) }
        .task {
            if scenePhase == .active { model.activate() }
            model.note(PL.customFontsAvailable ? "Police Inter Tight chargée." : "Police Inter Tight absente ; police système utilisée.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.activate() }
            else if phase == .background { model.suspend() }
            else if model.isFollowing { model.stop(message: "App inactive ; suivi arrêté") }
        }
    }

    private func start(_ setup: SessionSetup, kickoff: Bool) {
        model.beginSession(setup)
        screen = .recording(kickoff: kickoff)
    }
}

// MARK: Home

@MainActor
struct HomeView: View {
    @ObservedObject var status: AppStatus
    let onMatch: () -> Void
    let onSolo: () -> Void
    let onLibre: () -> Void
    let onSettings: () -> Void
    let onRecordings: () -> Void
    let onBuildPitch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                title.padding(.top, 16)
                matchSlab.padding(.top, 36)
                HStack(spacing: 12) {
                    soloCard
                    libreCard
                }
                .padding(.top, 42)
                buildPitchButton.padding(.top, 16)
                if let recording = status.latestRecording {
                    lastFilm(recording).padding(.top, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8).padding(.bottom, 20)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(PL.ground.ignoresSafeArea())
        .foregroundStyle(PL.paper)
        .plGrain()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("PL—01").plLabel(11, tracking: 0.1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Rectangle().fill(status.connected ? PL.neon : PL.orange).frame(width: 8, height: 8)
                Text(status.connected ? "PIED CONNECTÉ" : "PIED NON CONNECTÉ").plLabel(11, tracking: 0.1)
            }
            .accessibilityElement(children: .combine)
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Réglages avancés")
        }
        .frame(minHeight: 44)
    }

    private var title: some View {
        HStack(spacing: 0) {
            Text("On filme ").plDisplay(28, .extraBold)
            Text("quoi").plDisplay(28, .black)
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 4)
                .background(PL.violet, in: Capsule())
                .rotationEffect(.degrees(-4))
                .padding(.horizontal, 2)
            Text(" ?").plDisplay(28, .extraBold)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var matchSlab: some View {
        Button(action: onMatch) {
            ZStack(alignment: .topLeading) {
                PL.neon
                Canvas { context, size in
                    let t = SVGPath.fit(PitchDrawing.viewBox, in: CGRect(x: 22, y: 22, width: min(290, size.width - 60), height: 166))
                    let style = StrokeStyle(lineWidth: 2.4 * t.a, lineCap: .round, lineJoin: .round)
                    context.stroke(PitchDrawing.outline.applying(t), with: .color(PL.ground), style: style)
                    context.stroke(PitchDrawing.tactics.applying(t), with: .color(PL.ground), style: style)
                }
                VStack {
                    HStack {
                        Spacer()
                        Text("5 · 7 · 8 · 11").plLabel(13, tracking: 0.2)
                            .fixedSize().rotationEffect(.degrees(90)).frame(width: 20, height: 110)
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        Text("Match").plDisplay(88).lineLimit(1).minimumScaleFactor(0.6)
                        Spacer()
                        Text("→").plDisplay(22, .extraBold).foregroundStyle(PL.neon)
                            .frame(width: 44, height: 44).background(PL.ground, in: Circle())
                            .padding(.bottom, 10)
                    }
                }
                .padding(.leading, 24).padding(.trailing, 46).padding(.top, 24).padding(.bottom, 14)
            }
            .foregroundStyle(PL.ground)
            .frame(height: 290)
            .padding(.leading, -6).padding(.trailing, -34)
            .rotationEffect(.degrees(-3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Match, à 5, 7, 8 ou 11")
    }

    private var soloCard: some View {
        Button(action: onSolo) {
            ZStack(alignment: .bottomLeading) {
                PL.paper
                PixelPlayer().frame(width: 180, height: 129)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 12).padding(.leading, 8)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Toi + ton ballon").font(PL.font(15, .light))
                    Text("Solo").plDisplay(46)
                }
                .padding(.leading, 12).padding(.bottom, 12)
            }
            .foregroundStyle(PL.ground)
            .frame(height: 250).clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Solo : toi et ton ballon, le suivi démarre tout de suite")
    }

    private var libreCard: some View {
        Button(action: onLibre) {
            ZStack(alignment: .bottomLeading) {
                PL.ground
                TrackRings().frame(width: 150, height: 190)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: -34)
                Text("Libre").plDisplay(46).padding(.leading, 12).padding(.bottom, 10)
            }
            .foregroundStyle(PL.paper)
            .frame(height: 250).clipped()
            .overlay(Rectangle().strokeBorder(PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Libre : tes réglages avancés, sans préréglage")
    }

    private var buildPitchButton: some View {
        Button(action: onBuildPitch) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Construire le terrain").plDisplay(22, .extraBold, tracking: -0.01)
                    Text("Touche les deux cages, le terrain se dessine").font(PL.font(13, .light))
                }
                Spacer()
                Text("→").plDisplay(22, .extraBold).foregroundStyle(PL.ground)
                    .frame(width: 44, height: 44).background(PL.neon, in: Circle())
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .overlay(Capsule().strokeBorder(PL.neon, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Construire le terrain : touche les deux cages, le terrain se dessine sur l’image")
    }

    private func lastFilm(_ recording: MatchRecording) -> some View {
        Button(action: onRecordings) {
            VStack(spacing: 10) {
                Rectangle().fill(PL.paper).frame(height: 2)
                HStack {
                    Text(Self.describe(recording)).plLabel(12, tracking: 0.06).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text("→").plLabel(12, tracking: 0)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dernier film : \(Self.describe(recording)). Ouvre les films enregistrés")
    }

    static func describe(_ recording: MatchRecording) -> String {
        let date = recording.startedAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
            .uppercased().replacingOccurrences(of: ".", with: "")
        let seconds = Int(recording.durationSeconds)
        let duration = seconds < 60 ? "\(seconds) S" : "\(seconds / 60) MIN"
        var parts = ["DERNIER FILM —"]
        if let label = recording.sessionLabel { parts.append(label + " ·") }
        parts.append("\(date) · \(duration)")
        if recording.interrupted { parts.append("· INTERROMPU") }
        return parts.joined(separator: " ")
    }
}
