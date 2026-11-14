import SwiftUI

// Onboarding illustrations, drawn by hand: no system component exists for them. Animations last under
// a second or loop in the background; nothing waits for one to finish.

/// A slowly moving mesh in the page's colours, crossfading as the pages change.
struct OnboardingBackground: View {
    let page: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tints: [(Color, Color)] = [
        (Palette.pine, Palette.teal),
        (Palette.teal, Color(light: 0x3E73B8, dark: 0x5B8FD6)),
        (Palette.pine, Color(light: 0x7FA34E, dark: 0x93BD5E)),
        (Palette.teal, Color(light: 0x7A62C9, dark: 0x9A84E6)),
        (Palette.teal, Palette.pine),
        (Palette.pine, Color(light: 0xB8914A, dark: 0xCFA866)),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground)
            ForEach(Self.tints.indices, id: \.self) { index in
                // Only the page in front and its neighbours exist, so at most three meshes draw.
                if abs(index - page) <= 1 {
                    mesh(Self.tints[index]).opacity(index == page ? 1 : 0)
                }
            }
        }
        .animation(.smooth(duration: 0.6), value: page)
        .ignoresSafeArea()
    }

    private func mesh(_ tint: (Color, Color)) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let s = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [Float(0.5 + 0.15 * sin(s * 0.35)), 0], [1, 0],
                [0, Float(0.4 + 0.08 * cos(s * 0.3))],
                [Float(0.5 + 0.12 * cos(s * 0.4)), Float(0.42 + 0.08 * sin(s * 0.45))],
                [1, Float(0.4 + 0.08 * sin(s * 0.3))],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                tint.0.opacity(0.55), tint.1.opacity(0.45), tint.0.opacity(0.4),
                tint.1.opacity(0.2), tint.0.opacity(0.12), tint.1.opacity(0.2),
                .clear, .clear, .clear,
            ])
        }
    }
}

/// The page width, so art can move against its page as it is swiped.
private struct PageWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var onboardingPageWidth: CGFloat {
        get { self[PageWidthKey.self] }
        set { self[PageWidthKey.self] = newValue }
    }
}

/// Art runs ahead of its page by a third, out past the screen edge. Trailing pushed it into the neighbour,
/// and clipping that left a hard cut through the picture.
struct Parallax: ViewModifier {
    @Environment(\.onboardingPageWidth) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.visualEffect { [width, reduceMotion] content, proxy in
            let shift = width > 0 && !reduceMotion ? proxy.frame(in: .global).midX - width / 2 : 0
            return content.offset(x: shift * 0.3)
        }
    }
}

/// The sprig drawn from its stem out, needle by needle, in about 0.7 s.
/// A tap sends a ripple from the stem to the tip and sways the sprig.
struct GrowingSprig: View {
    @State private var progress: Double = 0
    @State private var ripple: Double = 0
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SprigDrawing(progress: progress, ripple: ripple)
            .keyframeAnimator(initialValue: Sway(), trigger: taps) { content, sway in
                content.rotationEffect(.degrees(sway.angle)).scaleEffect(sway.scale)
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    SpringKeyframe(-7, duration: 0.15)
                    SpringKeyframe(4, duration: 0.2)
                    SpringKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.08, duration: 0.15)
                    SpringKeyframe(1, duration: 0.45)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                taps += 1
                // Each tap runs the ripple over one whole number; the drawing uses the fraction.
                if !reduceMotion { withAnimation(.easeOut(duration: 0.6)) { ripple = ripple.rounded(.up) + 1 } }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .accessibilityHidden(true)
            .onAppear {
                guard progress == 0 else { return }
                if reduceMotion { progress = 1 } else { withAnimation(.easeOut(duration: 0.7)) { progress = 1 } }
            }
    }

    private struct Sway {
        var angle = 0.0
        var scale = 1.0
    }
}

private struct SprigDrawing: View, Animatable {
    var progress: Double
    var ripple: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, ripple) }
        set { (progress, ripple) = (newValue.first, newValue.second) }
    }

    private static let bounds: CGRect = {
        let parts = [Sprig.needles(side: -1), Sprig.needles(side: 1), Sprig.stem()]
        return parts.dropFirst().reduce(parts[0].boundingRect) { $0.union($1.boundingRect) }
    }()

    var body: some View {
        Canvas { context, size in
            let bounds = Self.bounds
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)

            // The stem leads; each needle grows out once the stem has passed it.
            let reach = CGFloat(progress) * 1.2
            guard reach > 0 else { return }
            var stem = Path()
            stem.move(to: Sprig.point(0))
            for step in 1...40 {
                let t = min(CGFloat(step) / 40, reach)
                stem.addLine(to: Sprig.point(min(t, 1)))
                if t >= reach { break }
            }
            for (side, colour) in [(CGFloat(-1), Palette.pine), (1, Palette.teal)] {
                for index in 0..<Sprig.count {
                    let start = Sprig.needle(index, side: side).t
                    // The ripple swells each needle by up to a fifth as it passes.
                    let wave = (ripple - ripple.rounded(.down)) * 1.4 - Double(start)
                    let swell = wave > 0 && wave < 0.4 ? 1 + 0.2 * sin(wave / 0.4 * .pi) : 1
                    let grown = min(max((reach - start) / 0.2, 0), 1) * CGFloat(swell)
                    guard grown > 0 else { continue }
                    context.stroke(Sprig.needle(index, side: side, grown: grown).line, with: .color(colour),
                                   style: StrokeStyle(lineWidth: Sprig.thickness, lineCap: .round))
                }
            }
            // On top, as in SprigMark.
            context.stroke(stem, with: .color(Palette.stem),
                           style: StrokeStyle(lineWidth: Sprig.thickness * 0.9, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The sprig with kinds of sites circling it and Zen-style workspaces floating over the ring.
struct SyncOrbit: View {
    private static let sites: [(symbol: String, colour: Color)] = [
        ("book.fill", .orange), ("briefcase.fill", .blue), ("music.note", .pink), ("cart.fill", .green),
        ("newspaper.fill", .gray), ("play.rectangle.fill", .red), ("map.fill", .teal), ("fork.knife", .yellow),
    ]
    private static let chips: [(title: LocalizedStringKey, symbol: String, x: CGFloat, y: CGFloat, tilt: Double)] = [
        ("Work", "briefcase", -84, -96, -7),
        ("Reading", "book", 92, -30, 6),
        ("Essentials", "star", -60, 98, 4),
    ]
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            // A full turn a minute: movement you notice, not watch.
            let turn = time.truncatingRemainder(dividingBy: 60) / 60 * 2 * .pi
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 1).frame(width: 190, height: 190)
                Circle().stroke(.secondary.opacity(0.15), lineWidth: 1).frame(width: 128, height: 128)
                SprigMark()
                    .frame(width: 46, height: 46)
                    .padding(12)
                    .background(Palette.field, in: .rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                ForEach(Self.sites.indices, id: \.self) { index in
                    let angle = turn + Double(index) / Double(Self.sites.count) * 2 * .pi
                    let site = Self.sites[index]
                    Image(systemName: site.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(site.colour.gradient, in: .rect(cornerRadius: 11, style: .continuous))
                        .scaleEffect(appeared ? 1 : 0.4)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(duration: 0.45, bounce: 0.35).delay(Double(index) * 0.03), value: appeared)
                        .offset(x: cos(angle) * 95, y: sin(angle) * 95)
                }
                ForEach(Self.chips.indices, id: \.self) { index in
                    let chip = Self.chips[index]
                    Label(chip.title, systemImage: chip.symbol)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: .capsule)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .rotationEffect(.degrees(chip.tilt))
                        .offset(x: chip.x, y: chip.y + 4 * sin(time * 1.1 + Double(index) * 2))
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(0.2), value: appeared)
                }
            }
        }
        .frame(height: 220)
        .onAppear { appeared = true }
    }
}

/// A small phone to try the tab gestures on. Left alone, it plays them itself with a finger dot.
struct GestureDemo: View {
    private static let width: CGFloat = 156, height: CGFloat = 312
    private static let pages: [(colour: Color, symbol: String)] = [
        (Palette.pine, "leaf.fill"), (Palette.teal, "drop.fill"), (Color(light: 0xB8914A, dark: 0xCFA866), "sun.max.fill"),
    ]
    @State private var index = 0
    @State private var deck = false
    @State private var drag = CGSize.zero
    @State private var finger: CGPoint?
    @State private var touched = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ZStack {
            Color(.secondarySystemBackground)
            ForEach(Self.pages.indices, id: \.self) { page in
                card(page)
                    .scaleEffect(deck ? 0.62 : 1)
                    .offset(x: CGFloat(page - index) * (deck ? Self.width * 0.68 : Self.width + 8) + drag.width,
                            y: deck ? -18 : 0)
                    .onTapGesture { if deck { touch(); withAnimation(.smooth(duration: 0.35)) { index = page; deck = false } } }
            }
            bar
            if let finger {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .position(finger)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(shape)
        .overlay(shape.stroke(.secondary.opacity(0.4), lineWidth: 1.5))
        .contentShape(shape)
        .highPriorityGesture(swipe)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A demo of the tab gestures")
        .task(id: touched) { if !touched && !reduceMotion { await autoplay() } }
    }

    private func card(_ page: Int) -> some View {
        let tint = Self.pages[page]
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: tint.symbol).font(.title2).foregroundStyle(.white)
            ForEach(0..<5, id: \.self) { line in
                Capsule().fill(.white.opacity(0.55)).frame(width: line == 4 ? 60 : nil, height: 7)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .padding(.top, 18)
        .frame(width: Self.width, height: Self.height)
        .background(tint.colour.gradient)
        .clipShape(.rect(cornerRadius: deck ? 26 : 0, style: .continuous))
    }

    private var bar: some View {
        VStack {
            Spacer()
            Group {
                if deck {
                    Text("\(Self.pages.count) Tabs").font(.caption.weight(.semibold))
                } else {
                    Capsule().fill(.primary.opacity(0.35)).frame(width: 60, height: 6)
                }
            }
            .frame(width: Self.width - 28, height: 30)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 12)
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                touch()
                let t = value.translation
                if abs(t.width) > abs(t.height) { drag = CGSize(width: t.width, height: 0) }
            }
            .onEnded { value in
                let t = value.predictedEndTranslation
                withAnimation(.smooth(duration: 0.35)) {
                    drag = .zero
                    if !deck, t.height < -60, abs(t.height) > abs(t.width) {
                        deck = true
                    } else if deck, t.height > 60, abs(t.height) > abs(t.width) {
                        deck = false
                    } else if t.width < -50 {
                        index = min(index + 1, Self.pages.count - 1)
                    } else if t.width > 50 {
                        index = max(index - 1, 0)
                    }
                }
            }
    }

    /// The user took over: the demo stops for good.
    private func touch() {
        guard !touched else { return }
        touched = true
        finger = nil
    }

    /// Swipes across all tabs, up to the deck, a tap on the card in front; the next round swipes back.
    private func autoplay() async {
        let barY = Self.height - 27
        func pause(_ seconds: Double) async -> Bool {
            try? await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled && !touched
        }
        func slide(from: CGPoint, to: CGPoint, change: @escaping () -> Void) async -> Bool {
            withAnimation(.easeOut(duration: 0.15)) { finger = from }
            guard await pause(0.2) else { return false }
            withAnimation(.smooth(duration: 0.4)) { finger = to; change() }
            guard await pause(0.45) else { return false }
            withAnimation(.easeOut(duration: 0.15)) { finger = nil }
            return true
        }
        while !Task.isCancelled && !touched {
            guard await pause(1.2) else { return }
            let step = index == 0 ? 1 : -1
            let left = CGPoint(x: Self.width * 0.25, y: barY), right = CGPoint(x: Self.width * 0.75, y: barY)
            for _ in 1..<Self.pages.count {
                guard await slide(from: step > 0 ? right : left, to: step > 0 ? left : right,
                                  change: { index += step }) else { return }
                guard await pause(0.8) else { return }
            }
            guard await slide(from: CGPoint(x: Self.width / 2, y: barY), to: CGPoint(x: Self.width / 2, y: Self.height * 0.5),
                              change: { deck = true }) else { return }
            guard await pause(1.0) else { return }
            let card = CGPoint(x: Self.width / 2, y: Self.height / 2 - 18)
            guard await slide(from: card, to: card, change: { deck = false }) else { return }
        }
    }
}
