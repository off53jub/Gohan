import SwiftUI
import UIKit

/// 送る用の1枚（写真＋店名＋日付＋はんこ。デ20・便59・便60・便30）
enum ShareCards {
    @MainActor
    static func mealImage(_ meal: Meal) async -> Image? {
        let photo = await ThumbCache.shared.image(meal.photoIDs.first ?? "", side: 1080)
        let card = MealShareCard(photo: photo, title: meal.title, dishes: meal.dishText, date: meal.date,
                                 visit: meal.place == nil ? nil : meal.visitNumber, area: meal.area)
        return render(card)
    }

    @MainActor
    static func placeImage(_ place: Place) async -> Image? {
        let photo = await ThumbCache.shared.image(place.visibleMeals.first?.photoIDs.first ?? "", side: 1080)
        let card = MealShareCard(photo: photo, title: place.name, dishes: place.visibleMeals.first?.dishText ?? place.mainGenre,
                                 date: place.lastVisit ?? place.firstVisit, visit: place.visibleMeals.count, area: place.address)
        return render(card)
    }

    /// まとめ（週・月・年）の1枚
    @MainActor
    static func summaryImage(title: String, meals: [Meal]) async -> Image? {
        var photos: [UIImage] = []
        for meal in meals.prefix(9) {
            if let image = await ThumbCache.shared.image(meal.photoIDs.first ?? "", side: 360) { photos.append(image) }
        }
        let places = Set(meals.compactMap { $0.place?.key }).count
        var genres: [String: Int] = [:]
        for m in meals { genres[m.genre, default: 0] += 1 }
        let top = genres.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \($0.value)" }
        let card = SummaryShareCard(title: title, photos: photos, lines: ["\(meals.count)食・\(places)軒"] + top)
        return render(card)
    }

    @MainActor
    private static func render<V: View>(_ view: V) -> Image? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.uiImage else { return nil }
        return Image(uiImage: image)
    }
}

private struct MealShareCard: View {
    let photo: UIImage?
    let title: String
    let dishes: String
    let date: Date
    let visit: Int?
    let area: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Ink.photo)
                    .overlay {
                        if let photo { Image(uiImage: photo).resizable().scaledToFill() }
                    }
                    .frame(width: 540, height: 540)
                    .clipped()
                if let visit, visit >= 1 {
                    Stamp(text: "\(visit)回目", size: 96).padding(24)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.brush(34)).foregroundStyle(Ink.ai).lineLimit(2)
                Text(dishes).font(.system(size: 20)).foregroundStyle(Ink.sumi).lineLimit(2)
                HStack {
                    Text([area, date.formatted(.dateTime.year().month().day())].filter { !$0.isEmpty }.joined(separator: "・"))
                        .font(.system(size: 16)).foregroundStyle(Ink.hai)
                    Spacer()
                    Text("ごはん帖").font(.brush(18)).foregroundStyle(Ink.ai)
                }
                Tokusa()
            }
            .padding(28)
        }
        .frame(width: 540)
        .background(Color.white)
    }
}

private struct SummaryShareCard: View {
    let title: String
    let photos: [UIImage]
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.brush(40)).foregroundStyle(Ink.ai)
            Tokusa()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(156), spacing: 6), count: 3), spacing: 6) {
                ForEach(photos.indices, id: \.self) { i in
                    Image(uiImage: photos[i]).resizable().scaledToFill().frame(width: 156, height: 156).clipped()
                }
            }
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 20)).foregroundStyle(Ink.sumi) }
            HStack { Spacer(); Text("ごはん帖").font(.brush(18)).foregroundStyle(Ink.ai) }
        }
        .padding(32)
        .frame(width: 540)
        .background(Color.white)
    }
}
