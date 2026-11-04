import SwiftUI
import WidgetKit

/// Home and Lock Screen widgets that open Fir straight into search.
@main
struct FirWidgets: WidgetBundle {
    var body: some Widget {
        SearchWidget()
    }
}

struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        // The app's first name: a new kind would drop the widgets already placed.
        StaticConfiguration(kind: "dev.khvoynitsky.ZenTabs.search", provider: Provider()) { _ in
            SearchWidgetView()
        }
        .configurationDisplayName("Search")
        .description("Start a search in Fir.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

/// Nothing changes over time, so a single entry that never refreshes.
struct Provider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

struct SearchWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "magnifyingglass").font(.title2.weight(.semibold))
                }
            case .systemMedium:
                VStack(alignment: .leading) {
                    SprigMark().frame(width: 34, height: 34)
                    Spacer()
                    searchCapsule(label: "Search or enter address")
                }
            default:
                VStack(alignment: .leading) {
                    SprigMark().frame(width: 40, height: 40)
                    Spacer()
                    searchCapsule(label: "Search")
                }
            }
        }
        .widgetURL(URL(string: "firbrowser://search"))
        .containerBackground(for: .widget) {
            Palette.field
        }
    }

    private func searchCapsule(label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            Text(label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.subheadline.weight(.medium))
        // System styles: the field is snow in light mode, where white text vanished.
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.fill.secondary, in: .capsule)
    }
}
