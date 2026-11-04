import SwiftUI

/// The brand's palette: conifer greens and glacier teal on snow. The greens lift a step in dark mode,
/// or they sink into black.
enum Palette {
    static let snow = Color(hex: 0xF4F6F3)
    /// Behind the mark, as on the icon: snow in light mode, and the system's dark icon grey in dark.
    static let field = Color(light: 0xF4F6F3, dark: 0x1C1C1E)
    static let pine = Color(light: 0x2F7D63, dark: 0x4FA383)
    static let teal = Color(light: 0x2E8C96, dark: 0x5CC2C0)
    static let stem = Color(light: 0x1F5C4A, dark: 0x2E7A62)
    /// The reader's page colours.
    static let ink = Color(hex: 0x1A1C1B)
    static let paper = Color(hex: 0xF5F3EA)
}

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(light: Int, dark: Int) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

extension Font {
    /// The heading face, Bricolage Grotesque, at a text style's default size; `relativeTo` scales it
    /// with Dynamic Type. It has no Cyrillic: Russian names fall back to the system font.
    static func brandHeading(_ style: TextStyle) -> Font {
        let size: CGFloat = switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        default: 17
        }
        return .custom("Bricolage Grotesque", size: size, relativeTo: style).weight(.semibold)
    }
}

/// The app icon's mark: a conifer sprig, two rows of needles along a bowed twig. Drawn on a 1024 pt
/// square; kept in step with scripts/render-icon.swift.
struct SprigMark: View {
    var left = Palette.pine
    var right = Palette.teal
    var stem = Palette.stem

    var body: some View {
        Canvas { context, size in
            // Fitted to the sprig itself: the icon's margins around it would shrink it in a tile.
            let parts = [Sprig.needles(side: -1), Sprig.needles(side: 1), Sprig.stem()]
            let bounds = parts.dropFirst().reduce(parts[0].boundingRect) { $0.union($1.boundingRect) }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            for (part, colour) in zip(parts, [left, right, stem]) { context.fill(part, with: .color(colour)) }
        }
    }
}

/// The sprig's geometry on a 1024 pt square.
enum Sprig {
    static let from = CGPoint(x: 260, y: 780), to = CGPoint(x: 760, y: 300)
    static let bow: CGFloat = 90, count = 12, needle: CGFloat = 150, angle = 52.0, thickness: CGFloat = 20

    static func point(_ t: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, length = (dx * dx + dy * dy).squareRoot()
        let control = CGPoint(x: (from.x + to.x) / 2 - dy / length * bow, y: (from.y + to.y) / 2 + dx / length * bow)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }

    static func stem() -> Path {
        var path = Path()
        path.move(to: point(0))
        for i in 1...40 { path.addLine(to: point(CGFloat(i) / 40)) }
        return path.strokedPath(StrokeStyle(lineWidth: thickness * 0.9, lineCap: .round, lineJoin: .round))
    }

    /// One row of needles; `side` is -1 or 1. The rows alternate, and the needles shorten near the tip.
    static func needles(side: CGFloat) -> Path {
        var path = Path()
        for i in 0..<count {
            let t = 0.08 + 0.9 * (CGFloat(i) + (side > 0 ? 0.5 : 0)) / CGFloat(count)
            let a = point(t), b = point(min(t + 0.01, 1))
            let dx = b.x - a.x, dy = b.y - a.y, length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
            let r = angle * .pi / 180 * Double(side)
            let ux = dx / length * cos(r) - dy / length * sin(r), uy = dx / length * sin(r) + dy / length * cos(r)
            let n = needle * (t > 0.75 ? max(0.35, (1 - t) / 0.25) : 1)
            path.move(to: a)
            path.addLine(to: CGPoint(x: a.x + ux * n, y: a.y + uy * n))
        }
        return path.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
    }
}
