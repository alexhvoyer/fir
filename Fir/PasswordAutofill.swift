import MozillaAppServices
import SwiftUI
import WebKit

/// Finds sign-in forms in pages, offers saved logins over the keyboard, and asks to save new ones.
/// The page script runs in its own content world, so a page can neither call the handler nor read
/// it; the origin always comes from WebKit's frame info, never from the page.
@MainActor
@Observable
final class PasswordAutofill: NSObject {
    static let shared = PasswordAutofill()

    struct FillOffer {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let host: String
        let logins: [Login]
    }

    struct SavePrompt: Identifiable {
        let id = UUID()
        let origin: String
        let username: String
        let password: String
        /// Set when the username is saved with another password: the prompt offers an update.
        let existing: Login?
    }

    private(set) var offer: FillOffer?
    var savePrompt: SavePrompt?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// The last submit already handled per origin, so a form posting twice asks once.
    @ObservationIgnored private var handled: [String: String] = [:]

    private static let world = WKContentWorld.world(name: "ZenLogins")
    private static let handlerName = "zenLogins"

    /// Called once per web view configuration; popups share their opener's and must not add it again.
    func attach(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(Self.script)
    }

    /// Fills the chosen login into the frame that asked, after Face ID or the passcode.
    func fill(_ login: Login) async {
        guard let offer, let webView = offer.webView else { return }
        if AppLock.isAvailable, !(await AppLock.authenticate(reason: "Fill your password")) { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__zenFill(username, password)",
            arguments: ["username": login.username, "password": login.password],
            in: offer.frame, contentWorld: Self.world
        )
        self.offer = nil
        Task.detached { PasswordStore.shared?.touch(login) }
    }

    func save(_ prompt: SavePrompt) async {
        await Task.detached {
            if let existing = prompt.existing {
                PasswordStore.shared?.updatePassword(existing, to: prompt.password)
            } else {
                PasswordStore.shared?.add(origin: prompt.origin, formActionOrigin: nil,
                                          username: prompt.username, password: prompt.password)
            }
        }.value
    }

    // MARK: - Messages

    private func received(_ body: [String: Any], frame: WKFrameInfo, webView: WKWebView?) {
        let security = frame.securityOrigin
        guard ["https", "http"].contains(security.protocol), !security.host.isEmpty else { return }
        let origin = security.port == 0 || security.port == (security.protocol == "https" ? 443 : 80)
            ? "\(security.protocol)://\(security.host)"
            : "\(security.protocol)://\(security.host):\(security.port)"
        switch body["type"] as? String {
        case "focus":
            hideTask?.cancel()
            Task {
                let logins = await Task.detached { PasswordStore.shared?.logins(for: origin) ?? [] }.value
                offer = logins.isEmpty ? nil : FillOffer(webView: webView, frame: frame, host: security.host, logins: logins)
            }
        case "blur":
            // A moment's grace: focus moving to the next field of the same form shouldn't flicker the bar.
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                offer = nil
            }
        case "submit":
            // Private tabs keep nothing, passwords included.
            guard webView?.configuration.websiteDataStore.isPersistent == true,
                  let password = body["password"] as? String, !password.isEmpty else { return }
            let username = body["username"] as? String ?? ""
            let fingerprint = "\(username)\u{0}\(password)"
            guard handled[origin] != fingerprint else { return }
            handled[origin] = fingerprint
            Task {
                let logins = await Task.detached { PasswordStore.shared?.logins(for: origin) ?? [] }.value
                let sameUser = logins.first { $0.username == username }
                if sameUser?.password == password { return }
                savePrompt = SavePrompt(origin: origin, username: username, password: password, existing: sameUser)
            }
        default:
            break
        }
    }

    // MARK: - Page script

    /// Watches focus on sign-in fields and form submits; `__zenFill` fills the last focused form.
    static let script = WKUserScript(source: """
        (() => {
          if (window.__zenFill) return;
          const post = (m) => window.webkit.messageHandlers.zenLogins.postMessage(m);
          const textTypes = ['text', 'email', 'tel', ''];
          const visible = (el) => el.getClientRects().length > 0;
          const isPassword = (el) => el instanceof HTMLInputElement && el.type === 'password';
          const isText = (el) => el instanceof HTMLInputElement && textTypes.includes(el.type);
          const inputsOf = (el) => [...(el.form || document).querySelectorAll('input')].filter(visible);
          const usernameFor = (pw) => {
            const inputs = inputsOf(pw);
            for (let i = inputs.indexOf(pw) - 1; i >= 0; i--) if (isText(inputs[i])) return inputs[i];
            return null;
          };
          const passwordFor = (field) => {
            const inputs = inputsOf(field);
            return inputs.slice(inputs.indexOf(field) + 1).find(isPassword) || null;
          };
          const isUsername = (el) => isText(el) &&
            (passwordFor(el) !== null || /username|email/.test(el.autocomplete || ''));
          let focused = null;
          document.addEventListener('focusin', (e) => {
            const el = e.target;
            if (isPassword(el) || isUsername(el)) { focused = el; post({ type: 'focus' }); }
          }, true);
          document.addEventListener('focusout', (e) => {
            if (e.target === focused) post({ type: 'blur' });
          }, true);
          const set = (el, value) => {
            if (!el) return;
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          window.__zenFill = (username, password) => {
            const el = focused && focused.isConnected ? focused : document.querySelector('input[type=password]');
            if (!el) return;
            const pw = isPassword(el) ? el : passwordFor(el);
            const user = isPassword(el) ? usernameFor(el) : el;
            set(user, username);
            set(pw, password);
          };
          const capture = (scope) => {
            const pw = [...(scope || document).querySelectorAll('input[type=password]')].find((p) => p.value);
            if (!pw) return;
            const user = usernameFor(pw);
            post({ type: 'submit', username: user ? user.value : '', password: pw.value });
          };
          document.addEventListener('submit', (e) => capture(e.target), true);
          document.addEventListener('click', (e) => {
            const button = e.target.closest && e.target.closest('button, input[type=submit]');
            if (button) capture(button.form || document);
          }, true);
          document.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && e.target instanceof HTMLInputElement) capture(e.target.form || document);
          }, true);
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
}

extension PasswordAutofill: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            received(body, frame: message.frameInfo, webView: message.webView)
        }
    }
}

/// Over the keyboard while a sign-in field of a site with saved logins is focused.
struct PasswordFillBar: View {
    let autofill: PasswordAutofill
    let webView: WKWebView

    var body: some View {
        if let offer = autofill.offer, offer.webView === webView, let first = offer.logins.first {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                Button { Task { await autofill.fill(first) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.username.isEmpty ? "Saved password" : first.username).lineLimit(1)
                        Text(offer.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if offer.logins.count > 1 {
                    Menu {
                        ForEach(offer.logins, id: \.id) { login in
                            Button(login.username.isEmpty ? "Saved password" : login.username) {
                                Task { await autofill.fill(login) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").frame(width: 36, height: 36)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
