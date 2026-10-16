import SwiftUI
import WidgetKit

private let groupId = "group.com.example.localwidgets"

struct LocalEntry: TimelineEntry {
    let date: Date
    let photoPath: String
    let verse: String
    let reference: String
    let watchItems: [String]
}

struct LocalProvider: TimelineProvider {
    func placeholder(in context: Context) -> LocalEntry {
        LocalEntry(date: Date(), photoPath: "", verse: "Be still, and know that I am God.",
                   reference: "Psalm 46:10", watchItems: ["A film to remember"])
    }

    func getSnapshot(in context: Context, completion: @escaping (LocalEntry) -> Void) {
        completion(makeEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LocalEntry>) -> Void) {
        let currentDate = Date()
        let entries = (0..<60).map { offset in
            let date = currentDate.addingTimeInterval(Double(offset * 15))
            return makeEntry(at: date)
        }
        let reloadDate = currentDate.addingTimeInterval(Double(60 * 15))
        completion(Timeline(entries: entries, policy: .after(reloadDate)))
    }

    private func makeEntry(at date: Date) -> LocalEntry {
        let defaults = UserDefaults(suiteName: groupId)
        let photoJSON = defaults?.string(forKey: "photo_paths") ?? "[]"
        let paths = (photoJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        let rotate = defaults?.object(forKey: "rotate_photos") as? Bool ?? true
        let intervalIndex = Int(date.timeIntervalSince1970 / 15.0)
        let path: String
        if paths.isEmpty {
            path = ""
        } else if rotate {
            let positiveIndex = ((intervalIndex % paths.count) + paths.count) % paths.count
            path = paths[positiveIndex]
        } else {
            path = paths[0]
        }
        let json = defaults?.string(forKey: "watchlist_json") ?? "[]"
        let list = (json.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([WatchRecord].self, from: $0) }) ?? []
        return LocalEntry(
            date: date,
            photoPath: path,
            verse: defaults?.string(forKey: "verse_text") ?? "Be still, and know that I am God.",
            reference: defaults?.string(forKey: "verse_reference") ?? "Psalm 46:10",
            watchItems: list.prefix(4).map { "\($0.watched ? "✓" : "○")  \($0.title)" }
        )
    }
}

private struct WatchRecord: Codable {
    let title: String
    let watched: Bool
}

private let surface = Color(red: 0.12, green: 0.13, blue: 0.16)
private let violet = Color(red: 0.73, green: 0.66, blue: 1)

struct PhotoWidgetView: View {
    var entry: LocalEntry
    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: entry.photoPath) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    surface
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28)).foregroundStyle(violet)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .containerBackground(for: .widget) { surface }
        .widgetURL(URL(string: "still://photo"))
    }
}

struct VerseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LocalEntry
    var body: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.verse).font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text(entry.reference).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if family == .accessoryInline {
                Text("\(entry.reference) · \(entry.verse)").lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DAILY VERSE").font(.system(size: 10, weight: .bold))
                        .tracking(2).foregroundStyle(violet)
                    Text(entry.verse).font(.system(size: 18, weight: .medium))
                        .lineLimit(5).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text(entry.reference).font(.system(size: 12)).foregroundStyle(violet)
                }
                .padding(16)
            }
        }
        .containerBackground(for: .widget) { surface }
        .widgetURL(URL(string: "still://verse"))
    }
}

struct WatchlistWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LocalEntry
    var body: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WATCHLIST").font(.system(size: 10, weight: .bold))
                    ForEach(Array(entry.watchItems.prefix(2).enumerated()), id: \.offset) { _, title in
                        Text(title).font(.system(size: 11)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WATCHLIST").font(.system(size: 10, weight: .bold))
                        .tracking(2).foregroundStyle(violet)
                    if entry.watchItems.isEmpty {
                        Text("Your watchlist is empty").foregroundStyle(.secondary)
                    }
                    ForEach(Array(entry.watchItems.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.system(size: 14)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(16)
            }
        }
        .containerBackground(for: .widget) { surface }
        .widgetURL(URL(string: "still://watchlist"))
    }
}

struct PhotoWidget: Widget {
    let kind = "PhotoWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LocalProvider()) { entry in
            PhotoWidgetView(entry: entry)
        }
        .configurationDisplayName("Photo")
        .description("Show locally selected photos.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct VerseWidget: Widget {
    let kind = "VerseWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LocalProvider()) { entry in
            VerseWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily Verse")
        .description("Keep a meaningful verse close by.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct WatchlistWidget: Widget {
    let kind = "WatchlistWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LocalProvider()) { entry in
            WatchlistWidgetView(entry: entry)
        }
        .configurationDisplayName("Watchlist")
        .description("Your films and series, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct LocalWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PhotoWidget()
        VerseWidget()
        WatchlistWidget()
    }
}
