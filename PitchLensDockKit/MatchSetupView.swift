import SwiftUI

/// Match setup: format, coverage and city stade are remembered between matches and logged with
/// the recording; « Coup d'envoi » turns on the match preset and starts filming.
@MainActor
struct MatchSetupView: View {
    let onBack: () -> Void
    let onKickoff: (SessionSetup) -> Void
    @AppStorage("pitchlens.matchFormat") private var format = 7
    @AppStorage("pitchlens.matchCoverage") private var coverageRaw = SessionSetup.Coverage.full.rawValue
    @AppStorage("pitchlens.cityStade") private var cityStade = false

    private var coverage: SessionSetup.Coverage { SessionSetup.Coverage(rawValue: coverageRaw) ?? .full }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Text("← RETOUR").plLabel(11, tracking: 0.1).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retour à l’accueil")
                    Spacer()
                    Text("PL—02").plLabel(11, tracking: 0.1)
                }
                Text("Match").plDisplay(104, tracking: -0.04).foregroundStyle(PL.neon)
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.leading, -4)
                    .accessibilityAddTraits(.isHeader)

                Text("01 — COMBIEN PAR ÉQUIPE").plLabel().padding(.top, 18)
                formatPicker.padding(.top, 6)

                Text("02 — CE QUE LA CAMÉRA COUVRE").plLabel().padding(.top, 20)
                CoverageDiagram(coverage: coverage).frame(height: 190).padding(.top, 8)
                coverageButtons

                cityRow.padding(.top, 18)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            kickoffButton.padding(.horizontal, 16).padding(.bottom, 10).frame(maxWidth: 430)
        }
        .background(PL.ground.ignoresSafeArea())
        .foregroundStyle(PL.paper)
        .plGrain()
    }

    private var formatPicker: some View {
        HStack(alignment: .center) {
            ForEach([5, 7, 8, 11], id: \.self) { value in
                if value != 5 { Spacer(minLength: 0) }
                Button { format = value } label: {
                    Group {
                        if format == value {
                            Text("\(value)").plDisplay(88, tracking: value == 11 ? -0.06 : -0.03)
                                .foregroundStyle(PL.ground)
                                .frame(minWidth: 86).padding(.horizontal, value == 11 ? 10 : 0)
                                .frame(height: 112)
                                .background(PL.neon, in: Capsule())
                        } else {
                            OutlinedText(text: "\(value)", size: 88, tracking: value == 11 ? -0.06 : -0.03)
                                .frame(minWidth: 70).frame(height: 104)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) contre \(value)")
                .accessibilityAddTraits(format == value ? .isSelected : [])
            }
        }
        .frame(height: 112)
    }

    private var coverageButtons: some View {
        HStack(spacing: 0) {
            coverageButton(.full, "Tout le terrain", PL.violet,
                hint: "Caméra au bord, au milieu du terrain")
            coverageButton(.half, "Une moitié", PL.orange,
                hint: "Caméra derrière un but")
        }
        .overlay(Rectangle().strokeBorder(PL.paper, lineWidth: 2).padding(.top, -2))
    }

    private func coverageButton(_ value: SessionSetup.Coverage, _ title: String, _ dot: Color, hint: String) -> some View {
        let selected = coverage == value
        return Button { coverageRaw = value.rawValue } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 12, height: 12)
                Text(title).plDisplay(15, .extraBold, tracking: -0.01)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? PL.ground : PL.paper)
            .background(selected ? PL.paper : PL.ground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cityRow: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("03 — CITY STADE").plLabel()
                    Text("Petit terrain fermé").font(PL.font(13, .light))
                }
                Spacer()
                Button { cityStade.toggle() } label: {
                    ZStack(alignment: cityStade ? .trailing : .leading) {
                        Capsule().fill(cityStade ? PL.neon : PL.ground)
                        Capsule().strokeBorder(cityStade ? PL.neon : PL.paper, lineWidth: 2)
                        Circle().fill(cityStade ? PL.ground : PL.paper).frame(width: 26, height: 26).padding(.horizontal, 7)
                    }
                    .frame(width: 76, height: 40)
                    .frame(minHeight: 44)
                    .animation(.easeOut(duration: 0.15), value: cityStade)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("City stade")
                .accessibilityValue(cityStade ? "activé" : "désactivé")
                .accessibilityAddTraits(.isToggle)
            }
            .frame(minHeight: 48)
            Rectangle().fill(PL.paper).frame(height: 2)
        }
    }

    private var kickoffButton: some View {
        Button {
            onKickoff(.match(format: format, coverage: coverage, cityStade: cityStade))
        } label: {
            HStack {
                Text("Coup d’envoi").plDisplay(30)
                Spacer()
                Circle().fill(PL.ground).overlay(Circle().strokeBorder(PL.neon, lineWidth: 6))
                    .frame(width: 60, height: 60)
            }
            .foregroundStyle(PL.ground)
            .padding(.leading, 30).padding(.trailing, 12)
            .frame(height: 84)
            .background(PL.orange, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Démarre le film et le suivi")
    }
}

/// The hand-drawn pitch with both camera placements; only the chosen one is highlighted.
struct CoverageDiagram: View {
    let coverage: SessionSetup.Coverage

    var body: some View {
        Canvas { context, size in
            let full = coverage == .full
            // Pitch area leaves room for the camera dot behind the right goal.
            let t = SVGPath.fit(PitchDrawing.viewBox, in: CGRect(x: 10, y: 8, width: size.width - 42, height: size.height - 22))
            let s = t.a
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PL.paper))
            // Covered area in neon.
            let left = full ? 0 : point(150, 0).x
            context.fill(Path(CGRect(x: left, y: 0, width: size.width - left, height: size.height)), with: .color(PL.neon))
            context.stroke(PitchDrawing.outline.applying(t), with: .color(PL.ground),
                style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round))
            let dotted = StrokeStyle(lineWidth: 6 * s, lineCap: .round, dash: [0.1 * s, 13 * s])
            // Touchline camera at halfway (violet) and behind-the-goal camera (orange).
            var violetCone = Path(); violetCone.move(to: point(150, 170)); violetCone.addLine(to: point(92, 30))
            violetCone.addLine(to: point(208, 30)); violetCone.closeSubpath()
            var violetRays = Path(); violetRays.move(to: point(150, 170)); violetRays.addLine(to: point(92, 30))
            violetRays.move(to: point(150, 170)); violetRays.addLine(to: point(208, 30))
            var orangeCone = Path(); orangeCone.move(to: point(298, 86)); orangeCone.addLine(to: point(176, 44))
            orangeCone.addLine(to: point(176, 128)); orangeCone.closeSubpath()
            var orangeRays = Path(); orangeRays.move(to: point(298, 86)); orangeRays.addLine(to: point(176, 44))
            orangeRays.move(to: point(298, 86)); orangeRays.addLine(to: point(176, 128))
            if full { context.fill(violetCone, with: .color(PL.violet.opacity(0.16))) }
            else { context.fill(orangeCone, with: .color(PL.orange.opacity(0.16))) }
            context.stroke(violetRays, with: .color(PL.violet.opacity(full ? 0.9 : 0.3)), style: dotted)
            context.stroke(orangeRays, with: .color(PL.orange.opacity(full ? 0.3 : 0.9)), style: dotted)
            let orangeCenter = CGPoint(x: min(size.width - 12, point(310, 86).x), y: point(310, 86).y)
            context.fill(Path(ellipseIn: CGRect(x: orangeCenter.x - 11, y: orangeCenter.y - 11, width: 22, height: 22)),
                with: .color(PL.orange.opacity(full ? 0.35 : 1)))
            let violetCenter = CGPoint(x: point(150, 0).x, y: size.height - 11)
            context.fill(Path(ellipseIn: CGRect(x: violetCenter.x - 11, y: violetCenter.y - 11, width: 22, height: 22)),
                with: .color(PL.violet.opacity(full ? 1 : 0.35)))
        }
        .accessibilityElement()
        .accessibilityLabel(coverage == .full
            ? "Schéma : caméra au bord du terrain, au milieu, qui couvre tout le terrain"
            : "Schéma : caméra derrière le but, qui couvre une moitié du terrain")
    }
}
