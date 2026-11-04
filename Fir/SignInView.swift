import SwiftUI
import WebKit

/// Hosts accounts.firefox.com and answers its WebChannel messages, the way Firefox does.
/// Protocol: https://mozilla.github.io/ecosystem-platform/docs/fxa-engineering/fxa-webchannel-protocol
struct SignInView: View {
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    SignInWebView(url: url) { code, state in
                        Task {
                            await account.finishSignIn(code: code, state: state)
                            dismiss()
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Mozilla Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task { url = await account.beginSignIn() }
    }
}

private struct SignInWebView: UIViewRepresentable {
    let url: URL
    let onLogin: @MainActor (_ code: String, _ state: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLogin: onLogin) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A throwaway cookie jar keeps the account page apart from regular browsing.
        config.websiteDataStore = .nonPersistent()
        let bridge = """
            window.addEventListener("WebChannelMessageToChrome", function (e) {
              webkit.messageHandlers.accountsCommandHandler.postMessage({ detail: e.detail });
            });
            """
        config.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: "accountsCommandHandler")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onLogin: @MainActor (String, String) -> Void

        init(onLogin: @escaping @MainActor (String, String) -> Void) {
            self.onLogin = onLogin
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let expected = AccountService.contentServer
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame,
                  origin.protocol == expected.scheme, origin.host == expected.host,
                  let webView = message.webView,
                  let body = message.body as? [String: Any],
                  let detail = Self.object(body["detail"]),
                  let msg = detail["message"] as? [String: Any],
                  let command = msg["command"] as? String
            else { return }

            let id = (msg["messageId"] as? Int) ?? (msg["messageId"] as? String).flatMap(Int.init)
            switch command {
            case "fxaccounts:fxa_status":
                // Offer only the tabs engine, the one this app syncs.
                reply(webView, id: id, command: command,
                      data: #"{"capabilities":{"choose_what_to_sync":true,"engines":["tabs"]}}"#)
            case "fxaccounts:can_link_account":
                reply(webView, id: id, command: command, data: #"{"ok":true}"#)
            case "fxaccounts:oauth_login":
                if let data = msg["data"] as? [String: Any],
                   let code = data["code"] as? String, let state = data["state"] as? String {
                    onLogin(code, state)
                }
            default:
                break
            }
        }

        // The page finishes by navigating to the out-of-band redirect URI; the app takes over instead.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "urn" ? .cancel : .allow
        }

        private func reply(_ webView: WKWebView, id: Int?, command: String, data: String) {
            guard let id else { return }
            let js = """
                window.dispatchEvent(new CustomEvent("WebChannelMessageToContent", { detail: JSON.stringify({
                  id: "account_updates",
                  message: { messageId: \(id), command: "\(command)", data: \(data) }
                }) }));
                """
            webView.evaluateJavaScript(js)
        }

        /// The page sends `detail` either as an object or as a JSON string.
        private static func object(_ value: Any?) -> [String: Any]? {
            if let dict = value as? [String: Any] { return dict }
            guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
