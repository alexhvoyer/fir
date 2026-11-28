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

    /// Nothing private survives Fir being killed: no private tab in either overview section, and its page
    /// not in History.
    func testPrivateTabGoneAfterRelaunch() {
        launch(layout: "grid")
        open("q")
        tabsButton.press(forDuration: 1)
        app.buttons["New Private Tab"].tap()
        type("r")
        XCTAssert(page("r").waitForExistence(timeout: Self.pageLoad), "the private tab loads")

        app.terminate()
        launch(layout: "grid")
        XCTAssertFalse(page("r").waitForExistence(timeout: 3), "the private page is not on screen")
        showTabs()
        XCTAssert(cell("Page q").waitForExistence(timeout: 5), "the regular tab is back")
        XCTAssertFalse(cell("Page r").exists, "no private tab among the regular ones")
        // The workspace switcher draws its labels as text under one gesture, not as buttons.
        app.staticTexts["Private"].firstMatch.tap()
        XCTAssertFalse(cell("Page r").waitForExistence(timeout: 2), "no private tab in Private")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings opens")
        app.staticTexts["History"].firstMatch.tap()
        // A row is one button whose label joins the title and the host.
        let row = { (title: String) in
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        }
        XCTAssert(row("Page q").waitForExistence(timeout: 5), "History lists the regular page")
        XCTAssertFalse(row("Page r").exists, "and not the private one")
    }

    /// In start-page mode the address is edited in the bar, with no sheet: the keyboard comes up, a page
    /// opens in the same tab, and Cancel puts the bar back.
    func testStartPageSearchInBar() {
        launch(layout: "grid", newTab: "page")
        open("i")
        let tabs = tabsButton.value as? String

        address.tap()
        XCTAssert(searchField.waitForExistence(timeout: 5), "the field takes the bar's place")
        XCTAssert(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard comes up")
        type("j")
        XCTAssert(page("j").waitForExistence(timeout: Self.pageLoad), "the page loads")
        XCTAssertEqual(tabsButton.value as? String, tabs, "it loads in the same tab")

        address.tap()
        XCTAssert(searchField.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssert(searchField.waitForNonExistence(timeout: 5), "Cancel ends the search")
        XCTAssert(page("j").exists, "the page stays")
    }

    /// Paste and Go in a blank tab's bar opens what was copied: a tap gesture on the capsule once took its touch.
    func testPasteAndGoInBar() {
        UIPasteboard.general.string = server.url("p")
        launch(layout: "cards", newTab: "page")
        // Tests share app data: an earlier one leaves a page in front, and only a blank tab's bar has the button.
        showTabs()
        overviewNewTab.tap()
        let paste = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Paste'")).firstMatch
        XCTAssert(paste.waitForExistence(timeout: 5), "the bar offers Paste and Go")
        paste.tap()
        XCTAssert(page("p").waitForExistence(timeout: Self.pageLoad), "the copied address opens")
    }

    /// Undo brings back a closed blank tab. With nothing in Recently Closed, that crashed: tests share app data,
    /// so the list is emptied by a launch argument.
    func testUndoCloseBlankTab() {
        launch(layout: "grid", newTab: "page", extra: ["-recentlyClosedTabs", ""])
        showTabs()
        overviewNewTab.tap()
        showTabs()
        let blanks = app.descendants(matching: .any).matching(identifier: "gridCell")
            .containing(.staticText, identifier: "New Tab")
        let count = blanks.count
        XCTAssertGreaterThan(count, 0)
        blanks.element(boundBy: count - 1).buttons["Close Tab"].tap()
        let undo = app.buttons["Undo Close Tab"]
        XCTAssert(undo.waitForExistence(timeout: 2), "closing offers Undo")
        undo.tap()
        XCTAssertEqual(app.state, .runningForeground, "Fir is still running after Undo")
        XCTAssert(waitHittable(overviewNewTab), "the overview is still up")
        XCTAssertEqual(blanks.count, count, "the blank tab is back")
    }

    /// Quick closes from the grid, and Undo while the cell is still leaving: it used to come back off screen
    /// with a dead close button.
    func testGridQuickClosesAndEarlyUndo() {
        launch(layout: "grid")
        // A closed cell's followers slide up, under a tap already aimed at them. So o goes early and stays
        // selected, and the closes run from the last cell back. k stays, so no close empties the workspace.
        open("k")
        newTab("o")
        newTab("m")
        newTab("n")
        showTabs()
        cell("Page o").tap()
        showTabs()
        let cells = app.descendants(matching: .any).matching(identifier: "gridCell")
        let before = cells.count
        cell("Page n").buttons["Close Tab"].tap()
        cell("Page m").buttons["Close Tab"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before - 2), object: cells)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "two quick closes close two tabs")

        cell("Page o").buttons["Close Tab"].tap()
        app.buttons["Undo Close Tab"].tap()
        XCTAssert(waitHittable(cell("Page o").buttons["Close Tab"]), "an early Undo puts the cell back on screen")
        cell("Page o").buttons["Close Tab"].tap()
        XCTAssert(cell("Page o").waitForNonExistence(timeout: 5), "it closes again after Undo")

        // The same with a swipe, which leaves the cell where the finger let go of it.
        app.buttons["Undo Close Tab"].tap()
        XCTAssert(waitHittable(cell("Page o").buttons["Close Tab"]))
        sleep(1)
        let home = cell("Page o").frame.minX
        cell("Page o").swipeLeft()
        app.buttons["Undo Close Tab"].tap()
        XCTAssert(waitHittable(cell("Page o").buttons["Close Tab"]), "an early Undo after a swipe puts the cell back")
        sleep(1)
        XCTAssertEqual(cell("Page o").frame.minX, home, accuracy: 2, "in its own place, not where the swipe left it")
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

    private func launch(layout: String, newTab: String = "sheet", extra: [String] = []) {
        XCTAssertNotEqual(server.port, 0, "the local page server didn't start")
        app = XCUIApplication()
        app.launchArguments += [
            "-onboardingDone", "YES",
            "-whatsNew", "<false/>",
            "-tabLayout", layout,
            "-newTabStyle", newTab,
        ] + extra
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
