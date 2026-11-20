import SwiftUI

/// Full-screen camera with the existing overlays and the filming HUD.
/// This view does not observe the model: the preview layer does (analysis rate, as before),
/// the HUD observes AppStatus, which changes at most once per second while filming.
@MainActor
struct RecordingScreen: View {
    let model: DockKitModel
    @ObservedObject var status: AppStatus
    /// Match and Solo: start following as soon as the camera and the stand allow it.
    /// Recording never starts by itself: the user presses « Filmer ».
    let kickoff: Bool
    let onExit: () -> Void
    @State private var showSettings = false
    @State private var notice: String?
    @State private var kickoffTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                LivePreviewLayer(model: model, diagnosticTop: landscape ? 74 : 132)
                hud(landscape: landscape)
                    .padding(.horizontal, landscape ? 20 : 16)
                    .padding(.vertical, landscape ? 12 : 10)
            }
        }
        .statusBarHidden()
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { AdvancedSettingsView(model: model) }
        .onAppear { if kickoff { startKickoff() } }
        .onDisappear { kickoffTask?.cancel() }
    }

    private var recording: Bool { status.recordingState != .idle }
    private var calibrating: Bool { status.calibrationStep != .idle }
    /// Every session can build the pitch, when the user asks: from the two goals (camera on a
    /// touchline) or, for « une moitié », from its own goal then the far one (camera behind a goal).
    private var pitchBuildable: Bool { status.session != nil }
    private var behindGoal: Bool { status.session?.coverage == .half }

    // MARK: Layout

    @ViewBuilder
    private func hud(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if landscape {
                HStack(spacing: 12) {
                    if !recording { backButton }
                    recordCapsule
                    summaryCapsule
                    Spacer(minLength: 0)
                    DriverIndicator(driver: status.driver, following: status.following)
                }
            } else {
                HStack(spacing: 10) {
                    if !recording { backButton }
                    recordCapsule
                    Spacer(minLength: 0)
                    DriverIndicator(driver: status.driver, following: status.following)
                }
                summaryCapsule
            }
            if calibrating { calibrationCard.padding(.top, landscape ? 8 : 12) }
            if !calibrating, let text = notice ?? status.pitchNotice ?? (recording ? nil : status.recordingMessage.nilIfEmpty) {
                Text(text).font(PL.font(13, .light)).foregroundStyle(PL.paper)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(PL.ground.opacity(0.75), in: Capsule())
                    .padding(.top, landscape ? 40 : 56)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: landscape ? 16 : 12) {
                settingsButton
                if calibrating {
                    calibrationControls
                } else {
                    followButton
                    if pitchBuildable { calibrateButton }
                    if status.calibrated { removePitchButton }
                }
                Spacer(minLength: 0)
                if recording { stopButton.padding(.bottom, 10) }
                if status.recordingState == .recording { highlightButton(size: landscape ? 116 : 104) }
            }
        }
    }

    // MARK: Controls

    private var backButton: some View {
        Button(action: onExit) {
            Image(systemName: "arrow.left").font(.system(size: 18, weight: .bold))
                .foregroundStyle(PL.paper).frame(width: 44, height: 44)
                .background(PL.ground, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retour à l’accueil")
    }

    @ViewBuilder
    private var recordCapsule: some View {
        if recording {
            HStack(spacing: 10) {
                Circle().fill(PL.ground).frame(width: 28, height: 28)
                Text(Self.clock(status.elapsed)).plDisplay(22, tracking: -0.02).monospacedDigit()
            }
            .padding(.leading, 8).padding(.trailing, 18)
            .frame(height: 44)
            .foregroundStyle(PL.ground)
            .background(PL.orange, in: Capsule())
            .opacity(status.recordingState == .recording ? 1 : 0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.recordingState == .recording ? "Enregistrement : \(Self.clock(status.elapsed))" : "Enregistrement en préparation")
        } else {
            Button(action: startRecording) {
                HStack(spacing: 10) {
                    Circle().fill(PL.ground).frame(width: 28, height: 28)
                    Text("Filmer").plDisplay(22, tracking: -0.02)
                }
                .padding(.leading, 8).padding(.trailing, 18)
                .frame(height: 44)
                .foregroundStyle(PL.ground)
                .background(PL.orange, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filmer : enregistrer la vidéo avec les logs")
        }
    }

    @ViewBuilder
    private var summaryCapsule: some View {
        if let session = status.session {
            Text(session.summary).plLabel(12, tracking: 0.1).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(PL.paper)
                .padding(.horizontal, 16).frame(height: 44)
                .overlay(Capsule().strokeBorder(PL.paper, lineWidth: 2))
                .background(PL.ground.opacity(0.35), in: Capsule())
                .accessibilityLabel("Session : \(session.summary)")
        }
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape").font(.system(size: 18, weight: .medium))
                .foregroundStyle(PL.paper).frame(width: 44, height: 44)
                .background(PL.ground, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Réglages avancés")
    }

    private var followButton: some View {
        Button(action: toggleFollowing) {
            HStack(spacing: 8) {
                Image(systemName: status.following ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                Text(status.following ? "Pause" : "Suivre").plDisplay(15, .extraBold, tracking: -0.01)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .foregroundStyle(status.following ? PL.paper : PL.ground)
            .background(status.following ? PL.ground : PL.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.following ? "Mettre le suivi en pause" : "Reprendre le suivi")
    }

    private var stopButton: some View {
        Button {
            kickoffTask?.cancel()
            model.stopRecording()
            model.stop()
        } label: {
            Rectangle().fill(PL.orange).frame(width: 22, height: 22)
                .frame(width: 64, height: 64)
                .background(PL.ground, in: Circle())
                .overlay(Circle().strokeBorder(PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(status.recordingState == .stopping)
        .accessibilityLabel("Arrêter le film")
    }

    private func highlightButton(size: CGFloat) -> some View {
        Button { model.markHighlight() } label: {
            VStack(spacing: 4) {
                Text("À revoir").plDisplay(20)
                Text(Self.moments(status.highlights)).plLabel(12, tracking: 0.06)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 8)
            }
            .foregroundStyle(PL.ground)
            .frame(width: size, height: size)
            .background(PL.neon, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Marquer ce moment à revoir")
        .accessibilityValue(Self.moments(status.highlights).lowercased())
    }

    // MARK: Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.calibrationStep.instruction(behindGoal: behindGoal)).plDisplay(20, .extraBold, tracking: -0.01)
            if !status.calibrationMessage.isEmpty {
                Text(status.calibrationMessage).font(PL.font(13, .light)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(PL.paper)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(PL.ground.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(PL.neon, lineWidth: 2))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var calibrationControls: some View {
        if status.calibrationStep == .review {
            pillButton("Valider", filled: true) {
                model.acceptCalibration()
                if kickoff { startKickoff() }
            }
            pillButton("Recommencer", filled: false) { model.beginCalibration() }
        } else if status.connected {
            HStack(spacing: 6) {
                arrow("arrow.left", .left, "Tourner à gauche")
                VStack(spacing: 6) {
                    arrow("arrow.up", .up, "Monter")
                    arrow("arrow.down", .down, "Baisser")
                }
                arrow("arrow.right", .right, "Tourner à droite")
            }
        }
        pillButton("Passer", filled: false) {
            model.cancelCalibration()
            if kickoff && !status.following { startKickoff() }
        }
    }

    private var calibrateButton: some View {
        pillButton(status.calibrated ? "Refaire le terrain" : "Terrain", filled: false) {
            kickoffTask?.cancel()
            notice = nil
            model.beginCalibration()
        }
        .accessibilityHint(behindGoal ? "Touche le pied de ta cage puis de la cage d’en face pour situer le terrain"
                                      : "Touche le pied des deux cages pour situer le terrain")
    }

    private var removePitchButton: some View {
        Button {
            notice = nil
            model.removeCalibration()
        } label: {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                .foregroundStyle(PL.paper).frame(width: 44, height: 44)
                .background(PL.ground, in: Circle())
                .overlay(Circle().strokeBorder(PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effacer le terrain et suivre sans lui")
    }

    private func arrow(_ symbol: String, _ direction: DockKitModel.Direction, _ label: String) -> some View {
        Button { model.move(direction) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold))
                .foregroundStyle(PL.paper).frame(width: 44, height: 44)
                .background(PL.ground, in: Circle())
                .overlay(Circle().strokeBorder(PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pillButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).plDisplay(15, .extraBold, tracking: -0.01)
                .padding(.horizontal, 16).frame(height: 44)
                .foregroundStyle(filled ? PL.ground : PL.paper)
                .background(filled ? PL.neon : PL.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? PL.neon : PL.paper, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func startRecording() {
        notice = nil
        guard model.canRecord else { notice = "Caméra pas encore prête ; réessaie dans un instant."; return }
        model.startRecording()
    }

    private func toggleFollowing() {
        if status.following { model.stop(); return }
        if let blocker = model.requestFollowing() { notice = "Suivi impossible : " + blocker }
        else { notice = nil }
    }

    /// The preview may rotate the analysis when it appears, which stops following; start once it settled.
    /// The pitch is never built automatically: the user touches « Terrain » when they want it.
    private func startKickoff() {
        kickoffTask?.cancel()
        notice = "Préparation du coup d’envoi…"
        kickoffTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            for _ in 0..<100 {
                if model.isFollowing { notice = nil; return }
                if model.canFollow {
                    model.startFollowing()
                    if model.isFollowing { notice = nil; return }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            notice = "Suivi non démarré : " + (model.followStartBlocker ?? "touche Suivre")
        }
    }

    static func clock(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func moments(_ count: Int) -> String {
        count <= 1 ? "\(count) MOMENT" : "\(count) MOMENTS"
    }
}

/// Read-only: what currently steers the camera (hybrid decision, or the confirmed ball in ball mode).
private struct DriverIndicator: View {
    let driver: DockKitModel.CameraDriver
    let following: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Ballon", active: driver == .ball)
            segment("Joueurs", active: driver == .players)
        }
        .frame(height: 44)
        .overlay(Capsule().strokeBorder(PL.neon, lineWidth: 2))
        .clipShape(Capsule())
        .background(PL.ground.opacity(0.35), in: Capsule())
        .opacity(following ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func segment(_ title: String, active: Bool) -> some View {
        Text(title).plDisplay(14, .extraBold, tracking: -0.01)
            .padding(.horizontal, 16).frame(maxHeight: .infinity)
            .foregroundStyle(active ? PL.ground : PL.paper)
            .background(active ? PL.neon : Color.clear)
    }

    private var label: String {
        let source = switch driver {
        case .ball: "le ballon"
        case .players: "les joueurs"
        case .none: "rien pour l’instant"
        }
        return "Caméra guidée par \(source)" + (following ? "" : ", suivi en pause")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
