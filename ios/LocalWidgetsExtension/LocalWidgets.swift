import SwiftUI
import WidgetKit
import ImageIO

private let groupId = "group.com.example.localwidgets"

private func widgetImage(at path: String, maxPixelSize: Int = 1200) -> UIImage? {
    guard !path.isEmpty,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: image)
}

private struct CuratedVerse: Decodable {
    let id: String
    let text: String
    let reference: String
    let topic: String
}

private enum LocalBible {
    static let curated: [CuratedVerse] = {
        guard let url = Bundle.main.url(forResource: "curated_widget", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let verses = try? JSONDecoder().decode([CuratedVerse].self, from: data) else {
            return []
        }
        return verses
    }()

    static func dayNumber(for date: Date) -> Int {
        let localParts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = utc.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let current = utc.date(from: localParts)!
        return utc.dateComponents([.day], from: epoch, to: current).day ?? 0
    }

    static func verse(on date: Date, defaults: UserDefaults?) -> (String, String) {
        if defaults?.string(forKey: "verse_mode") == "pinned",
           let text = defaults?.string(forKey: "verse_text"), !text.isEmpty {
            return (text, defaults?.string(forKey: "verse_reference") ?? "")
        }
        guard !curated.isEmpty else {
            return ("Open Still to initialize your library.", "Still")
        }
        let index = ((dayNumber(for: date) % curated.count) + curated.count) % curated.count
        return (curated[index].text, curated[index].reference)
    }
}

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
        let (verse, reference) = LocalBible.verse(on: date, defaults: defaults)
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
            verse: verse,
            reference: reference,
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
            if let image = widgetImage(at: entry.photoPath) {
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
