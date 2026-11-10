import ActivityKit
import QuickLook
import SwiftUI
import WebKit

/// Files pages hand over instead of showing. They land in Documents/Downloads, which the Files app
/// shows under On My iPhone › Fir.
@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var file: URL?
        var progress = 0.0
        var state = State.running
        /// False for a private tab's file: its name must not appear on the Lock Screen.
        var showsActivity = true
        enum State { case running, finished, failed }
    }

    /// This session's downloads, newest first; finished ones also stay in the folder.
    private(set) var active: [Item] = []
    @ObservationIgnored private var items: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var activity: Activity<DownloadAttributes>?
    @ObservationIgnored private var activityUpdated = Date.distantPast

    private override init() {
        super.init()
        // One left by a launch that ended mid-download would otherwise stay up for hours.
        Task { for leftover in Activity<DownloadAttributes>.activities { await leftover.end(nil, dismissalPolicy: .immediate) } }
    }

    static var folder: URL {
        let dir = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Everything in the folder, newest first.
    var files: [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return urls.sorted { date($0) > date($1) }
    }

    func track(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        var item = Item(name: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.showsActivity = download.webView?.configuration.websiteDataStore.isPersistent == true
        items[key] = item.id
        active.insert(item, at: 0)
        refreshActivity()
        download.delegate = self
        progressObservations[key] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            // Whole percents: the fraction moves on every received chunk, and each write redrew the bar.
            let fraction = (progress.fractionCompleted * 100).rounded(.down) / 100
            Task { @MainActor in self?.update(key) { $0.progress = fraction } }
        }
    }

    func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        active.removeAll { $0.file == file }
    }

    private func update(_ key: ObjectIdentifier, _ change: (inout Item) -> Void) {
        guard let id = items[key], let index = active.firstIndex(where: { $0.id == id }) else { return }
        var item = active[index]
        change(&item)
        if item != active[index] {
            active[index] = item
            refreshActivity()
        }
    }

    /// One activity for all downloads. Updates at most once a second: the system throttles faster ones.
    private func refreshActivity() {
        let shown = active.filter(\.showsActivity)
        let running = shown.filter { $0.state == .running }
        if let newest = running.first {
            let progress = running.map(\.progress).reduce(0, +) / Double(running.count)
            let state = DownloadAttributes.ContentState(name: newest.name, progress: progress, count: running.count, phase: .running)
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity {
                guard Date.now.timeIntervalSince(activityUpdated) >= 1 else { return }
                activityUpdated = .now
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(attributes: DownloadAttributes(), content: content)
                activityUpdated = .now
            }
        } else if let activity, let last = shown.first {
            self.activity = nil
            let state = DownloadAttributes.ContentState(name: last.name, progress: 1, count: 0,
                                                        phase: last.state == .failed ? .failed : .finished)
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
        }
    }

    private func finish(_ download: WKDownload, _ state: Item.State) {
        let key = ObjectIdentifier(download)
        update(key) { $0.state = state; $0.progress = 1 }
        progressObservations[key] = nil
        items[key] = nil
    }

    /// "report.pdf", then "report 2.pdf" and so on, so nothing is overwritten.
    private static func freeName(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                              suggestedFilename: String) async -> URL? {
        await MainActor.run {
            let file = Self.freeName(suggestedFilename.isEmpty ? "Download" : suggestedFilename)
            update(ObjectIdentifier(download)) { $0.name = file.lastPathComponent; $0.file = file }
            return file
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in finish(download, .finished) }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        Task { @MainActor in finish(download, .failed) }
    }
}

/// Settings › Downloads: what is in the folder, plus anything still coming in.
struct DownloadsView: View {
    private var manager: DownloadManager { .shared }
    @State private var preview: URL?
    @State private var files: [URL] = []

    var body: some View {
        List {
            let running = manager.active.filter { $0.state != .finished }
            if !running.isEmpty {
                Section {
                    ForEach(running) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).lineLimit(1)
                            if item.state == .failed {
                                Text("Failed").font(.caption).foregroundStyle(.red)
                            } else {
                                ProgressView(value: item.progress)
                            }
                        }
                    }
                }
            }
            Section {
                if files.isEmpty {
                    Text("Files you download appear here and in the Files app, under On My iPhone › Fir.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { file in
                    Button { preview = file } label: {
                        Label(file.lastPathComponent, systemImage: "doc")
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .contextMenu {
                        ShareLink(item: file)
                        Button("Delete", systemImage: "trash", role: .destructive) { remove(file) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { remove(file) } }
                }
            }
        }
        .navigationTitle("Downloads")
        .quickLookPreview($preview, in: files)
        .onAppear { files = manager.files }
        .onChange(of: manager.active.map(\.state)) { files = manager.files }
    }

    private func remove(_ file: URL) {
        manager.delete(file)
        files = manager.files
    }
}

