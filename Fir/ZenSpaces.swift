import SwiftUI

/// Zen's synced sidebar, decoded from the "spaces" collection (see zen-browser/desktop
/// src/zen/sync/ZenSpacesSyncModel.sys.mjs). Zen syncs pinned and folder tabs only.
struct ZenWorkspaces {
    struct Tab: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL?
    }

    struct Folder: Identifiable {
        let id: String
        let name: String
        let tabs: [Tab]
    }

    struct Space: Identifiable {
        let id: String
        let name: String
        let icon: String?
        let color: Color?
        let tabs: [Tab]
        let folders: [Folder]
        /// The container whose essentials Zen shows in this space.
        let container: String
    }

    let spaces: [Space]
    /// Zen keeps essentials per container, and a space shows only its own container's.
    private let essentialsByContainer: [String: [Tab]]

    /// A space's essentials; outside any space, the default container's.
    func essentials(in space: Space?) -> [Tab] {
        essentialsByContainer[space?.container ?? Self.defaultContainer] ?? []
    }

    static let defaultContainer = "default"

    init(records: [[String: Any]]) {
        var byId: [String: (kind: String, data: [String: Any])] = [:]
        for record in records where record["deleted"] as? Bool != true {
            guard let id = record["id"] as? String, let kind = record["kind"] as? String,
                  let data = record["data"] as? [String: Any] else { continue }
            byId[id] = (kind, data)
        }

        func tab(_ id: String) -> Tab? {
            guard let entry = byId[id], entry.kind == "tab" else { return nil }
            let data = entry.data
            let title = (data["staticLabel"] as? String) ?? (data["title"] as? String) ?? ""
            return Tab(id: id, title: title, url: (data["url"] as? String).flatMap(URL.init(string:)))
        }

        /// Tabs under a child id, flattening splits and nested folders.
        func tabs(under id: String, depth: Int = 0) -> [Tab] {
            guard depth < 8, let entry = byId[id] else { return [] }
            switch entry.kind {
            case "tab": return tab(id).map { [$0] } ?? []
            case "split": return (entry.data["tabs"] as? [String] ?? []).compactMap(tab)
            case "folder":
                return (entry.data["children"] as? [String] ?? []).flatMap { tabs(under: $0, depth: depth + 1) }
            default: return []
            }
        }

        let layout = byId["layout"]?.data
        let order = layout?["spaces"] as? [String]
            ?? byId.filter { $0.value.kind == "space" }.map(\.key).sorted()

        spaces = order.compactMap { uuid in
            guard let data = byId[uuid]?.data else { return nil }
            var looseTabs: [Tab] = []
            var folders: [Folder] = []
            // `children` gives the order but Zen leaves it empty for pinned tabs, so also
            // collect top-level items that point at this space through workspaceUuid.
            let ordered = data["children"] as? [String] ?? []
            let pointing = byId
                .filter { id, entry in
                    entry.data["workspaceUuid"] as? String == uuid
                        && entry.data["folderId"] as? String == nil
                        && entry.data["parentFolderId"] as? String == nil
                        && entry.data["essential"] as? Bool != true
                        && !ordered.contains(id)
                }
                .map(\.key)
                .sorted()
            for child in ordered + pointing {
                if byId[child]?.kind == "folder" {
                    let name = byId[child]?.data["name"] as? String ?? "Folder"
                    folders.append(Folder(id: child, name: name, tabs: tabs(under: child)))
                } else {
                    looseTabs += tabs(under: child)
                }
            }
            return Space(
                id: uuid,
                name: (data["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space",
                icon: Self.emojiIcon(data["icon"]),
                color: Self.themeColor(data["theme"]),
                tabs: looseTabs,
                folders: folders,
                container: data["containerGuid"] as? String ?? Self.defaultContainer
            )
        }

        let essentialIds = layout?["essentials"] as? [String: [String]] ?? [:]
        essentialsByContainer = essentialIds.mapValues { $0.compactMap(tab) }
    }

    /// Zen stores either an emoji or a chrome:// icon path; only the emoji is usable here.
    private static func emojiIcon(_ value: Any?) -> String? {
        guard let icon = value as? String, !icon.isEmpty, !icon.contains("/") else { return nil }
        return icon
    }

    /// First gradient stop, stored as `{ c: [r, g, b] }` in 0...255.
    private static func themeColor(_ value: Any?) -> Color? {
        guard let theme = value as? [String: Any],
              let first = (theme["gradientColors"] as? [[String: Any]])?.first,
              let rgb = first["c"] as? [Double], rgb.count >= 3 else { return nil }
        return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
    }
}
