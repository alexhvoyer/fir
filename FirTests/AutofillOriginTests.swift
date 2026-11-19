import Testing
import WebKit
@testable import Fir

/// A saved login goes only into the origin it was offered for, whatever page the frame holds by the fill.
@MainActor @Suite struct AutofillOriginTests {
    private static let form = #"<form><input id="u" type="text"><input id="p" type="password"></form>"#

    @Test func fillsTheOfferedOrigin() async throws {
        let webView = try await page(at: "https://a.test")
        await PasswordAutofill.fill(username: "me", password: "secret", origin: "https://a.test", in: webView, frame: nil)
        #expect(try await value(of: "u", in: webView) == "me")
        #expect(try await value(of: "p", in: webView) == "secret")
    }

    @Test func skipsAnotherOrigin() async throws {
        let webView = try await page(at: "https://b.test")
        await PasswordAutofill.fill(username: "me", password: "secret", origin: "https://a.test", in: webView, frame: nil)
        #expect(try await value(of: "u", in: webView) == "")
        #expect(try await value(of: "p", in: webView) == "")
    }

    private func page(at origin: String) async throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        webView.configuration.userContentController.addUserScript(PasswordAutofill.script)
        webView.loadHTMLString(Self.form, baseURL: URL(string: origin))
        for _ in 0..<100 {
            if !webView.isLoading, try await webView.evaluateJavaScript("document.readyState") as? String == "complete" {
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PageNotLoaded()
    }

    private struct PageNotLoaded: Error {}

    private func value(of id: String, in webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript("document.getElementById('\(id)').value") as? String
    }
}
