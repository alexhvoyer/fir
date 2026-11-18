import SwiftUI
import MozillaAppServices

struct ShareView: View {
    @Bindable var model: ShareModel
    let open: (URL) -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let page = model.page {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = model.title { Text(title).lineLimit(2) }
                            Text(page.host() ?? page.absoluteString)
                                .font(model.title == nil ? .body : .footnote)
                                .foregroundStyle(model.title == nil ? .primary : .secondary)
                        }
                        Button { open(page) } label: { Label("Open in Fir", systemImage: "arrow.up.forward.app") }
                    }
                    Section("Send to Device") { devices }
                }
            }
            .overlay {
                if !model.loaded {
                    ProgressView()
                } else if model.page == nil {
                    ContentUnavailableView("No Link", systemImage: "link",
                                           description: Text("Fir opens and sends web links only."))
                }
            }
            .navigationTitle("Fir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel, action: close) }
            }
            .alert("Couldn't Send the Tab", isPresented: $model.sendFailed) {} message: {
                Text("Check the connection and try again.")
            }
        }
    }

    @ViewBuilder private var devices: some View {
        switch model.devices {
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .signedOut:
            Text("Sign in to your Mozilla account in Fir to send links to your other devices.").foregroundStyle(.secondary)
        case .failed:
            Text("Couldn't load your devices. Check the connection.").foregroundStyle(.secondary)
        case .list(let list) where list.isEmpty:
            Text("Sign in to Zen or Firefox on another device to send links there.").foregroundStyle(.secondary)
        case .list(let list):
            ForEach(list, id: \.id) { device in
                Button {
                    Task {
                        // The tick shows a moment before the sheet goes.
                        if await model.send(to: device) {
                            try? await Task.sleep(for: .seconds(0.6))
                            close()
                        }
                    }
                } label: {
                    HStack {
                        Label(MozillaAccount.shortDeviceName(device.displayName), systemImage: Self.symbol(device.deviceType))
                        Spacer()
                        if model.sending == device.id {
                            ProgressView()
                        } else if model.sent == device.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                .accessibilityLabel("Sent")
                        }
                    }
                }
                .disabled(model.sending != nil || model.sent != nil)
            }
        }
    }

    private static func symbol(_ type: DeviceType) -> String {
        switch type {
        case .mobile: "iphone"
        case .tablet: "ipad"
        case .tv: "tv"
        case .vr: "visionpro"
        default: "laptopcomputer"
        }
    }
}
