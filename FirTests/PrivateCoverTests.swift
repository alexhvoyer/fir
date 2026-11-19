import Testing
import WebKit
@testable import Fir

/// iOS keeps the app switcher's screenshot on disk, so the cover must be up whenever something private shows.
@MainActor @Suite struct PrivateCoverTests {
    @Test func coversThePrivateOverviewOverARegularTab() {
        let regular = BrowserTab()
        #expect(BrowserModel.showsPrivate(selected: regular, space: BrowserModel.privateSpace))
        #expect(!BrowserModel.showsPrivate(selected: regular, space: nil))
    }

    @Test func coversAPrivateTab() {
        let privateTab = BrowserTab(spaceID: BrowserModel.privateSpace, dataStore: .nonPersistent())
        #expect(BrowserModel.showsPrivate(selected: privateTab, space: nil))
    }
}
