import Foundation
import Testing
import WebKit
@testable import Fir

/// Switching an add-on off for a site has to win over the sites it was granted at install, and switching it
/// back on has to restore them.
@MainActor @Suite final class SiteDenialTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: folder) }

    @Test func denialOutranksAllSites() async throws {
        let context = try await installed(hostPermissions: ["<all_urls>"])
        ExtensionManager.apply(false, on: "example.com", to: context)
        #expect(!context.hasAccess(to: URL(string: "https://example.com/a")!))
        #expect(!context.hasAccess(to: URL(string: "https://www.example.com/")!))
        #expect(context.hasAccess(to: URL(string: "https://other.com/")!))

        ExtensionManager.apply(true, on: "example.com", to: context)
        #expect(context.hasAccess(to: URL(string: "https://example.com/a")!))
    }

    @Test func allowingAgainRestoresAnAskedForSite() async throws {
        let context = try await installed(hostPermissions: ["*://example.com/*"])
        ExtensionManager.apply(false, on: "example.com", to: context)
        #expect(!context.hasAccess(to: URL(string: "https://example.com/a")!))

        ExtensionManager.apply(true, on: "example.com", to: context)
        #expect(context.hasAccess(to: URL(string: "https://example.com/a")!))
    }

    /// As ExtensionManager sets one up at install: every requested site granted.
    private func installed(hostPermissions: [String]) async throws -> WKWebExtensionContext {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0",
                                       "permissions": ["tabs"], "host_permissions": hostPermissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        return context
    }
}
