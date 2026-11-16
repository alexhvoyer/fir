import XCTest

/// The Smoke section of docs/regression-checklist.md, automated. Run by scripts/ui-tests.sh on its own erased
/// simulator: never signed in, so closing tabs here cannot reach a real Zen account.
@MainActor
final class SmokeTests: XCTestCase {
    private let server = PageServer.shared
    /// A first load on a freshly erased simulator starts WebKit and the content blocker from cold.
    private static let pageLoad: TimeInterval = 30
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - Cases

    /// Open pages, swipe the bar between them, and open one from the card deck.
    func testPagesSwipeAndCards() {
        launch(layout: "deck")
        open("a")
        newTab("b")

        address.swipeRight()
        XCTAssert(page("a").waitForExistence(timeout: 5), "a bar swipe to the right shows the previous tab")
        address.swipeLeft()
        XCTAssert(page("b").waitForExistence(timeout: 5), "a bar swipe to the left comes back")

        showTabs()
        let card = app.descendants(matching: .any).matching(identifier: "deckCard").firstMatch
        XCTAssert(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssert(app.webViews.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Fir test page'")).firstMatch
            .waitForExistence(timeout: 5), "a card opens its page")
    }

    /// Open a tab from a grid cell, then swipe another cell away.
    func testGridOpenAndSwipeToClose() {
        launch(layout: "grid")
        open("c")
        newTab("d")
        showTabs()

        cell("Page c").tap()
        XCTAssert(page("c").waitForExistence(timeout: 5), "a cell opens its page")

        showTabs()
        let closing = cell("Page d")
        XCTAssert(closing.waitForExistence(timeout: 5))
        closing.swipeLeft()
        XCTAssert(closing.waitForNonExistence(timeout: 5), "a cell swiped left closes its tab")
        XCTAssert(cell("Page c").exists, "the other tab stays")
    }

    /// The page menu and Share open and close, and the tabs are still reachable straight after.
    func testPageMenuShareThenTabs() {
        launch(layout: "deck")
        open("e")

        app.buttons["Page Menu"].tap()
        // The menu's own Share: the bar shows one only when it has room.
        let share = app.buttons["pageMenuShare"]
        XCTAssert(share.waitForExistence(timeout: 5), "the page menu opens")
        share.tap()
        // Another process draws it, so the test sees neither its buttons nor its frame; a tap above it closes it.
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssert(shareSheet.waitForExistence(timeout: 5), "Share opens the system share sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssert(shareSheet.waitForNonExistence(timeout: 5), "the share sheet closes")

        app.swipeDown()
        showTabs()
        XCTAssert(waitHittable(overviewNewTab), "nothing is left over the tab overview")
    }

    /// A private tab opens from the tabs button's menu and closes again.
    func testPrivateTab() {
        launch(layout: "grid")
        open("f")

        tabsButton.press(forDuration: 1)
        app.buttons["New Private Tab"].tap()
        type("g")
        XCTAssert(page("g").waitForExistence(timeout: Self.pageLoad), "the private tab loads")

        tabsButton.press(forDuration: 1)
        app.buttons["Close Tab"].tap()
        XCTAssert(page("g").waitForNonExistence(timeout: 5), "the private tab closes")
    }

    /// Settings opens from the tab overview and closes.
    func testSettingsOpenAndClose() {
        launch(layout: "grid")
        open("h")
        showTabs()

        app.buttons["Settings"].firstMatch.tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssert(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
    }

    // MARK: - Helpers

    private var address: XCUIElement { app.descendants(matching: .any)["address"] }
    /// The button inside the menu: after a bar swipe the menu's own element spans the whole glass bar, and a tap
    /// at its centre lands on the address.
    private var tabsButton: XCUIElement { app.buttons["tabs"].buttons.firstMatch }
    private var searchField: XCUIElement { app.textFields["Search or enter address"] }
    /// The overview's own button: the page bar has a New Tab button of its own.
    private var overviewNewTab: XCUIElement { app.buttons["overviewNewTab"] }

    private func page(_ name: String) -> XCUIElement { app.webViews.staticTexts["Fir test page \(name)"] }

    private func cell(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "gridCell")
            .containing(.staticText, identifier: title).firstMatch
    }

    private func launch(layout: String) {
        XCTAssertNotEqual(server.port, 0, "the local page server didn't start")
        app = XCUIApplication()
        app.launchArguments += [
            "-onboardingDone", "YES",
            "-whatsNew", "<false/>",
            "-tabLayout", layout,
        ]
        app.launch()
    }

    /// Opens a test page in the current tab: in the search sheet a blank tab opens with, or from the address bar.
    private func open(_ name: String) {
        if !searchField.waitForExistence(timeout: 3) {
            address.tap()
        }
        type(name)
        XCTAssert(page(name).waitForExistence(timeout: Self.pageLoad), "page \(name) loads")
    }

    private func newTab(_ name: String) {
        showTabs()
        overviewNewTab.tap()
        type(name)
        XCTAssert(page(name).waitForExistence(timeout: Self.pageLoad), "page \(name) loads in a new tab")
    }

    /// Types a page's address into the search field, replacing the selected address it may hold.
    private func type(_ name: String) {
        XCTAssert(searchField.waitForExistence(timeout: 5), "search opens")
        searchField.typeText(XCUIKeyboardKey.delete.rawValue + server.url(name) + "\n")
    }

    /// The overview stays in the tree under the page, so it counts as open only once its button takes taps.
    private func waitHittable(_ element: XCUIElement) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: 5) == .completed
    }

    private func showTabs() {
        XCTAssert(tabsButton.waitForExistence(timeout: 5))
        tabsButton.tap()
        XCTAssert(waitHittable(overviewNewTab), "the tab overview opens")
    }
}
