import SwiftUI
import WebKit
import Translation

/// Root: the tab deck with the selected page layered over it. As in Safari, the live web view never
/// moves: transitions (to and from the deck, swiping between tabs) animate a snapshot of the page
/// while the web view stays put, hidden. Transforming the live view made WebKit re-lay out fixed
/// elements mid-animation and jump when it settled.
struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AccountService.self) private var account
    @State private var pageShown = true
    /// Shrink toward the card: 0 = full screen, 1 = card size and crop.
    @State private var progress: CGFloat = 0
    /// Translation applied after scaling; follows the finger, then carries the page onto its card.
    @State private var follow: CGSize = .zero
    /// Global point the page scales about: where the finger grabbed it, or the screen's centre.
    @State private var anchor: CGPoint?
    /// The card a new tab grows from, held for the whole transition: its own card is placed only later.
    @State private var heldCard: CGRect?
    /// Counts requests to close PageView's sheets, which only it can reach.
    @State private var sheetsDismissed = 0
    /// Tracked here, not in the login capsule: it appears after the keyboard's notification has passed.
    @State private var keyboardShown = false
    /// Landscape layout, kept here for what is drawn outside the content.
    @State private var barOnTop = false
    /// Horizontal travel of a bar swipe between tabs.
    @State private var swipeX: CGFloat = 0
    /// The snapshot standing in for the live page during a transition; nil shows the live page.
    @State private var cover: UIImage?
    /// The live page frozen at the start of a transition; preferred over `cover` while set.
    @State private var coverView: UIView?
    /// A tab's saved snapshot left over its page until the page has loaded, then faded out.
    @State private var veil: UIImage?
    /// Whether a transition is running; the live page is hidden then, even without a snapshot.
    @State private var transitioning = false
    /// Where the lifted tab stood before moving to the end of the deck.
    @State private var liftOrigin: Int?
    /// The tab a committed swipe is sliding in, until it is in front.
    @State private var landing: BrowserTab?
    @State private var screen: CGRect = .zero
    @State private var cardFrames: [BrowserTab.ID: CGRect] = [:]
    /// The deck's settings sheet, and whether it opens on Workspaces.
    @State private var settings: SettingsSheet?
    @State private var showDownloads = false
    @State private var search: NewTabView.Mode?
    /// Where sheets grow out of: the bar's menu button and address capsule.
    @Namespace private var sheetSource
    /// A swipe past the last tab slid the new-tab page in; it slides back if the search is cancelled.
    @State private var swipedToNewTab = false
    /// A lift toward the deck is under way; the tab moves to the deck's end once per lift.
    @State private var lifting = false
    /// A page is growing out of its card in the deck.
    @State private var opening = false
    /// Bumped when a transition starts. An older one's completion or delayed step then stands aside:
    /// a card tapped while the page still shrank opened, and the close's completion hid it again.
    @State private var transitionID = 0
    /// A released swipe is carrying the neighbour in: its capsule opens while it arrives.
    @State private var arriving = false
    /// Counts bar swipes that switched tabs, for their haptic tick.
    @State private var swipeCommits = 0
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false
    @State private var onboardingRequested = false
    @AppStorage(SettingsKey.newTabStyle) private var newTabStyle = NewTabStyle.sheet
    @State private var showWhatsNew = WhatsNew.isDue
    /// Stays true until the sheet is fully gone: another one asked for while it leaves would be lost.
    @State private var whatsNewPending = WhatsNew.isDue

    /// A tab without a page is on screen, nothing over it: search opens, as there is nothing else to do.
    /// Not while Undo is offered, which the sheet would cover.
    private var blankShown: Bool {
        pageShown && !transitioning && browser.selected.url == nil && browser.undo == nil && onboardingDone && !whatsNewPending
            && newTabStyle == .sheet
    }

    // Safari's curve: a quick start and a soft settle, full screen in about 0.2 s on a 2026 recording.
    // A fixed-duration ease felt even-paced.
    private let settle = Animation.spring(response: 0.34, dampingFraction: 0.88)
    private let swipeCommit = Animation.spring(response: 0.32, dampingFraction: 0.92)
    static let swipeGap: CGFloat = 10
    /// The bottom bar's height and a gap.
    private static let barClearance: CGFloat = 56

    /// A camera column down one side only, as on both of the iPhone Duo's screens: Apple lays bars out
    /// beside it, so the buttons move there. A notched iPhone on its side has both sides inset.
    static func sideRail(_ insets: EdgeInsets) -> Bool {
        insets.trailing >= 40 && insets.leading < 20
    }

    var body: some View {
        // Read outside the ignored safe area: inside it the insets come back as zero. Without the
        // keyboard, which would lift the bar and resize the page while the find bar is open.
        GeometryReader { geo in
            content(safeInsets: geo.safeAreaInsets)
        }
        .ignoresSafeArea(.keyboard)
        // Outside the keyboard-ignoring area, so it sits on top of the keyboard.
        .overlay(alignment: .bottom) {
            // Only over its page: on the deck it covered the switcher.
            if pageShown, !transitioning, !(browser.selected.isPrivate && browser.privateLocked) {
                PasswordFillBar(autofill: .shared, webView: browser.selected.webView)
                    // A focused field doesn't always raise the keyboard, and then the capsule sat on the bar.
                    .padding(.bottom, keyboardShown || barOnTop ? 0 : Self.barClearance)
                    .animation(.snappy, value: PasswordAutofill.shared.offer?.host)
                    .animation(.snappy, value: keyboardShown)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .alert(savePromptTitle, isPresented: Binding(
            get: { PasswordAutofill.shared.savePrompt != nil },
            set: { if !$0 { PasswordAutofill.shared.savePrompt = nil } }
        ), presenting: PasswordAutofill.shared.savePrompt) { prompt in
            Button(prompt.existing == nil ? "Save" : "Update") {
                Task {
                    await PasswordAutofill.shared.save(prompt)
                    await account.sync()
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: { prompt in
            let sync = account.isSignedIn ? " It syncs to Zen." : ""
            Text(prompt.username.isEmpty ? "For this site.\(sync)" : "For \(prompt.username).\(sync)")
        }
        .sheet(isPresented: $showDownloads) { NavigationStack { DownloadsView() } }
        .haptic(.selection, trigger: swipeCommits)
    }

    private var savePromptTitle: String {
        guard let prompt = PasswordAutofill.shared.savePrompt else { return "" }
        let host = PasswordStore.host(prompt.origin)
        return prompt.existing == nil ? "Save password for \(host)?" : "Update password for \(host)?"
    }

    private func content(safeInsets: EdgeInsets) -> some View {
        ZStack {
            TabSwitcherView(
                hiddenTab: pageShown ? browser.selectedID : nil,
                onCardFrame: { cardFrames[$0] = $1 },
                onOpen: openPage,
                onNewTab: startNewTab,
                onSettings: { settings = .main },
                onEditWorkspaces: { settings = .workspaces },
                railWidth: Self.sideRail(safeInsets) ? safeInsets.trailing : 0,
                holdsPosition: opening
            )
            .equatable()
            // While a page grows or settles it takes no touches, and they fell through to the card under it.
            .allowsHitTesting(!pageShown || progress > 0)
            // The root ignores the safe area for the page; the deck's bars still need it.
            .safeAreaPadding(safeInsets)
            // A dimming layer, not the deck's opacity: fading the deck re-rendered all its shadows and
            // glass off screen on every frame of the transition.
            .overlay {
                Color.black.opacity(pageShown ? 0.7 * (1 - progress) : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            PageView(
                search: $search,
                sheetSource: sheetSource,
                liveHidden: transitioning,
                sheetsDismissed: sheetsDismissed,
                chromeOpacity: max(0, 1 - progress * 2.5),
                swipeX: swipeX,
                screenWidth: screen.width,
                safeInsets: safeInsets,
                swipeNeighbour: swipeNeighbour,
                swipeOpensNewTab: swipeOpensNewTab,
                arriving: arriving,
                transitionLayer: AnyView(transitionLayer),
                onLift: lift,
                onLiftEnd: endLift,
                onSwipe: swipe,
                onSwipeEnd: endSwipe,
                onShowTabs: closePage,
                onSearchOpen: showPageAtOnce,
                onSearchLeave: unrecede,
                onNewTab: startNewTab
            )
            .overlay {
                if browser.selected.isPrivate, browser.privateLocked {
                    PrivateLockedPage(offersLeave: true)
                        .background(.ultraThickMaterial)
                        .environment(\.colorScheme, .dark)
                        .ignoresSafeArea()
                }
            }
            // Always in the hierarchy, only hidden behind the deck, so the web views stay attached.
            .opacity(pageShown ? 1 : 0)
            .allowsHitTesting(pageShown)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screen = $0 }
        // Beside a camera column the bars go in the column, so even the Duo's wide inner screen keeps
        // the upright layout: no top bar or tab strip over the page.
        .environment(\.isLandscape, screen.width > screen.height && !Self.sideRail(safeInsets))
        .onChange(of: screen.width > screen.height && !Self.sideRail(safeInsets), initial: true) { barOnTop = $1 }
        // Over the bottom bar, on the page and on the deck.
        .overlay(alignment: .bottom) {
            UndoCloseCapsule()
                .padding(.bottom, safeInsets.bottom + 72)
        }
        .ignoresSafeArea()
        // An item, not a flag: a flag read only in the sheet's closure reached it stale.
        .sheet(item: $settings, onDismiss: {
            if onboardingRequested {
                onboardingRequested = false
                onboardingDone = false
            }
        }) { sheet in
            SettingsView(onOpenPage: showPageAtOnce, onShowOnboarding: { onboardingRequested = true },
                         opensWorkspaces: sheet == .workspaces)
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: { whatsNewPending = false }) {
            WhatsNewView().onAppear(perform: WhatsNew.markSeen)
        }
        .haptic(.impact(weight: .light), trigger: search) { old, new in old == nil && new != nil }
        .onChange(of: search) { old, new in
            if old == nil, new != nil { recede() }
            guard search == nil else { return }
            unrecede()
            // A cancelled new-tab search mustn't leave the deck on another workspace than the page's.
            if pageShown { browser.space = browser.selected.spaceID }
            guard swipedToNewTab else { return }
            swipedToNewTab = false
            withAnimation(settle) { swipeX = 0 } completion: { endTransition() }
        }
        .onAppear {
            // The tab shown at launch is restored and still loading.
            if !browser.selected.hasPainted, let image = browser.selected.snapshot { reveal(browser.selected, from: image) }
        }
        .onChange(of: browser.searchRequested, initial: true) { takeSearchRequest() }
        .onChange(of: whatsNewPending) { takeSearchRequest() }
        // From the deck too: the new tab's page shows, not just its card.
        .onChange(of: browser.linksOpened) {
            dismissSheets()
            search = nil
            showPageAtOnce()
        }
        // A restored tab's snapshot is held over it until it paints; another tab must not show under it.
        .onChange(of: browser.selectedID) { veil = nil }
        // On arrival only: a dismissed search stays down, leaving the deck and settings reachable.
        .onChange(of: blankShown, initial: true) {
            if blankShown, search == nil, settings == nil { search = .newTab }
        }
    }

    private func takeSearchRequest() {
        guard !whatsNewPending, let request = browser.searchRequested else { return }
        browser.searchRequested = nil
        dismissSheets()
        openSearch(request)
    }

    /// A link or search from outside the app goes in front, not behind whatever sheet was left open.
    private func dismissSheets() {
        settings = nil
        showDownloads = false
        sheetsDismissed += 1
    }

    /// New-tab search asked for from outside, in Private or else the current tab's workspace; a search
    /// already open switches over.
    private func openSearch(_ request: BrowserModel.SearchRequest) {
        FrameMeter.mark("open search")
        if request == .privateTab {
            browser.space = BrowserModel.privateSpace
        } else if browser.space == BrowserModel.privateSpace {
            browser.space = browser.selected.isPrivate ? nil : browser.selected.spaceID
        }
        search = .newTab
    }

    // MARK: - Transition layer

    /// The page as an image, cropped and scaled onto its card for the deck transitions, or sliding next
    /// to the neighbouring tab for a swipe.
    @ViewBuilder private var transitionLayer: some View {
        if transitioning {
            let card = currentCard
            let k = card.width / max(screen.width, 1)
            let a = anchor ?? CGPoint(x: screen.midX, y: screen.midY)
            let swipeRadius = min(abs(swipeX) / 2, 48)
            ZStack(alignment: .topLeading) {
                if swipeOpensNewTab {
                    NewTabPlaceholder(spaceID: browser.selected.spaceID)
                        .frame(width: screen.width, height: screen.height)
                        .clipShape(.rect(cornerRadius: swipeRadius, style: .continuous))
                        .offset(x: swipeX + screen.width + Self.swipeGap)
                } else if swipeX != 0, let neighbour = swipeNeighbour {
                    PageImage(image: neighbour.snapshot, host: neighbour.isPrivate ? nil : neighbour.url?.host(),
                              blank: neighbour.url == nil, space: neighbour.spaceID, offset: neighbour.startPageOffset,
                              failed: neighbour)
                        .frame(width: screen.width, height: screen.height)
                        .clipShape(.rect(cornerRadius: swipeRadius, style: .continuous))
                        .offset(x: swipeX + (swipeX > 0 ? -1 : 1) * (screen.width + Self.swipeGap))
                }
                PageImage(image: cover, view: coverView, host: browser.selected.isPrivate ? nil : browser.selected.url?.host(),
                          blank: browser.selected.url == nil, space: browser.selected.spaceID,
                          offset: browser.selected.startPageOffset, failed: browser.selected)
                    .frame(width: screen.width, height: screen.height)
                    .clipShape(PageMask(progress: progress, minRadius: swipeRadius, cropHeight: card.height / k, scale: k))
                    // The card's shadow, growing in as the page shrinks: without it the shadow blinked out
                    // while the page moved. Divided by the scale, so it lands at the card's size.
                    .background {
                        let scale = 1 + (k - 1) * progress
                        PageMask(progress: progress, minRadius: swipeRadius, cropHeight: card.height / k, scale: k)
                            .fill(.black)
                            .shadow(color: .black.opacity(0.25 * progress), radius: 18 / scale, x: -6 / scale, y: 8 / scale)
                    }
                    .scaleEffect(1 + (k - 1) * progress,
                                 anchor: UnitPoint(x: a.x / max(screen.width, 1), y: a.y / max(screen.height, 1)))
                    .offset(follow)
                    .offset(x: swipeX)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.identity)
        } else if let veil {
            PageImage(image: veil, host: nil)
                .frame(width: screen.width, height: screen.height)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Freezes the page into its snapshot and hides the live view; the start of every transition.
    private func beginTransition() {
        guard !transitioning else { return }
        transitionID += 1
        veil = nil
        browser.selected.stopScrolling()
        // A start page caught mid-glide: the copy shows where it is now, and the page stops there.
        if browser.selected.url == nil { browser.selected.startPageOffset = browser.selected.liveStartPageOffset }
        coverView = browser.selected.liveSnapshot()
        cover = browser.selected.snapshot
        // Always: a video, a dismissed sheet or an inner scroll changes the page without moving its scroll
        // view. A page still loading keeps its saved image.
        if browser.selected.snapshot == nil || browser.selected.hasPainted { browser.selected.refreshSnapshot() }
        transitioning = true
    }

    private func endTransition() {
        transitioning = false
        cover = nil
        coverView = nil
        anchor = nil
        follow = .zero
        heldCard = nil
    }

    // MARK: - Deck transitions

    private var currentCard: CGRect {
        heldCard ?? cardFrames[browser.selectedID ?? UUID()] ?? Self.fallbackCard(in: screen)
    }

    /// The translation that, with the page scaled about `anchor`, lands it exactly on its card.
    private func followOntoCard(anchor a: CGPoint) -> CGSize {
        let card = currentCard
        let k = card.width / max(screen.width, 1)
        return CGSize(width: card.minX - screen.minX - (a.x - screen.minX) * (1 - k),
                      height: card.minY - screen.minY - (a.y - screen.minY) * (1 - k))
    }

    /// Live drag: the grabbed point stays under the finger while the page shrinks with upward travel.
    private func lift(translation: CGSize, start: CGPoint) {
        // Not keyed on `transitioning`: after a bar swipe it stays set while the new tab loads.
        if !lifting {
            lifting = true
            transitionID += 1
            liftOrigin = nil
        }
        beginTransition()
        let up = max(0, -translation.height)
        // Only once it really rises; undone if the lift is called off.
        if up > 0, liftOrigin == nil {
            liftOrigin = browser.position(of: browser.selected)
            bringSelectedToEnd()
        }
        // Matched to a Safari recording: about 40% of the screen height of travel reaches card size,
        // and the page rises at half finger speed so its top stays on screen while it shrinks.
        withAnimation(.interactiveSpring) {
            anchor = start
            progress = min(up / (screen.height * 0.4), 1)
            follow = CGSize(width: translation.width,
                            height: translation.height < 0 ? translation.height * 0.5 : translation.height / 3)
        }
    }

    private func endLift(translation: CGSize, predicted: CGSize) {
        lifting = false
        // Raised, then flung back down: called off, however high it got.
        let flungBack = predicted.height - translation.height > 150
        if (-translation.height > 70 && !flungBack) || -predicted.height > 260 {
            closePage()
        } else {
            // Retargeting the in-flight interactive spring keeps the finger's velocity.
            let id = transitionID
            let origin = liftOrigin
            let tab = browser.selected
            withAnimation(settle) { progress = 0; follow = .zero } completion: {
                guard id == transitionID else { return }
                // Under the full-screen page again, so the deck's reshuffle isn't seen.
                if let origin {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { browser.move(tab, to: origin) }
                }
                endTransition()
            }
        }
        liftOrigin = nil
    }

    private func openPage() {
        FrameMeter.mark("open page")
        let a = CGPoint(x: screen.midX, y: screen.midY)
        cover = browser.selected.snapshot
        // Drawn over the image: a card tapped during a shrink would grow with the old page's picture.
        coverView = nil
        transitioning = true
        anchor = a
        progress = 1
        follow = followOntoCard(anchor: a)
        pageShown = true
        opening = true
        transitionID += 1
        let id = transitionID
        // Let the deck lay out the card first so the page grows out of its real frame.
        Task {
            await Task.yield()
            withAnimation(settle) { progress = 0; follow = .zero } completion: {
                opening = false
                if id == transitionID { reveal(browser.selected) }
            }
        }
    }

    /// Ends a transition onto a tab. One that hasn't loaded yet (restored at launch, or reloading after
    /// iOS reclaimed it) stays under its snapshot, which fades once the page is drawn: no white flash.
    private func reveal(_ tab: BrowserTab, from image: UIImage? = nil) {
        // A failed page never paints, and the veil would sit over its error screen.
        guard !tab.hasPainted, tab.loadFailure == nil, let image = image ?? cover ?? tab.snapshot else { endTransition(); return }
        veil = image
        endTransition()
        Task {
            for _ in 0..<40 where !tab.hasPainted && veil != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            withAnimation(.easeOut(duration: 0.3)) { veil = nil }
        }
    }

    /// Under the search sheet the screen steps back, like Lens. Not after a swipe to a new tab: that
    /// page has already slid away.
    private func recede() {
        guard pageShown, !swipedToNewTab else { return }
        ScreenRecess.begin()
    }

    private func unrecede() { ScreenRecess.end() }

    /// The search sheet, or in start-page mode a tab of its own in the deck's workspace. From the deck
    /// it grows out of the front card's place, where its card goes; from a page it shows at once.
    private func startNewTab() {
        guard newTabStyle == .page else {
            search = .newTab
            return
        }
        let front = currentCard
        browser.open(nil)
        guard !pageShown else { return showPageAtOnce() }
        heldCard = front
        openPage()
    }

    /// Like Safari after a search: the page is already full screen under the search screen as it
    /// slides away, so neither the deck nor a grow-from-card shows in between.
    private func showPageAtOnce() {
        FrameMeter.mark("show page")
        transitionID += 1
        swipedToNewTab = false
        swipeX = 0
        endTransition()
        progress = 0
        pageShown = true
    }

    private func closePage() {
        FrameMeter.mark("close page")
        let reordered = bringSelectedToEnd()
        beginTransition()
        transitionID += 1
        let id = transitionID
        let a = anchor ?? CGPoint(x: screen.midX, y: screen.midY)
        Task {
            // A reordered deck must lay out first, so the page shrinks onto the card's new frame.
            if reordered { await Task.yield() }
            withAnimation(settle) {
                anchor = a
                progress = 1
                follow = followOntoCard(anchor: a)
            } completion: {
                guard id == transitionID else { return }
                pageShown = false
                endTransition()
            }
        }
    }

    /// Done under the full-screen page, so the deck's reshuffle is never seen.
    @discardableResult private func bringSelectedToEnd() -> Bool {
        let siblings = browser.tabs(in: browser.selected.spaceID)
        guard siblings.last?.id != browser.selectedID else { return false }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { browser.moveToEnd(browser.selected) }
        return true
    }

    private static func fallbackCard(in screen: CGRect) -> CGRect {
        let width = screen.width * 0.72
        return CGRect(x: screen.minX + (screen.width - width) / 2, y: screen.minY + screen.height * 0.15,
                      width: width, height: width * 1.9)
    }

    // MARK: - Swipe between tabs

    /// The tab a bar swipe reveals, from the same workspace: dragging right shows the previous one,
    /// left the next one.
    private var swipeNeighbour: BrowserTab? {
        let siblings = browser.tabs(in: browser.selected.spaceID)
        guard let index = siblings.firstIndex(where: { $0.id == browser.selectedID }) else { return nil }
        let next = swipeX > 0 ? index - 1 : index + 1
        return siblings.indices.contains(next) ? siblings[next] : nil
    }

    /// Like Safari: dragging left from the last tab of a workspace brings in a new one.
    private var swipeOpensNewTab: Bool {
        swipeX < 0 && swipeNeighbour == nil && browser.selected.url != nil
    }

    /// Puts the tab a committed swipe is sliding in in front, at once.
    private func land() {
        guard let landing else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            browser.selectedID = landing.id
            cover = landing.snapshot
            coverView = nil
            swipeX = 0
            arriving = false
        }
        self.landing = nil
    }

    private func swipe(_ dx: CGFloat) {
        // A swipe during the last one's landing starts from the tab it was landing on.
        land()
        // A new swipe, possibly while the last one's page is still being revealed.
        if swipeX == 0 { transitionID += 1 }
        beginTransition()
        swipeX = dx
        // Resist past the first tab; past the last one waits a new tab.
        if swipeNeighbour == nil, !swipeOpensNewTab { swipeX = dx / 4 }
    }

    private func endSwipe(_ dx: CGFloat, predicted: CGFloat) {
        FrameMeter.mark("swipe end")
        let width = screen.width + Self.swipeGap
        // Predicted includes the drag so far: opposite signs mean a flick back the other way.
        let committed = dx * predicted > 0 && (abs(dx) > width * 0.35 || abs(predicted) > width * 0.6)
        if swipeOpensNewTab, committed {
            FrameMeter.mark("swipe to new tab")
            swipeCommits += 1
            guard newTabStyle == .sheet else {
                // The start page slid in on the placeholder; the new tab takes its place.
                withAnimation(swipeCommit) { swipeX = -width } completion: {
                    browser.open(nil, in: browser.selected.spaceID)
                    showPageAtOnce()
                }
                return
            }
            swipedToNewTab = true
            withAnimation(swipeCommit) { swipeX = -width }
            search = .newTab
            return
        }
        let id = transitionID
        guard let neighbour = swipeNeighbour, committed else {
            withAnimation(settle) { swipeX = 0 } completion: { if id == transitionID { endTransition() } }
            return
        }
        let target = swipeX > 0 ? width : -width
        swipeCommits += 1
        landing = neighbour
        withAnimation(swipeCommit) {
            swipeX = target
            arriving = true
        } completion: {
            // Another swipe already landed it and went on.
            guard landing?.id == neighbour.id else { return }
            land()
            Task {
                // The neighbour's web view needs a moment to paint after being shown.
                try? await Task.sleep(for: .milliseconds(150))
                if id == transitionID { reveal(neighbour) }
            }
        }
    }
}


extension EnvironmentValues {
    /// Wider than tall, from the root's own size: the size class read compact on a portrait iPhone.
    @Entry var isLandscape = false
}

/// One tab in the landscape strip; the selected one carries its close button, as in Safari.
private struct TabChip: View {
    let tab: BrowserTab
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if selected {
                Button("Close Tab", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            SiteIcon(host: tab.url?.host(), size: 16, fetch: !tab.isPrivate)
            Text(tab.title.isEmpty ? tab.url?.host() ?? "New Tab" : tab.title)
                .lineLimit(1)
        }
        .font(.footnote.weight(selected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .frame(width: 170, height: 28, alignment: .leading)
        .background { if selected { Capsule().fill(.primary.opacity(0.12)) } }
        .contentShape(.capsule)
        .onTapGesture(perform: onSelect)
    }
}

/// The screen stepping back behind the search sheet, as a snapshot scaled in UIKit. Its Core Animation
/// spring keeps running while the main thread builds the sheet; a SwiftUI animation dropped frames there.
@MainActor
private enum ScreenRecess {
    private static weak var cover: UIView?

    static func begin() {
        guard cover == nil,
              let root = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController?.view,
              let snapshot = root.snapshotView(afterScreenUpdates: false) else { return }
        // In the root view, so under the sheet's own container.
        let cover = UIView(frame: root.bounds)
        cover.backgroundColor = .black
        cover.isUserInteractionEnabled = false
        snapshot.frame = cover.bounds
        snapshot.clipsToBounds = true
        snapshot.layer.cornerCurve = .continuous
        cover.addSubview(snapshot)
        root.addSubview(cover)
        self.cover = cover
        // Scaled about the bottom edge; matched to a Lens recording.
        let scale = 0.92
        UIView.animate(springDuration: 0.45, bounce: 0) {
            snapshot.transform = CGAffineTransform(translationX: 0, y: cover.bounds.height * (1 - scale) / 2)
                .scaledBy(x: scale, y: scale)
            snapshot.layer.cornerRadius = 40
        }
    }

    /// During a swipe down: the page follows the sheet, and goes back if the swipe is called off.
    static func end(alongside coordinator: any UIViewControllerTransitionCoordinator) {
        guard let cover, let snapshot = cover.subviews.first else { return }
        let transform = snapshot.transform
        let radius = snapshot.layer.cornerRadius
        coordinator.animateAlongsideTransition(in: cover, animation: { _ in
            snapshot.transform = .identity
            snapshot.layer.cornerRadius = 0
        }) { context in
            if context.isCancelled {
                snapshot.transform = transform
                snapshot.layer.cornerRadius = radius
            } else {
                cover.removeFromSuperview()
                if self.cover === cover { self.cover = nil }
            }
        }
    }

    static func end() {
        guard let cover, let snapshot = cover.subviews.first else { return }
        self.cover = nil
        UIView.animate(springDuration: 0.45, bounce: 0) {
            snapshot.transform = .identity
            snapshot.layer.cornerRadius = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }
}

/// Calls `action` when the sheet it sits in starts to go, or moves the page with a swipe that may be
/// called off. SwiftUI clears the sheet's binding only once the sheet has gone.
private struct SheetLeaving: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> Watcher { Watcher(action: action) }
    func updateUIViewController(_ watcher: Watcher, context: Context) { watcher.action = action }

    final class Watcher: UIViewController {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let coordinator = transitionCoordinator, coordinator.isInteractive else { return action() }
            ScreenRecess.end(alongside: coordinator)
        }
    }
}

/// As in Lens: for a few seconds after a tab closes, a capsule offers to put it back.
private struct UndoCloseCapsule: View {
    @Environment(BrowserModel.self) private var browser
    @State private var restores = 0

    var body: some View {
        ZStack {
            if let undo = browser.undo {
                Button("Undo Close Tab", systemImage: "arrow.uturn.backward") {
                    restores += 1
                    withAnimation(.smooth(duration: 0.35)) { browser.undoClose() }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                // Regular, not large: large stood taller than the switcher's pill below it.
                .controlSize(.regular)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: undo.tab.id) {
                    guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
                    browser.dropUndo()
                }
            } else if let unloaded = browser.unloaded {
                Label("Unloaded, still in \(unloaded.folder)", systemImage: "moon.zzz")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: unloaded.id) {
                        guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
                        if browser.unloaded?.id == unloaded.id { browser.unloaded = nil }
                    }
            }
        }
        .animation(.snappy, value: browser.undo?.tab.id)
        .animation(.snappy, value: browser.unloaded)
        .haptic(.impact(weight: .light), trigger: browser.undo?.tab.id) { _, new in new != nil }
        .haptic(.success, trigger: restores)
    }
}

/// Watches a page's scroll offset in a view of its own. Read in PageView's body, the offset re-ran all
/// of it, bar and sheets included, on every scroll frame.
private struct ScrollWatch: View {
    let tab: BrowserTab
    let onChange: (CGFloat, CGFloat) -> Void

    var body: some View {
        Color.clear.onChange(of: tab.scrollY) { onChange($0, $1) }
    }
}

/// Hands its content an animated progress, so a spring between two values still passes through every
/// layout in between instead of interpolating the end frames.
private struct Morphing<Content: View>: View, Animatable {
    var progress: CGFloat
    var shrink: CGFloat
    var arrive: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat, CGFloat) -> Content

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(shrink, arrive)) }
        set { (progress, shrink, arrive) = (newValue.first, newValue.second.first, newValue.second.second) }
    }

    var body: some View { content(progress, shrink, arrive) }
}

/// A button beside the capsule as the bar collapses: gone by halfway, shrinking slightly where it is.
private struct FadeInPlace: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.25 * progress)
            .opacity(max(0, 1 - progress * 2))
    }
}

/// The system zoom transition out of `id`, or the standard sheet when there is none.
private struct ZoomFromSource: ViewModifier {
    let id: String?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let id {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// Marks the view a sheet grows out of; only the selected tab's bar, not a swipe neighbour's.
private struct SheetSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Masks content right of a global x, wherever the content itself has moved.
private struct ClipBefore: ViewModifier {
    let x: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: max(0, x - geo.frame(in: .global).minX))
            }
        }
    }
}

/// What a swipe past the last tab brings in.
private struct NewTabPlaceholder: View {
    let spaceID: String?
    @AppStorage(SettingsKey.newTabStyle) private var style = NewTabStyle.sheet

    var body: some View {
        if style == .page {
            BlankTab(spaceID: spaceID)
        } else {
            Color(.systemBackground).overlay {
                Label("New Tab", systemImage: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A full-screen page snapshot, top-aligned; white with the site's letter when there is none yet.
private struct PageImage: View {
    let image: UIImage?
    var view: UIView? = nil
    let host: String?
    /// A tab without a page, which has no snapshot: drawn itself, not a blank web page's white.
    var blank = false
    var space: String? = nil
    var offset: CGFloat = 0
    /// Its failure screen is drawn over the web view, so no snapshot of the page has it.
    var failed: BrowserTab? = nil

    var body: some View {
        Color.white.overlay(alignment: .top) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if blank {
                BlankTab(spaceID: space, offset: offset)
            } else if view == nil {
                SiteIcon(host: host, size: 56).padding(.top, 180)
            }
        }
        // The live snapshot over the saved image: it draws a few frames late, and white showed meanwhile.
        .overlay(alignment: .top) {
            if let view { SnapshotHost(view: view) }
        }
        .overlay {
            if let failed, failed.loadFailure != nil { LoadFailurePage(tab: failed) }
        }
    }
}

/// In place of a page that couldn't load; WebKit shows no error page of its own.
private struct LoadFailurePage: View {
    let tab: BrowserTab

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open This Page", systemImage: "exclamationmark.circle")
        } description: {
            Text(tab.loadFailure?.message ?? "")
        } actions: {
            Button("Try Again") { tab.retryFailedLoad() }
                .buttonStyle(.borderedProminent)
            if tab.pageURL != nil { Button("Back to Page") { tab.dismissLoadFailure() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Shows a render-server snapshot view; SwiftUI scales and clips it like an image.
private struct SnapshotHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame.origin = .zero
        container.addSubview(view)
    }
}

/// Full screen at 0; at 1 a rounded crop from the top with the card's aspect.
private struct PageMask: Shape {
    var progress: CGFloat
    /// The swipe's rounding, animated with it.
    var minRadius: CGFloat
    let cropHeight: CGFloat
    /// The card's size against the screen's; the page is drawn unscaled and shrunk afterwards.
    let scale: CGFloat

    /// The radius is worked out per frame from these: passed in whole, it held its end value for the
    /// whole animation, and a page opening from the deck kept square corners until it landed.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, minRadius) }
        set { (progress, minRadius) = (newValue.first, newValue.second) }
    }

    private static let cardRadius: CGFloat = 34
    /// The smallest screen corner of a Face ID iPhone, so at full size the corners hide behind the screen's.
    private static let screenRadius: CGFloat = 39

    func path(in rect: CGRect) -> Path {
        let height = rect.height + (cropHeight - rect.height) * progress
        let onScreen = Self.screenRadius + (Self.cardRadius - Self.screenRadius) * progress
        let radius = max(onScreen / (1 + (scale - 1) * progress), minRadius)
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                    cornerRadius: radius, style: .continuous)
    }
}

/// The live page: every tab's web view in one host, the selected one shown, with the bar over it.
private struct PageView: View {
    /// The search screen, shown by the root over everything.
    @Binding var search: NewTabView.Mode?
    let sheetSource: Namespace.ID
    let liveHidden: Bool
    let sheetsDismissed: Int
    let chromeOpacity: Double
    let swipeX: CGFloat
    let screenWidth: CGFloat
    let safeInsets: EdgeInsets
    let swipeNeighbour: BrowserTab?
    let swipeOpensNewTab: Bool
    let arriving: Bool
    let transitionLayer: AnyView
    /// Finger translation and global start point, live.
    let onLift: (CGSize, CGPoint) -> Void
    /// Final and predicted translation when the finger lifts.
    let onLiftEnd: (CGSize, CGSize) -> Void
    /// Sideways drag on the bar, live and on release (with predicted travel): switches tabs.
    let onSwipe: (CGFloat) -> Void
    let onSwipeEnd: (CGFloat, CGFloat) -> Void
    let onShowTabs: () -> Void
    /// The search sheet opened or switched to a page.
    let onSearchOpen: () -> Void
    /// The search sheet started to go, before SwiftUI clears its binding.
    let onSearchLeave: () -> Void
    /// A new tab, as the new-tab style has it.
    let onNewTab: () -> Void

    @Environment(BrowserModel.self) private var browser
    @AppStorage(SettingsKey.collapseOnScroll) private var collapseOnScroll = true
    /// Settled state: the page's insets and the landscape strip follow it, not the live progress.
    @State private var collapsed = false
    /// 0 is the full bar, 1 the pill. Follows the scroll while it moves, then settles at either end.
    @State private var collapse: CGFloat = 0
    @State private var settleTimer = SettleTimer()
    /// The collapsed pill's width: its host label plus padding.
    @State private var pillWidth: CGFloat = 120
    /// The host label's centre in the full bar, relative to the capsule's centre.
    /// Per tab: its neighbour's capsule lands with the buttons of its own page, not the current tab's.
    @State private var hostOffsets: [BrowserTab.ID: CGFloat] = [:]
    /// Each tab's host label width at full size, for its compact capsule during a swipe.
    @State private var labelWidths: [BrowserTab.ID: CGFloat] = [:]
    /// The tab whose scroll offset was seen last.
    @State private var scrollTab: BrowserTab.ID?
    /// The page's bottom inset follows the bar, and that nudges the scroll position; scroll changes
    /// right after a toggle are ignored so the bar doesn't flip back and forth.
    @State private var collapseToggled = Date.distantPast
    @State private var showSettings = false
    @State private var reader: ReaderArticle?
    @State private var showPageSheet = false
    @State private var intelligenceSearch: IntelligenceSearchRequest?
    /// What opened the page sheet, the menu button or the address, for it to grow out of.
    @State private var pageSheetSource = "menu"
    /// When a long press opened the sheet; the tap that ends the same touch is ignored.
    @State private var longPressed = Date.distantPast
    private var justLongPressed: Bool { Date.now.timeIntervalSince(longPressed) < 0.8 }
    /// The page sheet's choice, run once the sheet has gone.
    @State private var pageAction: PageSheet.Action?
    @State private var showDownloads = false
    /// The tab whose address is showing "Reader Available" for a moment.
    @State private var readerAnnounced: BrowserTab.ID?
    /// A finished download whose bar button has gone.
    @State private var dismissedDownload: UUID?
    /// Set to start a translation; invalidated to run it again.
    @State private var translation: TranslationSession.Configuration?
    /// The tab whose page shows a translation, so its menu offers the original back.
    @State private var translationFailed = false
    @State private var translating = false
    @State private var alreadyTranslated = false
    /// The page's language when Apple's translator can't handle it, for the alert.
    @State private var unsupportedLanguage: String?
    @State private var sendResult: SendResult?
    /// The tab a new Zen folder is being named for.
    @State private var folderFor: BrowserTab?
    @State private var folderName = ""
    @Environment(AccountService.self) private var account

    private enum SendResult: Identifiable {
        case sent(String), failed
        var id: String { if case .sent(let name) = self { name } else { "failed" } }
    }
    @State private var readerUnavailable = false
    @State private var dragAxis: Axis?
    /// A sideways drag that started off the address field: tab switching belongs to the field only.
    @State private var dragIgnored = false
    /// The address field's global frame, expanded or collapsed.
    @State private var addressFrame: CGRect = .zero
    /// Where the buttons that stay put during a swipe begin; sliding capsules' content ends there.
    @State private var trailingButtonsMinX: CGFloat = .infinity
    /// True while the finger is down; resets on its own when the system cancels the drag.
    @GestureState private var dragging = false
    /// The phone on its side: as in Safari, the bar moves to the top with a strip of the tabs under it.
    @Environment(\.isLandscape) private var landscape
    private static let stripHeight: CGFloat = 36
    /// The strip lists the workspace's tabs; one tab needs no strip.
    private var showsStrip: Bool { browser.tabs(in: browser.selected.spaceID).count > 1 }
    /// Landscape: the top chrome's height under the safe area, the page's top inset. Collapsed, the pill.
    private var topChromeHeight: CGFloat {
        collapsed ? 44 : Self.barHeight + (showsStrip ? Self.stripHeight + 6 : 0)
    }

    /// The bar's height (48) plus its top padding (8); with the home indicator, the page's bottom inset.
    private static let barHeight: CGFloat = 56
    /// Collapsed, the pill drops into the home indicator area and the page gets the space back, as in
    /// Safari: measured there, the pill's bottom sits about 14 pt above the screen edge.
    private func collapseDrop(_ insets: EdgeInsets) -> CGFloat { max(0, insets.bottom - 7) }
    private static let collapsedInset: CGFloat = 50

    var body: some View {
        let tab = browser.selected
        let insets = safeInsets
        ZStack(alignment: .bottom) {
                // Fills the side cutouts the page keeps clear of; the deck showed through them.
                if insets.leading > 0 || insets.trailing > 0 { Color(.systemGroupedBackground) }
                // Shown in the gap between sliding pages during a swipe.
                if swipeX != 0 { Color(.systemGray5) }
                // Full screen like Safari, with the status bar and the bar declared obscured: fixed
                // headers sit below the status bar, fixed bottom menus above the bar, and content
                // scrolls under both. The bottom inset shrinks only while the bar is collapsed.
                // Swapped for its snapshot in one frame: caught in a drag's animation, the two cross-faded.
                WebHost(browser: browser, insets: pageInsets(insets))
                    // Clear of side cutouts, as Safari lays out: the iPhone Duo's camera column and the
                    // notch side in landscape. Top and bottom stay obscured insets, under which content scrolls.
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .opacity(liveHidden ? 0 : 1)
                    .animation(nil, value: liveHidden)
                if tab.url == nil {
                    BlankTab(spaceID: tab.spaceID, tab: tab,
                             insets: EdgeInsets(top: pageInsets(insets).top, leading: insets.leading,
                                                bottom: 0, trailing: insets.trailing),
                             isCovered: liveHidden)
                        // Each blank tab its own page, so one's scroll position isn't another's.
                        .id(tab.id)
                        .opacity(liveHidden ? 0 : 1)
                        .animation(nil, value: liveHidden)
                }
                if tab.loadFailure != nil {
                    LoadFailurePage(tab: tab)
                        .opacity(liveHidden ? 0 : 1)
                        .animation(nil, value: liveHidden)
                }
                transitionLayer
                if landscape {
                    VStack(spacing: 6) {
                        bar
                        if showsStrip, !collapsed {
                            tabStrip
                                .padding(.leading, max(16, insets.leading))
                                .padding(.trailing, max(16, insets.trailing))
                                .opacity(chromeOpacity * (1 - collapse))
                                .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, insets.top)
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        bar.padding(.bottom, insets.bottom)
                            .offset(y: collapse * collapseDrop(insets))
                    }
                    if sideRail {
                        // As the system lays out bars beside a side camera: the tab buttons go in its column.
                        VStack(spacing: 10) {
                            Spacer(minLength: 0)
                            iconButton("plus", action: onNewTab)
                                .frame(width: 48, height: 48)
                                .glassEffect(.regular.interactive(), in: .circle)
                            tabsButton
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .modifier(FadeInPlace(progress: collapse))
                        .allowsHitTesting(collapse < 0.5)
                        .opacity(chromeOpacity)
                        .frame(width: insets.trailing)
                        .padding(.bottom, insets.bottom)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
        }
        .ignoresSafeArea()
        // Restored tabs load their page only once shown.
        .onChange(of: browser.selectedID, initial: true) { browser.selected.loadIfNeeded() }
        // Only a real load: sites rewrite their address while scrolling, which kept popping the bar open.
        .onChange(of: tab.pageURL) { if tab.isLoading { withAnimation(.snappy) { expand() } } }
        .onChange(of: browser.selectedID) { expand() }
        .onChange(of: tab.isLoading) { if !tab.isLoading { browser.save() } }
        // An address change without a page load (a site's own navigation) gets no didFinish to check on.
        .task(id: tab.pageURL) {
            guard (try? await Task.sleep(for: .seconds(1.2))) != nil, !tab.isLoading else { return }
            await tab.checkReaderable()
        }
        .task(id: tab.isReaderable ? tab.pageURL : nil) {
            guard tab.isReaderable else { return }
            let id = tab.id
            withAnimation(.smooth(duration: 0.4)) { readerAnnounced = id }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.smooth(duration: 0.4)) { if readerAnnounced == id { readerAnnounced = nil } }
        }
        // Switching tabs swaps whose offset this is: the jump between two pages is not a scroll.
        .background {
            ScrollWatch(tab: tab) { old, new in
                guard scrollTab == browser.selectedID else { scrollTab = browser.selectedID; return }
                handleScroll(from: old, to: new)
            }
            // Here, not on the bar: turning the phone rebuilds the bar, and its gesture never ends.
            .onChange(of: dragging) { if !dragging { cancelDrag() } }
            .onChange(of: landscape) { if dragAxis != nil { cancelDrag() } }
        }
        .onChange(of: tab.isTouching) { fingerChanged() }
        // These sheets sit above the locked page's cover and would keep showing the private tab.
        .onChange(of: browser.privateLocked) {
            guard browser.privateLocked, tab.isPrivate else { return }
            reader = nil
            showPageSheet = false
            intelligenceSearch = nil
            search = nil
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDownloads) { NavigationStack { DownloadsView() } }
        // Presented here, beside the address capsule it grows out of: from the root the zoom found no
        // source and grew from the middle of the screen.
        .sheet(item: $search, onDismiss: {
            intelligenceSearch = browser.intelligenceRequest
            browser.intelligenceRequest = nil
        }) { mode in
            NewTabView(mode: mode, onOpen: onSearchOpen) { search = nil }
                .background(SheetLeaving(action: onSearchLeave))
                .modifier(ZoomFromSource(id: mode == .edit ? "address" : nil, namespace: sheetSource))
        }
        .sheet(item: $intelligenceSearch) { request in
            IntelligenceSearchView(request: request) { url in
                intelligenceSearch = nil
                browser.open(url, in: request.tab.spaceID)
            }
        }
        .sheet(isPresented: $showPageSheet, onDismiss: runPageAction) {
            // The system's zoom transition: the sheet grows out of whatever opened it, and shrinks back.
            PageSheet(tab: tab, isTranslated: tab.isTranslated, sendTargets: account.sendTargets,
                      offersEssentials: folderEditor.offersEssentials(tab)) {
                pageAction = $0
            }
            .navigationTransition(.zoom(sourceID: pageSheetSource, in: sheetSource))
        }
        .onChange(of: tab.readerRequest) {
            guard tab.readerRequest != nil else { return }
            // Once per load: left set, every switch back to this tab opened Reader again.
            tab.readerRequest = nil
            Task { reader = await ReaderArticle.extract(from: tab.webView) }
        }
        .fullScreenCover(item: $reader) { article in
            ReaderView(article: article) { browser.selected.load($0) }
        }
        .alert(item: $sendResult) { result in
            switch result {
            case .sent(let name): Alert(title: Text("Sent to \(NewTabView.shortName(name))"))
            case .failed: Alert(title: Text("Couldn't Send the Tab"), message: Text("Check the connection and try again."))
            }
        }
        .translationTask(translation) { session in
            translating = true
            defer { translating = false }
            let translated = browser.selected
            do {
                // Shows the language download sheet first if the model isn't on the phone yet.
                try await session.prepareTranslation()
                try await PageTranslator.translate(translated.webView, with: session)
            } catch {
                // Earlier batches may already be in the page.
                translated.isTranslated = false
                await PageTranslator.restore(translated.webView)
                translationFailed = true
            }
        }
        // The first translation loads the language model and can take a few seconds.
        .overlay(alignment: .top) {
            if translating {
                Label("Translating…", systemImage: "translate")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, safeInsets.top + 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: translating)
        .alert("New Folder", isPresented: Binding(get: { folderFor != nil }, set: { if !$0 { folderFor = nil } })) {
            TextField("Name", text: $folderName)
            Button("Create") {
                if let tab = folderFor {
                    folderEditor.newFolder(named: folderName, with: tab, in: zenSpace(of: tab))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ZenFolderEditor.newFolderNote(for: folderFor))
        }
        .alert("Already in Your Language", isPresented: $alreadyTranslated) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This page is already in the language your iPhone uses.")
        }
        .alert("Couldn't Translate the Page", isPresented: $translationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The page may already be in your language, or its language isn't available for translation.")
        }
        .alert("Can't Translate \(unsupportedLanguage ?? "")", isPresented: Binding(
            get: { unsupportedLanguage != nil }, set: { if !$0 { unsupportedLanguage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Apple's translator on iPhone doesn't support this language yet.")
        }
        .alert("Reader Isn't Available", isPresented: $readerUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This page has no article to show on its own.")
        }
    }

    private func runPageAction() {
        guard let action = pageAction else { return }
        pageAction = nil
        let tab = browser.selected
        switch action {
        case .find:
            tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
        case .pin:
            folderEditor.togglePin(tab)
        case .essential:
            folderEditor.toggleEssential(tab)
        case .reader:
            Task {
                reader = await ReaderArticle.extract(from: tab.webView)
                readerUnavailable = reader == nil
            }
        case .translate(let target):
            Task { await startTranslation(of: tab, to: target) }
        case .showOriginal:
            tab.isTranslated = false
            Task { await PageTranslator.restore(tab.webView) }
        case .downloads:
            showDownloads = true
        case .settings:
            showSettings = true
        case .send(let device):
            guard let url = tab.pageURL else { return }
            Task { sendResult = await account.send(url, title: tab.title, to: device) ? .sent(device.displayName) : .failed }
        }
    }

    /// Translates from the page's own language into `target`; a page already in it is left alone.
    private func startTranslation(of tab: BrowserTab, to target: Locale.Language) async {
        let source = await PageTranslator.pageLanguage(tab.webView)
        if let source, source.languageCode == target.languageCode {
            alreadyTranslated = true
            return
        }
        // Apple's on-device translator covers about twenty languages; say which one it lacks.
        if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported {
            unsupportedLanguage = Locale.current.localizedString(forIdentifier: source.minimalIdentifier)
                ?? source.minimalIdentifier
            return
        }
        tab.isTranslated = true
        let configuration = TranslationSession.Configuration(source: source, target: target)
        if translation == configuration {
            translation?.invalidate()
        } else {
            translation = configuration
        }
    }

    /// The page's obscured edges: under the bar and the status bar, or in landscape under the top chrome.
    private func pageInsets(_ insets: EdgeInsets) -> UIEdgeInsets {
        if landscape {
            return UIEdgeInsets(top: insets.top + topChromeHeight, left: 0, bottom: insets.bottom, right: 0)
        }
        // Follows the bar as it shrinks, as in Safari: switching only once it settled left fixed footers
        // floating above the pill for a moment.
        let full = Self.barHeight + insets.bottom
        let bottom = insets.bottom > 0 ? full + (Self.collapsedInset - full) * collapse : full
        return UIEdgeInsets(top: insets.top, left: 0, bottom: bottom.rounded(), right: 0)
    }

    private var bar: some View {
        bottomBar
            .padding(.leading, max(16, safeInsets.leading))
            .padding(.trailing, max(16, safeInsets.trailing))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .padding(.top, 8)
            .opacity(chromeOpacity)
            .contentShape(.rect)
            // High priority so interactive glass on the buttons doesn't swallow the drag; taps still pass.
            .highPriorityGesture(liftGesture)
            .onChange(of: sheetsDismissed) {
                reader = nil
                showPageSheet = false
                showSettings = false
                showDownloads = false
                intelligenceSearch = nil
            }
            .onChange(of: browser.tabs.count) {
                let open = Set(browser.tabs.map(\.id))
                hostOffsets = hostOffsets.filter { open.contains($0.key) }
                labelWidths = labelWidths.filter { open.contains($0.key) }
            }
    }

    /// A cancelled drag never reaches onEnded; settle back instead of freezing mid-swipe.
    private func cancelDrag() {
        dragIgnored = false
        guard let axis = dragAxis else { return }
        dragAxis = nil
        if axis == .horizontal { onSwipeEnd(0, 0) } else { onLiftEnd(.zero, .zero) }
    }

    /// Where the neighbouring tab's controls sit relative to the current ones, one page away.
    private var neighbourOffset: CGFloat? {
        guard swipeX != 0, swipeNeighbour != nil || swipeOpensNewTab else { return nil }
        return (swipeX > 0 ? -1 : 1) * (screenWidth + BrowserView.swipeGap)
    }

    // MARK: - Bottom bar

    /// One progress value lays out the whole bar, as in Safari: the address capsule shrinks to the pill
    /// around its label while the buttons fade in place. Nothing is inserted or removed mid-way.
    @ViewBuilder private var bottomBar: some View {
        let tab = browser.selected
        GeometryReader { geo in
            Morphing(progress: collapse, shrink: swipeShrink, arrive: arriving ? 1 : 0) { p, s, a in
                // The address capsules share one glass container, so the system morphs them as liquid:
                // a leaving one shrinks away and the arriving one grows out of nothing, blending where
                // they meet. Buttons stay outside it: inside one, a glass view's opacity is ignored.
                let currentRel = swipeRel(swipeX)
                let neighbourRel = neighbourOffset.map { swipeRel(swipeX + $0) } ?? 0
                let offsets = swipeOffsets(p: p, s: s, a: a, width: geo.size.width,
                                           vanish: (Self.vanish(currentRel) * Self.leaving(a), Self.vanish(neighbourRel)))
                ZStack(alignment: .leading) {
                    historyButtons(tab, p: p, rel: currentRel, offset: offsets.current)
                        .opacity(max(0, 1 - a * 2))
                    if neighbourOffset != nil, let neighbour = swipeNeighbour {
                        historyButtons(neighbour, p: p, rel: neighbourRel, offset: offsets.neighbour)
                            .allowsHitTesting(false)
                    }
                    GlassEffectContainer(spacing: 20) {
                        ZStack(alignment: .leading) {
                            tabCapsule(tab, live: true, p: p, s: s, width: geo.size.width, rel: currentRel,
                                       vanish: Self.vanish(currentRel) * Self.leaving(a), offset: offsets.current)
                            if neighbourOffset != nil {
                                Group {
                                    if let neighbour = swipeNeighbour {
                                        // Compact while it comes in; it opens as a released swipe carries it home.
                                        tabCapsule(neighbour, live: false, p: p, s: 1 - a, width: geo.size.width,
                                                   rel: neighbourRel, vanish: Self.vanish(neighbourRel),
                                                   offset: offsets.neighbour)
                                    } else {
                                        newTabCapsule(p: p, s: 1, width: geo.size.width,
                                                      vanish: Self.vanish(neighbourRel), offset: offsets.neighbour)
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    trailingButtons(p: p)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 48)
            }
        }
        .animation(.snappy, value: tab.canGoBack)
        .animation(.snappy, value: tab.canGoForward)
    }

    private var trailingWidth: CGFloat { sideRail ? 0 : landscape ? 106 : 48 }

    private var sideRail: Bool { BrowserView.sideRail(safeInsets) }

    /// Where a tab's capsule sits in the bar, before any swipe offset.
    /// As shown: `vanish` of its width, kept centred.
    private func capsuleFrame(for tab: BrowserTab?, p: CGFloat, s: CGFloat, width: CGFloat,
                              vanish: CGFloat = 1) -> (x: CGFloat, width: CGFloat) {
        let history = tab.map { ($0.canGoBack ? 1 : 0) + ($0.canGoForward ? 1 : 0) } ?? 0
        let frame = capsuleFrame(p: p, s: s, compact: tab.map(compactWidth) ?? 220,
                                 leading: history > 0 ? CGFloat(history) * 44 + 10 : 0, width: width)
        let shown = frame.width * vanish
        return (frame.x + (frame.width - shown) / 2, shown)
    }

    /// Swipe offsets for the current and neighbouring capsules. Neither passes the tabs button: the one on
    /// the right stops short of it, and the one on the left stops short of that one.
    private func swipeOffsets(p: CGFloat, s: CGFloat, a: CGFloat, width: CGFloat,
                              vanish: (current: CGFloat, neighbour: CGFloat)) -> (current: CGFloat, neighbour: CGFloat) {
        let gap: CGFloat = 12
        let limit = width - trailingWidth - gap
        var current = barOffset(swipeX, width: width, s: s)
        guard let neighbourOffset else { return (min(current, limit - capsuleRight(browser.selected, p: p, s: s, width: width)), 0) }
        var neighbour = barOffset(swipeX + neighbourOffset, width: width, s: s)
        let mine = capsuleFrame(for: browser.selected, p: p, s: s, width: width, vanish: vanish.current)
        let theirs = capsuleFrame(for: swipeNeighbour, p: p, s: swipeNeighbour == nil ? 1 : 1 - a, width: width,
                                  vanish: vanish.neighbour)
        // A pill keeps clear of the other only as much as the other is still there, and not once a
        // released swipe lands (`a`): so when one shrinks away, landing or cancelled, the remaining one
        // eases to its place instead of snapping there the moment the other is gone.
        func easing(_ free: CGFloat, _ held: CGFloat, other: CGFloat) -> CGFloat {
            held + (free - held) * max(a, 1 - other)
        }
        if neighbourOffset < 0 {
            // Neighbour on the left, current on the right.
            current = min(current, limit - (mine.x + mine.width))
            neighbour = easing(neighbour, min(neighbour, mine.x + current - gap - (theirs.x + theirs.width)),
                               other: vanish.current)
        } else {
            neighbour = min(neighbour, limit - (theirs.x + theirs.width))
            current = easing(current, min(current, theirs.x + neighbour - gap - (mine.x + mine.width)),
                             other: vanish.neighbour)
        }
        return (current, neighbour)
    }

    private func capsuleRight(_ tab: BrowserTab, p: CGFloat, s: CGFloat, width: CGFloat) -> CGFloat {
        let frame = capsuleFrame(for: tab, p: p, s: s, width: width)
        return frame.x + frame.width
    }

    /// Capsules narrow with the finger over the first stretch of a swipe, as in Safari, not all at once.
    private var swipeShrink: CGFloat {
        min(1, abs(swipeX) / 140)
    }

    /// How far a tab's page is from home, in pages: 0 shown, ±1 one page aside.
    private func swipeRel(_ pageOffset: CGFloat) -> CGFloat {
        pageOffset / max(screenWidth + BrowserView.swipeGap, 1)
    }

    /// As in Safari the compact capsules travel within the bar, not with their pages: the leaving one
    /// slides under the buttons on one side while the arriving one comes out from under the other.
    private func barOffset(_ pageOffset: CGFloat, width: CGFloat, s: CGFloat) -> CGFloat {
        // A page apart, pills sit side by side with a gap, however long their addresses; the current
        // one counts at its present width, as it is still narrowing early in a swipe.
        let tab = browser.selected
        let history = (tab.canGoBack ? 1 : 0) + (tab.canGoForward ? 1 : 0)
        let full = max(0, width - (history > 0 ? CGFloat(history) * 44 + 10 : 0) - trailingWidth - 10)
        let current = full + (min(compactWidth(tab), full) - full) * s
        let spacing = max(width * 0.45, (current + (swipeNeighbour.map(compactWidth) ?? 220)) / 2 + 16)
        return swipeRel(pageOffset) * spacing
    }

    private func trailingButtons(p: CGFloat) -> some View {
        HStack(spacing: 10) {
            if landscape {
                iconButton("plus", action: onNewTab)
                    .frame(width: 48)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            if !sideRail {
                tabsButton
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .modifier(FadeInPlace(progress: p))
        .allowsHitTesting(p < 0.5)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { trailingButtonsMinX = $0 }
    }

    /// A capsule's width share by its distance from home: whole until 0.56 of a page away, then
    /// shrinking to nothing a little before a page away, so a spring's slow tail leaves no sliver.
    private static func vanish(_ rel: CGFloat) -> CGFloat {
        min(1, max(0, (0.92 - abs(rel)) * 2.8))
    }

    /// The leaving capsule's share of its width as a released swipe lands: gone by under half the way,
    /// so no sliver of it is left beside the arriving bar.
    private static func leaving(_ a: CGFloat) -> CGFloat {
        max(0, 1 - a * 2.2)
    }

    /// Content shows only near home, so the leaving address fades out and the arriving one in.
    private static func presence(_ rel: CGFloat) -> CGFloat {
        max(0, 1 - abs(rel) * 1.8)
    }

    /// Back and forward of a tab, `offset` away from home, beside its capsule.
    @ViewBuilder
    private func historyButtons(_ tab: BrowserTab, p: CGFloat, rel: CGFloat, offset: CGFloat) -> some View {
        if tab.canGoBack || tab.canGoForward {
            HStack(spacing: 0) {
                if tab.canGoBack {
                    historyButton("chevron.backward", items: tab.webView.backForwardList.backList.reversed(), tab: tab) {
                        browser.goBack()
                    }
                }
                if tab.canGoForward {
                    historyButton("chevron.forward", items: tab.webView.backForwardList.forwardList, tab: tab) {
                        browser.goForward()
                    }
                }
            }
            .modifier(ClipBefore(x: contentLimit))
            .glassEffect(.regular.interactive(), in: .capsule)
            .modifier(FadeInPlace(progress: p))
            .opacity(Self.presence(rel))
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .allowsHitTesting(p < 0.5)
            .offset(x: offset)
        }
    }

    /// A tab's address capsule, `offset` away from home and `vanish` of its width, kept centred.
    /// `live` is the selected tab's; the other is a swipe neighbour's.
    private func tabCapsule(_ tab: BrowserTab, live: Bool, p: CGFloat, s: CGFloat, width: CGFloat,
                            rel: CGFloat, vanish: CGFloat, offset: CGFloat) -> some View {
        let history = (tab.canGoBack ? 1 : 0) + (tab.canGoForward ? 1 : 0)
        let base = capsuleFrame(p: p, s: s, compact: compactWidth(tab),
                                leading: history > 0 ? CGFloat(history) * 44 + 10 : 0, width: width)
        let shown = base.width * vanish
        return addressCapsule(tab, live: live, p: p, s: s, presence: Self.presence(rel),
                              frame: (base.x + (base.width - shown) / 2, shown, base.full))
            .offset(x: offset)
    }

    /// The capsule's x and width: the space between the buttons when full (capped and centred on a wide
    /// screen, as in Safari), the pill centred on the screen when collapsed, and linear in between.
    /// While swiping (`s`) it narrows to `compact` around its centre, as Safari's does.
    private func capsuleFrame(p: CGFloat, s: CGFloat, compact: CGFloat, leading: CGFloat,
                              width: CGFloat) -> (x: CGFloat, width: CGFloat, full: CGFloat) {
        let available = max(0, width - leading - trailingWidth - 10)
        let full = landscape ? min(available, 560) : available
        let fullX = leading + (available - full) / 2
        let open = full + (min(compact, full) - full) * s
        let openX = fullX + (full - open) / 2
        return (openX + ((width - pillWidth) / 2 - openX) * p, open + (pillWidth - open) * p, full)
    }

    /// A capsule just wide enough for the tab's address.
    private func compactWidth(_ tab: BrowserTab) -> CGFloat {
        (labelWidths[tab.id] ?? 160) + 40
    }

    /// Text and icons end at the tabs button while a capsule slides under it; the glass merges with the
    /// button's. A mask on the glass itself has no effect inside a GlassEffectContainer.
    private var contentLimit: CGFloat {
        collapse > 0 ? .infinity : trailingButtonsMinX - 4
    }

    /// The bar of the new tab a swipe past the last one brings in.
    private func newTabCapsule(p: CGFloat, s: CGFloat, width: CGFloat, vanish: CGFloat, offset: CGFloat) -> some View {
        let base = capsuleFrame(p: p, s: s, compact: 220, leading: 0, width: width)
        let frame = (x: base.x + base.width * (1 - vanish) / 2, width: base.width * vanish, full: base.full)
        return HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").frame(width: 44, height: 48)
            Text("Search or enter address")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(width: frame.full)
        .modifier(ClipBefore(x: contentLimit))
        .opacity(max(0, 1 - p * 2))
        .frame(width: frame.width, height: min(48 - 12 * p, frame.width))
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
        .offset(x: frame.x + offset)
    }

    /// One glass capsule for both states. The bar's icons fade out over the first half while its host
    /// label shrinks to the pill's size and drifts to the centre, staying readable throughout.
    private func addressCapsule(_ tab: BrowserTab, live: Bool, p: CGFloat, s: CGFloat, presence: CGFloat,
                                frame: (x: CGFloat, width: CGFloat, full: CGFloat)) -> some View {
        // Icons give way to the address as the capsule narrows, whether collapsing or swiping.
        let compacting = max(p, s)
        return ZStack {
            addressBar(tab, live: live, width: frame.full)
                .frame(width: frame.full)
                .opacity(max(0, 1 - compacting * 2) * presence)
                .allowsHitTesting(compacting < 0.5)
            hostLabel(tab)
                // Measured before the cap's frame, which takes all the width it is offered.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    labelWidths[tab.id] = width
                    if live { pillWidth = width * Self.pillScale + 36 }
                }
                .frame(maxWidth: max(0, frame.full - 168))
                .scaleEffect(1 - (1 - Self.pillScale) * p)
                .offset(x: (hostOffsets[tab.id] ?? 0) * (1 - compacting))
                .opacity(presence)
                .allowsHitTesting(false)
        }
        .modifier(ClipBefore(x: contentLimit))
        // No taller than wide: glass at zero width still draws a full-height line, which merged with the arriving capsule.
        .frame(width: frame.width, height: min(48 - 12 * p, frame.width))
        .clipShape(.capsule)
        .contentShape(.capsule)
        .onTapGesture { if collapse > 0.5, !justLongPressed { withAnimation(.snappy) { expand() } } }
        // On the whole capsule, alongside its taps and the glass's own touch handling, so it fires on a
        // real finger anywhere on it, collapsed or not.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            guard live else { return }
            longPressed = .now
            pageSheetSource = "address"
            showPageSheet = true
        })
        .haptic(.impact(weight: .medium), trigger: showPageSheet) { _, new in new && live }
        // Loading progress runs along the field's bottom edge, as in Safari. Inside the glass: an
        // overlay outside it is drawn under the container's glass.
        .overlay(alignment: .bottom) { LoadingLine(tab: tab) }
        // Inside the glass: outside it, in the glass container, the zoom found no source.
        .modifier(SheetSource(id: "address", namespace: sheetSource, enabled: live))
        .glassEffect(.regular.interactive(), in: .capsule)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { if live { addressFrame = $0 } }
        .offset(x: frame.x)
    }

    /// The pill's label size relative to the bar's: footnote against body.
    private static let pillScale: CGFloat = 13 / 17

    private func hostLabel(_ tab: BrowserTab) -> some View {
        HStack(spacing: 6) {
            if readerAnnounced == tab.id {
                // As in Safari: the address briefly says Reader is there, then comes back.
                // Drops its icon, then shrinks a little, when back and forward narrow the capsule.
                ViewThatFits {
                    Label("Reader Available", systemImage: "doc.plaintext")
                    Text("Reader Available").minimumScaleFactor(0.75)
                }
                .transition(.blurReplace)
            } else {
                if tab.isPrivate { PrivateMark() }
                Text(tab.url?.host() ?? "Search or enter address")
                    .foregroundStyle(tab.url == nil ? .secondary : .primary)
                    .transition(.blurReplace)
                // A hidden twin on the right keeps the address centred, as in a regular tab.
                if tab.isPrivate { PrivateMark().hidden() }
            }
        }
        .lineLimit(1)
    }

    private func addressBar(_ tab: BrowserTab, live: Bool, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button("Page Menu", systemImage: "line.3.horizontal") {
                pageSheetSource = "menu"
                showPageSheet = true
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 48)
            .modifier(SheetSource(id: "menu", namespace: sheetSource, enabled: live))
            // The label itself is drawn by hostLabel, which survives into the pill; this keeps its place.
            // A tap edits the address; a long press opens the page sheet.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(.rect)
                .onTapGesture { if !justLongPressed { search = .edit } }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.addressSpace)).midX } action: {
                    hostOffsets[tab.id] = $0 - width / 2
                }
            // Smart buttons, as in Lens: shown only while the page needs them.
            // On a swipe neighbour too: they move the address, which landed in the wrong place without them.
            smartButtons(tab)
            // Keyed on the address, not the loaded page: a tab still loading (restored, or just swiped
            // to) gets them at once, instead of later shifting the address when the page commits.
            if let url = tab.url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 40, height: 48) }
                    .foregroundStyle(.primary)
                if tab.isLoading {
                    iconButton("xmark") { tab.webView.stopLoading() }
                } else {
                    iconButton("arrow.clockwise") {
                        tab.reload()
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .animation(.snappy, value: tab.isReaderable)
        .animation(.snappy, value: DownloadManager.shared.active.first?.state)
        .coordinateSpace(.named(Self.addressSpace))
    }

    private static let addressSpace = "PageView.address"

    @ViewBuilder private func smartButtons(_ tab: BrowserTab) -> some View {
        if let download = DownloadManager.shared.active.first, download.id != dismissedDownload {
            Button("Downloads", systemImage: download.state == .failed ? "exclamationmark.circle"
                   : download.state == .finished ? "checkmark.circle" : "arrow.down.circle") {
                showDownloads = true
            }
            .labelStyle(.iconOnly)
            .symbolEffect(.pulse, isActive: download.state == .running)
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(download.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .frame(width: 40, height: 48)
            .transition(.scale.combined(with: .opacity))
            // A finished download's button lingers a moment, then melts away.
            .task(id: download.state == .running) {
                guard download.state != .running else { return }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.snappy) { dismissedDownload = download.id }
            }
        }
        if tab.isReaderable {
            Button("Reader", systemImage: "doc.plaintext") {
                Task {
                    reader = await ReaderArticle.extract(from: tab.webView)
                    readerUnavailable = reader == nil
                }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 48)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var tabsButton: some View {
        // Tap shows the tabs; long press opens the menu from the button itself, as in Safari. A context
        // menu instead lifted the label out of its glass circle.
        Menu {
            Button("New Tab", systemImage: "plus.square.on.square") { newTab(private: false) }
            Button("New Private Tab", systemImage: "eyes") { newTab(private: true) }
            if !browser.recentlyClosed.isEmpty {
                Menu("Recently Closed", systemImage: "arrow.uturn.backward") {
                    ForEach(browser.recentlyClosed.prefix(10)) { closed in
                        Button(closed.title.isEmpty ? closed.url.host() ?? closed.url.absoluteString : closed.title) {
                            browser.reopen(closed)
                        }
                    }
                }
            }
            let current = browser.selected
            if current.url != nil, !current.fromZenFolder {
                Button(current.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: current.isPinned ? "pin.slash" : "pin") {
                    folderEditor.togglePin(current)
                }
                if folderEditor.offersEssentials(current) {
                    Button(current.zenEssentialID == nil ? "Add to Essentials" : "Remove from Essentials",
                           systemImage: current.zenEssentialID == nil ? "star" : "star.slash") { folderEditor.toggleEssential(current) }
                }
            }
            if let space = zenSpace(of: current) {
                FolderMenuItems(tab: current, space: space, editor: folderEditor) {
                    folderName = ""
                    folderFor = current
                }
            } else if current.spaceID == nil, current.url != nil {
                LocalFolderMenuItems(tab: current, browser: browser) {
                    folderName = ""
                    folderFor = current
                }
            }
            Divider()
            let count = browser.tabs(in: browser.selected.spaceID).count
            if count > 1 {
                Button("Close All \(count) Tabs", systemImage: "xmark.square", role: .destructive) {
                    browser.closeAll(in: browser.selected.spaceID)
                }
            }
            // A Zen folder's tab only unloads, its card staying in the folder.
            Button(current.fromZenFolder ? "Unload Tab" : "Close Tab", systemImage: current.fromZenFolder ? "moon.zzz" : "xmark",
                   role: current.fromZenFolder ? nil : .destructive) { browser.close(browser.selected) }
        } label: {
            Text("\(browser.tabs(in: browser.selected.spaceID).count)")
                .font(.footnote.weight(.semibold))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.5))
                .frame(width: 48, height: 48)
        } primaryAction: {
            onShowTabs()
        }
        .foregroundStyle(.primary)
    }

    private var folderEditor: ZenFolderEditor { ZenFolderEditor(account: account, browser: browser) }

    private func zenSpace(of tab: BrowserTab) -> ZenWorkspaces.Space? {
        guard !tab.isPrivate else { return nil }
        return account.zenWorkspaces?.spaces.first { $0.id == tab.spaceID }
    }

    /// Opens search for a tab in the current workspace, or in Private.
    private func newTab(private isPrivate: Bool) {
        FrameMeter.mark("new tab")
        let current = browser.selected
        if isPrivate {
            browser.space = BrowserModel.privateSpace
        } else if current.isPrivate {
            // A regular new tab from a private page goes to this iPhone's tabs.
            browser.space = nil
        }
        onNewTab()
    }

    /// Landscape: the workspace's tabs side by side, the selected one scrolled into view.
    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs(in: browser.selected.spaceID)) { tab in
                        TabChip(tab: tab, selected: tab.id == browser.selectedID,
                                onSelect: { browser.select(tab) }, onClose: { browser.close(tab) })
                            .id(tab.id)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: browser.selectedID, initial: true) {
                withAnimation(.snappy) { proxy.scrollTo(browser.selectedID, anchor: .center) }
            }
        }
        .frame(height: Self.stripHeight)
        .glassEffect(.regular, in: .capsule)
    }

    /// Back or forward; a long press lists the pages that way, nearest first, as in Safari.
    private func historyButton(_ symbol: String, items: [WKBackForwardListItem], tab: BrowserTab,
                               action: @escaping () -> Void) -> some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button(item.title?.isEmpty == false ? item.title! : item.url.host() ?? item.url.absoluteString) {
                    tab.webView.go(to: item)
                }
            }
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 48)
        } primaryAction: {
            action()
        }
        .foregroundStyle(.primary)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 48)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Gestures

    /// Up from anywhere on the bar goes to the tab overview; sideways switches tabs, but only from the
    /// address field. The axis is fixed by the first movement.
    private var liftGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if dragAxis == nil, !dragIgnored {
                    let sideways = abs(value.translation.width) > abs(value.translation.height)
                    // While a swipe lands its capsule has already left, and the next flick still counts.
                    if sideways, swipeX == 0, !addressFrame.contains(value.startLocation) {
                        dragIgnored = true
                    } else if !sideways, landscape {
                        // A bar at the top has nowhere to lift the page to; the tabs button opens the deck.
                        dragIgnored = true
                    } else {
                        dragAxis = sideways ? .horizontal : .vertical
                    }
                }
                guard !dragIgnored else { return }
                if dragAxis == .horizontal {
                    onSwipe(value.translation.width)
                } else {
                    onLift(value.translation, value.startLocation)
                }
            }
            .onEnded { value in
                defer { dragAxis = nil; dragIgnored = false }
                guard !dragIgnored else { return }
                if dragAxis == .horizontal {
                    onSwipeEnd(value.translation.width, value.predictedEndTranslation.width)
                } else {
                    onLiftEnd(value.translation, value.predictedEndTranslation)
                }
            }
    }

    /// Counts as a toggle: in landscape the page's top inset follows the bar and shifts the scroll
    /// position, which must not collapse it straight back.
    private func expand() {
        settleTimer.task?.cancel()
        withAnimation(Self.settleSpring) { collapse = 0 }
        guard collapsed else { return }
        collapseToggled = .now
        collapsed = false
    }

    /// The finger lifted: settle once the page has stopped too.
    private func fingerChanged() {
        guard !browser.selected.isTouching, collapse > 0, collapse < 1 else { return }
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTimer.task?.cancel()
        settleTimer.task = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !browser.selected.isTouching else { return }
            settle(at: collapse > 0.5 ? 1 : 0)
        }
    }

    /// Scroll distance over which the bar goes from full to pill. A slow scroll collapses it gradually,
    /// a quick one at once but animated, as in Safari.
    private static let collapseDistance: CGFloat = 60
    private static let settleSpring = Animation.spring(response: 0.32, dampingFraction: 0.9)

    /// The bar follows the scroll both ways; once the page stops, it settles at the nearer end.
    private func handleScroll(from old: CGFloat, to new: CGFloat) {
        guard collapseOnScroll, Date.now.timeIntervalSince(collapseToggled) > 0.4 else { return }
        guard new > 0 else {
            if collapse > 0 { settle(at: 0) }
            return
        }
        let next = min(max(collapse + (new - old) / Self.collapseDistance, 0), 1)
        // A flick covers the whole distance in a frame or two: animate such a jump instead of snapping.
        if abs(next - collapse) > 0.15 {
            withAnimation(Self.settleSpring) { collapse = next }
        } else if next != collapse {
            collapse = next
        }
        // While the finger is down the bar just follows; settling waits for it to lift.
        if browser.selected.isTouching { settleTimer.task?.cancel() } else { scheduleSettle() }
    }

    private func settle(at target: CGFloat) {
        settleTimer.task?.cancel()
        withAnimation(Self.settleSpring) { collapse = target }
        let settled = target == 1
        guard settled != collapsed else { return }
        // The page's inset follows and shifts the scroll position; that shift is not the user scrolling.
        collapseToggled = .now
        withAnimation(.snappy) { collapsed = settled }
    }
}

/// Restarted on every scroll step; as plain @State each restart counted as a change to the page view.
@MainActor private final class SettleTimer {
    var task: Task<Void, Never>?
}

/// Holds every opened tab's WKWebView and shows the selected one. The views stay attached while their
/// tab exists, only hidden, so returning to a tab doesn't make WebKit rebuild its page.
private struct WebHost: UIViewRepresentable {
    let browser: BrowserModel
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .white
        return view
    }

    func makeCoordinator() -> InsetAnimator { InsetAnimator() }

    func updateUIView(_ container: UIView, context: Context) {
        let selected = browser.selected.webView
        container.backgroundColor = browser.selected.pageBackground ?? .white
        let live = Set(browser.tabs.map { ObjectIdentifier($0.webView) })
        for case let webView as WKWebView in container.subviews where !live.contains(ObjectIdentifier(webView)) {
            webView.removeFromSuperview()
        }
        if selected.superview !== container {
            selected.frame = container.bounds
            selected.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(selected)
        }
        for case let webView as WKWebView in container.subviews {
            if webView === selected, webView.isHidden { FrameMeter.mark("web view shown \(webView.url?.host() ?? "-")") }
            webView.isHidden = webView !== selected
            // Not every step of a bar collapse: a hidden page gets its final insets when it is shown.
            if webView !== selected, webView.obscuredContentInsets.top != insets.top { InsetAnimator.apply(insets, to: webView) }
        }
        context.coordinator.move(selected, to: insets)
    }
}

/// Steps the page's insets frame by frame when the bar collapses or expands. Set at once, WebKit
/// re-lays out fixed footers in one jump while the pill is still moving.
final class InsetAnimator {
    private var link: CADisplayLink?
    private weak var webView: WKWebView?
    private var from = UIEdgeInsets.zero
    private var to = UIEdgeInsets.zero
    private var start: CFTimeInterval = 0
    private static let duration: CFTimeInterval = 0.3

    static func apply(_ insets: UIEdgeInsets, to webView: WKWebView) {
        // Obscured insets only shrink WebKit's layout viewport; the scroll view needs the same insets,
        // or a pull down at the top bounces back to zero and leaves the page under the status bar.
        if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets }
        if webView.scrollView.contentInset != insets {
            webView.scrollView.contentInset = insets
            webView.scrollView.verticalScrollIndicatorInsets = insets
        }
    }

    func move(_ webView: WKWebView, to insets: UIEdgeInsets) {
        guard insets != to || self.webView !== webView else { return }
        let current = webView.obscuredContentInsets
        // Only the bottom changes with the bar; a new tab or rotation takes the insets at once.
        // A step of a scroll that the bar follows goes in at once; easing it would trail the bar.
        guard self.webView === webView, current.top == insets.top, current != .zero,
              link != nil || abs(insets.bottom - current.bottom) > 12 else {
            link?.invalidate()
            link = nil
            self.webView = webView
            to = insets
            Self.apply(insets, to: webView)
            return
        }
        from = current
        to = insets
        start = CACurrentMediaTime()
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let webView else { link.invalidate(); self.link = nil; return }
        let t = min(1, (CACurrentMediaTime() - start) / Self.duration)
        let eased = 1 - pow(1 - t, 3)
        var insets = to
        insets.bottom = (from.bottom + (to.bottom - from.bottom) * eased).rounded()
        Self.apply(insets, to: webView)
        if t >= 1 {
            link.invalidate()
            self.link = nil
        }
    }
}

/// Marks a private tab in the bar and the search field; a tint alone looks the same as the dark theme.
/// Outline eyes glancing down-left: the "eyes" symbol has solid whites and reads as the emoji.
struct PrivateMark: View {
    var body: some View {
        HStack(spacing: 1) {
            eye
            eye
        }
        // A concrete colour: the hierarchical `.primary` dims solid fills on glass (the pupils went grey).
        .foregroundStyle(Color(uiColor: .label))
        .accessibilityElement()
        .accessibilityLabel("Private")
    }

    private var eye: some View {
        ZStack(alignment: .bottomLeading) {
            Ellipse().stroke(lineWidth: 1.6)
            Circle().frame(width: 4.5, height: 4.5).offset(x: 2, y: -2.4)
        }
        .frame(width: 10, height: 14)
    }
}

/// A thin line along the bottom of the address field, filling with the page's loading progress and
/// fading out once it finishes.
private struct LoadingLine: View {
    let tab: BrowserTab

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * tab.estimatedProgress, height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(.capsule)
        .opacity(tab.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: tab.estimatedProgress)
        .animation(.easeOut(duration: 0.3), value: tab.isLoading)
        .allowsHitTesting(false)
    }
}

/// Which settings the deck's button opened: all of them, or straight on Workspaces.
enum SettingsSheet: Identifiable {
    case main, workspaces
    var id: Self { self }
}
