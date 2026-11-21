import SwiftData
import SwiftUI

/// 食事の一覧（新しい順・日ごと）
struct TimelineView: View {
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var scanner = Scanner.shared

    var body: some View {
        NavigationStack {
            List {
                if scanner.isRunning || scanner.lastError != nil {
                    Section {
                        if scanner.isRunning {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(scanner.status.isEmpty ? "写真を読んでいます" : scanner.status)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let error = scanner.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(days, id: \.day) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.meals) { meal in
                            NavigationLink(value: meal) { MealRow(meal: meal) }
                        }
                    }
                }
            }
            .overlay {
                if meals.isEmpty && !scanner.isRunning {
                    ContentUnavailableView("まだ記録がありません", systemImage: "fork.knife",
                                           description: Text("ごはんの写真を撮ると、ここに並びます。下に引くと読み直します。"))
                }
            }
            .navigationTitle("ごはん帖")
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .refreshable { await scanner.scan() }
        }
    }

    private var days: [(day: Date, meals: [Meal])] {
        let calendar = Calendar.current
        var out: [(day: Date, meals: [Meal])] = []
        for meal in meals {
            let day = calendar.startOfDay(for: meal.date)
            if out.last?.day == day {
                out[out.count - 1].meals.append(meal)
            } else {
                out.append((day, [meal]))
            }
        }
        return out
    }

    static func dayTitle(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year) ? "M月d日(E)" : "yyyy年M月d日(E)"
        if Calendar.current.isDateInToday(day) { return "今日 " + f.string(from: day) }
        if Calendar.current.isDateInYesterday(day) { return "きのう " + f.string(from: day) }
        return f.string(from: day)
    }
}

struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumb(id: meal.photoIDs.first)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meal.title).font(.headline).lineLimit(1)
                    if meal.place?.wantAgain == true {
                        Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                    }
                }
                Text("\(Genre.emoji(meal.genre)) \(meal.dishText)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(meal.date, format: .dateTime.hour().minute())
                    if meal.photoIDs.count > 1 { Text("・写真\(meal.photoIDs.count)枚") }
                    if meal.needsCheck {
                        Text("たぶん")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.yellow.opacity(0.25), in: Capsule())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
