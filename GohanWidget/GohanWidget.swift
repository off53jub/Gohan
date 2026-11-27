import SwiftUI
import UIKit
import WidgetKit

// ホーム画面の小窓（大19。2026-11-28）。1 年前の今日の写真か、また行きたいお店を 1 軒

struct FeedEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeedFile?
    let image: UIImage?
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry { FeedEntry(date: Date(), feed: nil, image: nil) }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) { completion(entry()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        // 日が変わったら読み直す（アプリも、書いたときに読み直しを頼む）
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .minute, value: 5, to: calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()))
        completion(Timeline(entries: [entry()], policy: .after(next ?? Date().addingTimeInterval(86_400))))
    }

    private func entry() -> FeedEntry {
        let feed = WidgetFeedFile.read()
        var image: UIImage?
        if let name = feed?.memory?.image, let url = AppGroup.folder?.appendingPathComponent(name) {
            image = UIImage(contentsOfFile: url.path)
        }
        return FeedEntry(date: Date(), feed: feed, image: image)
    }
}

struct FeedView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    private let ai = Color(red: 0x22 / 255, green: 0x34 / 255, blue: 0x6B / 255)
    private let aka = Color(red: 0xC2 / 255, green: 0x3B / 255, blue: 0x2A / 255)

    var body: some View {
        if let memory = entry.feed?.memory {
            ZStack(alignment: .bottomLeading) {
                if let image = entry.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ai
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(yearsAgo(memory.date)).font(.caption2.bold()).foregroundStyle(.white.opacity(0.9))
                    Text(memory.title).font(.footnote.bold()).foregroundStyle(.white).lineLimit(2)
                }
                .padding(12)
            }
            .widgetURL(ShareInbox.mealURL(memory.mealID))
        } else if let want = entry.feed?.want {
            VStack(alignment: .leading, spacing: 6) {
                Label("また行きたい", systemImage: "heart.fill").font(.caption2.bold()).foregroundStyle(aka)
                Text(want.name).font(.headline).foregroundStyle(ai).lineLimit(2)
                if !want.detail.isEmpty {
                    Text(want.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .widgetURL(ShareInbox.placeURL(want.key))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "book.closed").font(.title2).foregroundStyle(ai)
                Text("ごはん帖").font(.footnote.bold()).foregroundStyle(ai)
            }
        }
    }

    private func yearsAgo(_ date: Date) -> String {
        let years = Calendar.current.dateComponents([.year], from: date, to: entry.date).year ?? 1
        return "\(max(1, years))年前の今日"
    }
}

struct GohanFeedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "gohan.feed", provider: FeedProvider()) { entry in
            FeedView(entry: entry)
                .containerBackground(for: .widget) { Color.white }
        }
        .configurationDisplayName("ごはん帖")
        .description("1年前の今日のごはんと、また行きたいお店")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct GohanWidgetBundle: WidgetBundle {
    var body: some Widget {
        GohanFeedWidget()
    }
}
