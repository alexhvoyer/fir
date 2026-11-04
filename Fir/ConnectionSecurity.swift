import Security
import SwiftUI
import WebKit

/// What the page sheet shows about the page's connection: whether it is encrypted, and the
/// certificate WebKit accepted for it, as Lens and Yab show it.
struct ConnectionSecurityView: View {
    let tab: BrowserTab
    @State private var report: ConnectionReport?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let report {
                Section { summary(report) }
                    .listRowBackground(Color.clear)
                if !report.chain.isEmpty {
                    Section("Certificate") {
                        ForEach(Self.details(of: report), id: \.0) { label, value in
                            LabeledContent(label, value: value)
                        }
                        HStack {
                            Text("Status")
                            Spacer()
                            Label(report.valid ? "Valid" : "Not Trusted",
                                  systemImage: report.valid ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(report.valid ? .green : .red)
                        }
                    }
                    Section("Certificate Chain") {
                        ForEach(Array(report.chain.enumerated()), id: \.offset) { index, cert in
                            LabeledContent {
                                Text(Self.role(index, of: report.chain.count))
                            } label: {
                                Label(cert.name, systemImage: index == 0 ? "globe" : "checkmark.shield")
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        // Its own header, not the navigation bar, so the back button leaves with the page on a swipe back.
        // A bar, not an inset: the system fades the list scrolling under it.
        .safeAreaBar(edge: .top) { header }
        .toolbar(.hidden, for: .navigationBar)
        .task { report = await ConnectionReport.make(for: tab) }
    }

    private var header: some View {
        ZStack {
            Text("Connection Security").font(.headline)
            HStack {
                Button("Back", systemImage: "chevron.left") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func summary(_ report: ConnectionReport) -> some View {
        VStack(spacing: 10) {
            Image(systemName: report.secure ? "lock.fill" : "lock.open.fill")
                .font(.title)
                .foregroundStyle(report.secure ? .green : .red)
                .frame(width: 64, height: 64)
                .background((report.secure ? Color.green : Color.red).opacity(0.18), in: .circle)
            Text(report.secure ? "Connection Is Secure" : "Connection Is Not Secure").font(.headline)
            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// The certificate's facts that the site has; optional ones are left out rather than blank.
    private static func details(of report: ConnectionReport) -> [(String, String)] {
        guard let site = report.chain.first else { return [] }
        var rows = [("Issued To", site.name)]
        if let organization = site.organization { rows.append(("Organization", organization)) }
        if report.chain.count > 1 { rows.append(("Issued By", report.chain[1].name)) }
        if let expires = site.expires {
            rows.append(("Expires", expires.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }

    private static func role(_ index: Int, of count: Int) -> String {
        index == 0 ? "Website" : index == count - 1 ? "Root" : "Intermediate"
    }
}

/// The connection as WebKit saw it, read once when the screen opens.
struct ConnectionReport {
    struct Certificate {
        let name: String
        let organization: String?
        let expires: Date?
    }

    let host: String
    let secure: Bool
    /// Some of the page's resources came over plain HTTP.
    let mixed: Bool
    let valid: Bool
    /// The site's certificate first, the root last.
    let chain: [Certificate]

    var summary: String {
        if !secure {
            return "Your connection to \(host) isn't encrypted. Don't enter passwords or card numbers here."
        }
        if mixed {
            return "Your connection to \(host) is encrypted, but some of this page's content isn't."
        }
        return "Your connection to \(host) is encrypted. What you send stays private on the way there."
    }

    @MainActor
    static func make(for tab: BrowserTab) async -> ConnectionReport {
        // The committed address: webView.url can be a load still pending, while serverTrust is the page shown.
        let webView = tab.webView
        let host = tab.pageURL?.host() ?? ""
        let mixed = !webView.hasOnlySecureContent
        guard tab.pageURL?.scheme == "https", let trust = webView.serverTrust else {
            return ConnectionReport(host: host, secure: false, mixed: mixed, valid: false, chain: [])
        }
        // Evaluation can reach the network for revocation, so it stays off the main thread.
        nonisolated(unsafe) let sendable = trust
        let (valid, chain) = await Task.detached {
            let valid = SecTrustEvaluateWithError(sendable, nil)
            let certificates = SecTrustCopyCertificateChain(sendable) as? [SecCertificate] ?? []
            return (valid, certificates.map(Certificate.init))
        }.value
        return ConnectionReport(host: host, secure: true, mixed: mixed, valid: valid, chain: chain)
    }
}

extension ConnectionReport.Certificate {
    init(_ certificate: SecCertificate) {
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        name = (commonName as String?) ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unknown"
        organization = DER.subjectOrganization(SecCertificateCopyData(certificate) as Data)
        expires = SecCertificateCopyNotValidAfterDate(certificate) as Date?
    }
}

/// Just enough DER to read a certificate's subject organization, which iOS has no API for.
private enum DER {
    /// The organizationName attribute, 2.5.4.10.
    private static let organizationOID: [UInt8] = [0x55, 0x04, 0x0A]

    static func subjectOrganization(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        // Certificate > tbsCertificate > [version], serial, signature, issuer, validity, subject.
        guard let certificate = element(bytes, at: 0),
              let tbs = element(bytes, at: certificate.content) else { return nil }
        var fields: [Element] = []
        var offset = tbs.content
        while offset < tbs.end, let field = element(bytes, at: offset) {
            fields.append(field)
            offset = field.end
        }
        let skip = bytes[tbs.content] == 0xA0 ? 1 : 0
        guard fields.count > skip + 4 else { return nil }
        return organization(bytes, in: fields[skip + 4])
    }

    private struct Element {
        let content: Int
        let end: Int
    }

    private static func element(_ bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 1 < bytes.count else { return nil }
        var length = Int(bytes[offset + 1])
        var content = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, content + count <= bytes.count else { return nil }
            length = bytes[content..<content + count].reduce(0) { $0 << 8 | Int($1) }
            content += count
        }
        guard content + length <= bytes.count else { return nil }
        return Element(content: content, end: content + length)
    }

    /// A Name is SEQUENCE OF SET OF { OID, value }; returns the organization's value.
    private static func organization(_ bytes: [UInt8], in name: Element) -> String? {
        var offset = name.content
        while offset < name.end, let set = element(bytes, at: offset) {
            if let pair = element(bytes, at: set.content),
               let oid = element(bytes, at: pair.content),
               Array(bytes[oid.content..<oid.end]) == organizationOID,
               let value = element(bytes, at: oid.end) {
                return String(bytes: bytes[value.content..<value.end], encoding: .utf8)
            }
            offset = set.end
        }
        return nil
    }
}

/// Turns the swipe back on in a navigation stack whose bar is hidden: UIKit's own gesture delegate
/// refuses it then. Put in the stack's root page.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ host: Host, context: Context) {}

    final class Host: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let navigation = navigationController else { return }
            navigation.interactivePopGestureRecognizer?.delegate = self
            navigation.interactiveContentPopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
