import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadAttributes.self) { context in
            HStack(spacing: 12) {
                symbol(context.state).font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(context.state)).font(.headline).lineLimit(1)
                    if context.state.phase == .running { ProgressView(value: context.state.progress) }
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { symbol(context.state).font(.title2) }
                DynamicIslandExpandedRegion(.center) { Text(title(context.state)).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .running { ProgressView(value: context.state.progress) }
                }
            } compactLeading: {
                symbol(context.state)
            } compactTrailing: {
                ring(context.state)
            } minimal: {
                ring(context.state)
            }
        }
    }

    private func title(_ state: DownloadAttributes.ContentState) -> String {
        switch state.phase {
        case .running: state.count > 1 ? "\(state.count) downloads" : state.name
        case .finished: state.name
        case .failed: "Download failed"
        }
    }

    private func symbol(_ state: DownloadAttributes.ContentState) -> some View {
        let name = switch state.phase {
        case .running: "arrow.down.circle"
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
