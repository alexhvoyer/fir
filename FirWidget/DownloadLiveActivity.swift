import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadAttributes.self) { context in
            let state = shown(context)
            HStack(spacing: 12) {
                symbol(state).font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(state)).font(.headline).lineLimit(1)
                    if state.phase == .running { ProgressView(value: state.progress) }
                }
            }
            .padding()
        } dynamicIsland: { context in
            let state = shown(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { symbol(state).font(.title2) }
                DynamicIslandExpandedRegion(.center) { Text(title(state)).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase == .running { ProgressView(value: state.progress) }
                }
            } compactLeading: {
                symbol(state)
            } compactTrailing: {
                ring(state)
            } minimal: {
                ring(state)
            }
        }
    }

    /// A running download with no news for a minute: iOS has suspended the app and it isn't moving.
    private func shown(_ context: ActivityViewContext<DownloadAttributes>) -> DownloadAttributes.ContentState {
        var state = context.state
        if context.isStale, state.phase == .running { state.phase = .paused }
        return state
    }

    private func title(_ state: DownloadAttributes.ContentState) -> String {
        switch state.phase {
        case .running: state.count > 1 ? "\(state.count) downloads" : "Downloading"
        case .paused: "Open Fir to continue"
        case .finished: "Download finished"
        case .failed: "Download failed"
        }
    }

    private func symbol(_ state: DownloadAttributes.ContentState) -> some View {
        let name = switch state.phase {
        case .running: "arrow.down.circle"
        case .paused: "pause.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
        return Image(systemName: name)
            .foregroundStyle(state.phase == .failed ? Color.red : Palette.teal)
    }

    @ViewBuilder private func ring(_ state: DownloadAttributes.ContentState) -> some View {
        if state.phase == .running {
            ProgressView(value: state.progress).progressViewStyle(.circular).tint(Palette.teal)
        } else {
            symbol(state)
        }
    }
}
