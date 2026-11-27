import Foundation
import SwiftData
import WidgetKit

// ホーム画面の小窓に渡すものを書く（大19。2026-11-28）。読み取りのあとと、アプリを開いたときに書く

enum WidgetFeed {
    /// 1 年前の今日として出す幅（前後の日数）
    static let memoryDays = 3

    /// 1 年前の今日にいちばん近い食事
    static func memory(_ meals: [(id: UUID, date: Date)], now: Date, calendar: Calendar = .current) -> UUID? {
        guard let target = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
        let near = meals.filter { abs($0.date.timeIntervalSince(target)) <= Double(memoryDays) * 86_400 }
        return near.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }?.id
    }

    /// また行きたいお店から、いちばんごぶさたの 1 軒
    static func want(_ places: [(key: String, last: Date?)]) -> String? {
        places.min { ($0.last ?? .distantPast) < ($1.last ?? .distantPast) }?.key
    }

    @MainActor
    static func write(context: ModelContext, now: Date = Date()) async {
        guard let folder = AppGroup.folder else { return }
        var feed = WidgetFeedFile(made: now)
        if let target = Calendar.current.date(byAdding: .year, value: -1, to: now) {
            let from = target.addingTimeInterval(-Double(memoryDays) * 86_400)
            let to = target.addingTimeInterval(Double(memoryDays) * 86_400)
            let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.date >= from && $0.date <= to })
            let meals = ((try? context.fetch(descriptor)) ?? []).filter { !$0.photoIDs.isEmpty }
            if let id = memory(meals.map { ($0.id, $0.date) }, now: now), let meal = meals.first(where: { $0.id == id }) {
                var imageName: String?
                if let photo = meal.photoIDs.first, let image = await ThumbCache.shared.image(photo, side: 600),
                   let data = image.jpegData(compressionQuality: 0.75) {
                    try? data.write(to: folder.appendingPathComponent(WidgetFeedFile.imageName), options: .atomic)
                    imageName = WidgetFeedFile.imageName
                }
                feed.memory = .init(title: meal.title, date: meal.date, mealID: meal.id.uuidString, image: imageName)
            }
        }
        let wants = ((try? context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.wantAgain }))) ?? [])
        if let key = want(wants.map { ($0.key, $0.lastVisit) }), let place = wants.first(where: { $0.key == key }) {
            let detail = place.nextWish.isEmpty ? place.lastVisit.map { "前に来たのは \($0.formatted(.dateTime.year().month().day()))" } ?? "" : "つぎは \(place.nextWish)"
            feed.want = .init(name: place.name, detail: detail, key: place.key)
        }
        if feed.memory != WidgetFeedFile.read()?.memory || feed.want != WidgetFeedFile.read()?.want {
            feed.write()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
