import SwiftUI
import UIKit

/// Art direction: flat fills, capsule « track » shapes, Inter Tight, film grain. No gradients or shadows.
enum PL {
    static let ground = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)   // Darkest Hour
    static let paper = Color(red: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEB / 255)    // Cloud Dancer
    static let neon = Color(red: 0xDF / 255, green: 0xFF / 255, blue: 0x00 / 255)     // Sun Glare
    static let orange = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x26 / 255)   // Exuberant Orange
    static let violet = Color(red: 0x6A / 255, green: 0x5A / 255, blue: 0xCD / 255)   // Blue Violet

    enum Weight: CaseIterable {
        case light, medium, extraBold, black
        var postScriptName: String {
            switch self {
            case .light: "InterTight-Light"
            case .medium: "InterTight-Medium"
            case .extraBold: "InterTight-ExtraBold"
            case .black: "InterTight-Black"
            }
        }
        var system: Font.Weight {
            switch self {
            case .light: .light
            case .medium: .medium
            case .extraBold: .heavy
            case .black: .black
            }
        }
    }

    /// Checked once: the bundled fonts (UIAppFonts) must all resolve, otherwise the system font is used.
    static let customFontsAvailable: Bool = Weight.allCases.allSatisfy { UIFont(name: $0.postScriptName, size: 12) != nil }

    static func font(_ size: CGFloat, _ weight: Weight) -> Font {
        customFontsAvailable ? .custom(weight.postScriptName, fixedSize: size) : .system(size: size, weight: weight.system)
    }
}

extension View {
    /// Titles and numerals: heavy weight, tight tracking (≈ −0.03 em).
    func plDisplay(_ size: CGFloat, _ weight: PL.Weight = .black, tracking: CGFloat = -0.03) -> some View {
        font(PL.font(size, weight)).tracking(size * tracking)
    }
    /// Small uppercase labels: medium weight, wide tracking.
    func plLabel(_ size: CGFloat = 11, tracking: CGFloat = 0.14) -> some View {
        font(PL.font(size, .medium)).tracking(size * tracking)
    }
    func plGrain(opacity: Double = 0.18) -> some View {
        overlay(GrainOverlay(opacity: opacity))
    }
}

/// Static tiled noise, generated once: no live filter, so it costs nothing per frame beyond compositing.
struct GrainOverlay: View {
    var opacity = 0.35
    static let tile: UIImage = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        var state: UInt32 = 0x9E37_79B9
        func next() -> UInt32 { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state }
        for index in bytes.indices {
            // Mean of two uniforms: softer, mid-grey centred grain like fractal noise.
            bytes[index] = UInt8((Int(next() & 0xFF) + Int(next() & 0xFF)) / 2)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()

    var body: some View {
        Image(uiImage: Self.tile).resizable(resizingMode: .tile)
            .blendMode(.overlay).opacity(opacity)
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Minimal SVG path reader for the mock-up drawings (M L H V C Z, absolute and relative, circle arcs).
enum SVGPath {
    private enum Token { case command(Character), number(CGFloat) }

    private static func tokens(_ d: String) -> [Token] {
        var result: [Token] = []
        var buffer = ""
        func flush() { if let value = Double(buffer) { result.append(.number(CGFloat(value))) }; buffer = "" }
        for character in d {
            if character.isLetter && character != "e" { flush(); result.append(.command(character)) }
            else if character == "-" && !buffer.isEmpty && buffer.last != "e" { flush(); buffer.append(character) }
            else if character == "," || character == " " || character == "\n" { flush() }
            else { buffer.append(character) }
        }
        flush()
        return result
    }

    static func parse(_ d: String) -> Path {
        let items = tokens(d)
        var path = Path()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        func number() -> CGFloat {
            guard index < items.count, case .number(let value) = items[index] else { index += 1; return 0 }
            index += 1; return value
        }
        func point(_ relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        while index < items.count {
            if case .command(let next) = items[index] {
                index += 1
                command = next
                if next == "Z" || next == "z" { path.closeSubpath(); current = start; continue }
            }
            let relative = command.isLowercase
            switch command {
            case "M", "m":
                current = point(relative); start = current; path.move(to: current)
                command = relative ? "l" : "L"
            case "L", "l": current = point(relative); path.addLine(to: current)
            case "H", "h": let x = number(); current.x = relative ? current.x + x : x; path.addLine(to: current)
            case "V", "v": let y = number(); current.y = relative ? current.y + y : y; path.addLine(to: current)
            case "C", "c":
                let c1 = point(relative), c2 = point(relative), end = point(relative)
                path.addCurve(to: end, control1: c1, control2: c2); current = end
            case "A", "a":
                // Only the mock-ups' closed circles: start point at the top, centre one radius below.
                let rx = number(); _ = number(); _ = number(); _ = number(); _ = number()
                let end = point(relative)
                path.addEllipse(in: CGRect(x: current.x - rx, y: current.y, width: rx * 2, height: rx * 2))
                current = end; path.move(to: current)
            default: index += 1
            }
        }
        return path
    }

    /// Uniform « meet » fit of a view box into a rectangle, centred.
    static func fit(_ viewBox: CGRect, in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let x = rect.midX - viewBox.midX * scale, y = rect.midY - viewBox.midY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
    }
}

/// The hand-drawn pitch shared by the home slab and the match diagram (view box 300 × 172).
enum PitchDrawing {
    static let viewBox = CGRect(x: 0, y: 0, width: 300, height: 172)
    static let outline: Path = SVGPath.parse("""
        M8 12 C80 6 200 10 292 8 C296 60 290 120 294 162 C200 168 90 160 10 166 C4 110 12 60 8 12 Z \
        M150 9 C148 60 153 120 151 164 \
        M150 60 C172 58 182 84 170 104 C156 122 126 114 124 90 C122 72 134 60 150 60 \
        M9 52 C28 50 40 54 42 56 C44 80 40 110 43 122 C30 124 18 122 10 124 \
        M293 50 C276 52 262 50 258 54 C256 80 260 104 257 120 C270 122 284 120 294 122
        """)
    /// Tactics marks of the home slab: crosses, players, passes.
    static let tactics: Path = SVGPath.parse("""
        M66 40 l10 10 M76 40 l-10 10 M96 118 l10 10 M106 118 l-10 10 M214 132 l10 10 M224 132 l-10 10 \
        M112 62 a6 6 0 1 0 0.1 0 M206 46 a6 6 0 1 0 0.1 0 M232 96 a6 6 0 1 0 0.1 0 \
        M78 56 C100 62 118 74 134 88 M124 87 L135 89 L131 78 \
        M168 84 C182 66 194 58 204 56 M193 55 L205 55 L199 65
        """)
}

/// Pixel-art player with ball (view box −6 −2 28 20).
struct PixelPlayer: View {
    var color = PL.violet
    var ball = PL.violet
    static let viewBox = CGRect(x: -6, y: -2, width: 28, height: 20)
    static let body = SVGPath.parse("M6 0h2v2h-2zM5 2h4v1h-4zM4 3h6v1h-6zM3 4h2v1h-2zM6 4h3v1h-3zM10 4h2v1h-2zM2 5h2v1h-2zM6 5h3v1h-3zM11 5h2v1h-2zM1 6h1v1h-1zM6 6h3v3h-3zM13 6h1v1h-1zM9 8h1v1h-1zM5 9h2v1h-2zM8 9h3v1h-3zM4 10h2v1h-2zM9 10h3v1h-3zM3 11h2v1h-2zM10 11h4v1h-4zM2 12h2v1h-2zM12 12h3v1h-3zM1 13h2v1h-2zM14 13h1v1h-1zM0 14h2v1h-2z")
    static let ballPath = SVGPath.parse("M17 11h2v2h-2z")
    static let dust = SVGPath.parse("M-2 5h1v1h-1zM-4 7h1v1h-1zM-1 9h1v1h-1zM-5 10h1v1h-1zM-3 12h1v1h-1zM-2 14h1v1h-1zM-5 14h1v1h-1zM20 9h1v1h-1zM21 12h1v1h-1z")

    var body: some View {
        Canvas { context, size in
            let t = SVGPath.fit(Self.viewBox, in: CGRect(origin: .zero, size: size))
            context.fill(Self.body.applying(t), with: .color(color))
            context.fill(Self.ballPath.applying(t), with: .color(ball))
            context.fill(Self.dust.applying(t), with: .color(color.opacity(0.55)))
        }
        .accessibilityHidden(true)
    }
}

/// Three nested capsule strokes: orange, neon, violet.
struct TrackRings: View {
    var lineWidth: CGFloat = 14
    var body: some View {
        GeometryReader { geometry in
            let step = lineWidth * 1.3
            ZStack {
                Capsule().strokeBorder(PL.orange, lineWidth: lineWidth)
                Capsule().strokeBorder(PL.neon, lineWidth: lineWidth).padding(step)
                Capsule().strokeBorder(PL.violet, lineWidth: lineWidth).padding(step * 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Outlined numeral (the mock-ups' text stroke), drawn with eight offset copies under a ground fill.
struct OutlinedText: View {
    let text: String
    let size: CGFloat
    var stroke = PL.paper
    var fill = PL.ground
    var tracking: CGFloat = -0.03
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { step in
                let angle = Double(step) * .pi / 4
                Text(text).plDisplay(size, tracking: tracking).foregroundStyle(stroke)
                    .offset(x: cos(angle) * 1.3, y: sin(angle) * 1.3)
            }
            Text(text).plDisplay(size, tracking: tracking).foregroundStyle(fill)
        }
    }
}
