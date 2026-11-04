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
        enum State { case running, finished, failed }
    }

    /// This session's downloads, newest first; finished ones also stay in the folder.
    private(set) var active: [Item] = []
    @ObservationIgnored private var items: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

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
        let item = Item(name: download.originalRequest?.url?.lastPathComponent ?? "Download")
        items[key] = item.id
        active.insert(item, at: 0)
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
        if item != active[index] { active[index] = item }
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

