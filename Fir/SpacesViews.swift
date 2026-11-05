import SwiftUI
import MozillaAppServices

/// Safari-style group switcher: one glass capsule whose labels slide under the finger. The selection is a
/// tinted glass pill at the centre; while dragging it turns to clear glass that magnifies the labels
/// passing under it, as Safari's does. Letting go settles on the nearest label and selects it.
struct SpaceSwitcher: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let items: [Item]
    @Binding var selection: String
    /// The fractional item index under the capsule while switching, for the pages to follow; nil at rest.
    @Binding var scrub: CGFloat?
    /// Each label's width, measured.
    @State private var widths: [String: CGFloat] = [:]
    @State private var stripWidth: CGFloat = 0
    /// The strip position under the capsule's centre while dragging; nil when resting on `selection`.
    @State private var position: CGFloat?
    /// 1 while a finger holds the lens up, 0 at rest; animates both ways, so letting go eases it down.
    @State private var lift: CGFloat = 0
    @State private var dragStart: CGFloat?
    /// Where the current drag began; a different one means a new drag, whatever became of the last.
    @State private var dragOrigin: CGPoint?
    /// Down while a finger is on the strip; a drag the system cancels never reaches onEnded.
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { geo in
            let current = position.map(nearest) ?? selection
            strip(width: geo.size.width, current: current)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                // Under the lens only its bent copy shows; the plain labels would double it.
                .mask {
                    Rectangle().overlay {
                        if position != nil {
                            Capsule().frame(width: pillWidth * (1 + 0.08 * lift), height: 40 * (1 + 0.08 * lift)).blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
                .haptic(.selection, trigger: current)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                   .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .contentShape(.capsule)
        .gesture(drag)
        // Cancelled mid-drag: settle on whatever is under the lens rather than staying half-way.
        .onChange(of: touching) {
            guard !touching, dragStart != nil, let position else { return }
            dragStart = nil
            dragOrigin = nil
            settle(on: nearest(position), from: scrub)
        }
        .frame(height: 48)
        .glassEffect(.regular, in: .capsule)
        .overlay { lens }
    }

    /// The labels in a row, slid so `position` (or the selection) sits at the centre.
    /// `solid` draws plain colours: the lens shader can't capture the vibrant ones glass text uses.
    private func strip(width: CGFloat, current: String, solid: Bool = false) -> some View {
            HStack(spacing: Self.spacing) {
                ForEach(items) { item in
                    label(item, selected: item.id == current, solid: solid)
                        // At rest the pill draws the selected title itself, crisp on its tint.
                        .opacity(position == nil && item.id == selection ? 0 : 1)
                        // A size ignores offsets and effects; the lens copy's equal labels don't write.
                        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { w in
                            guard !solid, widths[item.id] != w else { return }
                            widths[item.id] = w
                        }
                }
            }
            .padding(.vertical, 4)
            .fixedSize()
            .offset(x: width / 2 - (position ?? centers[selection] ?? width / 2))
    }

    /// The selection pill, as wide as the label under it: a light pill with the title at rest; while
    /// dragging a lens over a copy of the labels, bent at its rim by a shader. Glass can't refract the labels
    /// itself: they are the bar's glass content, which other glass doesn't see on a device.
    private var lens: some View {
        LensBody(lift: lift, size: CGSize(width: pillWidth, height: 40),
                 title: items.first { $0.id == selection }?.title ?? "", showsCopy: position != nil) {
            strip(width: stripWidth, current: position.map(nearest) ?? selection, solid: true)
                .frame(width: stripWidth, height: 48, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    private var pillWidth: CGFloat {
        guard let position else { return widths[selection] ?? 100 }
        let f = fraction(position)
        let low = items[min(max(Int(f.rounded(.down)), 0), items.count - 1)].id
        let high = items[min(max(Int(f.rounded(.up)), 0), items.count - 1)].id
        let a = widths[low] ?? 100, b = widths[high] ?? 100
        return a + (b - a) * (f - f.rounded(.down))
    }

    private static let spacing: CGFloat = 4

    /// Each label's centre along the strip, from the widths. Centres measured in the strip's coordinate
    /// space moved with the drag, and with two writers (strip and lens copy) layout could loop forever.
    private var centers: [String: CGFloat] {
        var x: CGFloat = 0
        var result: [String: CGFloat] = [:]
        for item in items {
            guard let width = widths[item.id] else { break }
            result[item.id] = x + width / 2
            x += width + Self.spacing
        }
        return result
    }

    private func label(_ item: Item, selected: Bool, solid: Bool) -> some View {
        Text(item.title)
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .foregroundStyle(solid ? Color(selected ? .label : .secondaryLabel) : selected ? .primary : .secondary)
            .contentShape(.capsule)
            .onTapGesture { settle(on: item.id, from: index(of: selection)) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                // A new drag starts from where the strip is now, even mid-settle.
                if dragOrigin != value.startLocation {
                    dragOrigin = value.startLocation
                    dragStart = position ?? centers[selection] ?? 0
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { lift = 1 }
                }
                let start = dragStart ?? centers[selection] ?? 0
                position = clamped(start - value.translation.width)
                scrub = position.map(fraction)
            }
            .onEnded { value in
                let target = nearest(clamped((dragStart ?? 0) - value.predictedEndTranslation.width))
                dragStart = nil
                dragOrigin = nil
                settle(on: target, from: scrub)
            }
    }

    /// Slides labels and pages to `target` together, then makes it the selection in one still update.
    private func settle(on target: String, from start: CGFloat?) {
        if scrub == nil { scrub = start }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            lift = 0
            position = centers[target]
            scrub = index(of: target)
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                selection = target
                position = nil
                scrub = nil
            }
        }
    }

    private func index(of id: String) -> CGFloat {
        CGFloat(items.firstIndex { $0.id == id } ?? 0)
    }

    /// Where `x` falls between the labels' centres, as a fractional item index.
    private func fraction(_ x: CGFloat) -> CGFloat {
        let points = items.compactMap { centers[$0.id] }
        guard points.count == items.count, let first = points.first else { return index(of: selection) }
        if x <= first { return 0 }
        for i in 1..<points.count where x <= points[i] {
            return CGFloat(i - 1) + (x - points[i - 1]) / max(points[i] - points[i - 1], 1)
        }
        return CGFloat(points.count - 1)
    }

    private func clamped(_ x: CGFloat) -> CGFloat {
        let all = items.compactMap { centers[$0.id] }
        guard let low = all.min(), let high = all.max() else { return x }
        return min(max(x, low), high)
    }

    private func nearest(_ x: CGFloat) -> String {
        items.min { abs((centers[$0.id] ?? .infinity) - x) < abs((centers[$1.id] ?? .infinity) - x) }?.id ?? selection
    }
}

/// The switcher's pill, raised into a lens by `lift`. Animatable, so the shader's magnify and bend ease
/// with the scale; at 0 the copy matches the plain title, and swapping them shows no jump.
private struct LensBody<Copy: View>: View, Animatable {
    var lift: CGFloat
    let size: CGSize
    let title: String
    let showsCopy: Bool
    @ViewBuilder let copy: Copy

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    var body: some View {
        ZStack {
            if showsCopy {
                copy
                    // A margin around the capsule, so the bent rim has labels beyond it to draw from.
                    .frame(width: size.width + 32, height: 48)
                    .clipped()
                    .layerEffect(ShaderLibrary.glassLens(.float2(16, 4), .float2(size), .float(1 + 0.08 * lift),
                                                         .float(0.6 * lift)),
                                 maxSampleOffset: CGSize(width: 16, height: 16))
                    .frame(width: size.width, height: size.height)
                    .clipShape(.capsule)
                    .transition(.identity)
            } else {
                // No crossfade with the lens: both copies at once read as doubled text.
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(Color(.label))
                    .transition(.identity)
            }
        }
        .frame(width: size.width, height: size.height)
        // Drawn, not glass: glass over the bar's glass rendered with soft dark ends on the device, unlike
        // the simulator. A flat light fill and a lit rim match Safari's pill and lens.
        .background { Capsule().fill(Color(.label).opacity(0.14 - 0.09 * lift)) }
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            .opacity(lift)
        }
        .scaleEffect(1 + 0.08 * lift)
    }
}

/// One Zen workspace: title, essentials, then its pinned tabs and folders.
struct ZenSpacePage: View {
    let space: ZenWorkspaces.Space
    let essentials: [ZenWorkspaces.Tab]
    let onOpen: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Same title and spacing as ZenSpaceHeader, so switching to a space with tabs doesn't jump.
                VStack(alignment: .leading, spacing: 12) {
                    Text([space.icon, space.name].compactMap { $0 }.joined(separator: " "))
                        .font(.brandHeading(.title2))
                        .lineLimit(1)
                    if !essentials.isEmpty {
                        PinGrid(urls: essentials.map { ($0.id, $0.url) },
                                removeTitle: { _ in "Remove from Essentials" }, onOpen: onOpen)
                    }
                }
                if !space.tabs.isEmpty { section(title: nil, tabs: space.tabs) }
                ForEach(space.folders) { section(title: $0.name, tabs: $0.tabs) }
                if space.tabs.isEmpty && space.folders.allSatisfy(\.tabs.isEmpty) {
                    Text("No pinned tabs or folders in this space. Tabs you open here stay in it, on this iPhone only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) {
            // A wash of the space's theme colour, like Zen's own sidebar.
            LinearGradient(colors: [(space.color ?? .clear).opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    private func section(title: String?, tabs: [ZenWorkspaces.Tab]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label(title, systemImage: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(tabs) { tab in
                    Button { tab.url.map(onOpen) } label: {
                        HStack(spacing: 12) {
                            SiteIcon(host: tab.url?.host(), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? "Untitled" : tab.title).lineLimit(1)
                                if let host = tab.url?.host() {
                                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}

/// Another device's open tabs, most recently used first; a tap opens one here as a new tab.
struct RemoteTabsPage: View {
    let client: ClientRemoteTabs
    let onOpen: (URL) -> Void

    var body: some View {
        // Pinned tabs are Zen's workspace pins, already shown with their workspaces.
        let tabs = client.remoteTabs.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(NewTabView.shortName(client.clientName),
                      systemImage: client.deviceType == .mobile ? "smartphone" : "laptopcomputer")
                    .font(.brandHeading(.title2))
                    .lineLimit(1)
                if tabs.isEmpty {
                    Text("No open tabs on this device.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                            let url = tab.urlHistory.first.flatMap(URL.init(string:))
                            Button { url.map(onOpen) } label: {
                                HStack(spacing: 12) {
                                    SiteIcon(host: url?.host(), size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title.isEmpty ? "Untitled" : tab.title).lineLimit(1)
                                        if let host = url?.host() {
                                            Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(.rect)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }
}

/// Above a workspace's tab deck: its title and every pinned site as one row of icons.
struct ZenSpaceHeader: View {
    let space: ZenWorkspaces.Space
    let essentials: [ZenWorkspaces.Tab]
    let onOpen: (URL) -> Void
    @Environment(\.isLandscape) private var landscape

    var body: some View {
        // A folder's tabs are cards in the deck below.
        let pins = essentials + space.tabs
        VStack(alignment: .leading, spacing: 12) {
            Text([space.icon, space.name].compactMap { $0 }.joined(separator: " "))
                .font(.brandHeading(.title2))
                .lineLimit(1)
            // On its side the deck has no height to spare for the pins.
            if !pins.isEmpty, !landscape {
                PinGrid(urls: pins.map { ($0.id, $0.url) }, removeTitle: { id in
                    essentials.contains { $0.id == id } ? "Remove from Essentials" : "Unpin"
                }, pinnedIDs: Set(pins.dropFirst(essentials.count).map(\.id)), singleRow: true, onOpen: onOpen)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(colors: [(space.color ?? .clear).opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

/// The private deck before any private tab is open.
struct PrivateEmptyPage: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.largeTitle)
            Text("Private Browsing").font(.brandHeading(.title2))
            Text("Pages you open here aren't saved, and their cookies and site data are gone when you close the last private tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stands in for private tabs while they're locked: in the deck, and over a private page.
struct PrivateLockedPage: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.scenePhase) private var scenePhase
    /// Over a page there's no tab switcher to leave by; it gets its own way out.
    var offersLeave = false
    /// Off while it only slides past in the switcher, so Face ID doesn't come up uninvited.
    var asks = true

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Private Tabs Are Locked").font(.brandHeading(.title3))
            Button("Unlock") { Task { await browser.unlockPrivate() } }
                .buttonStyle(.glassProminent)
            if offersLeave {
                Button("Go to Tabs") { browser.leavePrivate() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Asks at once when shown, and again on coming back to Fir.
        .task(id: scenePhase) {
            if asks, scenePhase == .active { await browser.unlockPrivate() }
        }
    }
}
