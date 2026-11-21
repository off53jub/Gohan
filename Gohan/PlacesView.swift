import MapKit
import SwiftData
import SwiftUI

/// 行ったお店の一覧と、料理・お店の名前で探す
struct PlacesView: View {
    @Query(sort: \Place.firstVisit, order: .reverse) private var places: [Place]
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var onlyWant = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Picker("表示", selection: $onlyWant) {
                    Text("すべて").tag(false)
                    Text("また行きたい").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section(query.isEmpty ? "お店（\(shownPlaces.count)）" : "お店") {
                    ForEach(shownPlaces) { place in
                        NavigationLink(value: place) { PlaceRow(place: place) }
                    }
                }
                if !query.isEmpty, !hitMeals.isEmpty {
                    Section("料理・メモ") {
                        ForEach(hitMeals) { meal in
                            NavigationLink(value: meal) { MealRow(meal: meal) }
                        }
                    }
                }
            }
            .overlay {
                if places.isEmpty {
                    ContentUnavailableView("まだお店がありません", systemImage: "storefront",
                                           description: Text("お店で撮ったごはんの写真が読まれると、ここに並びます。"))
                }
            }
            .searchable(text: $query, prompt: "お店・料理・ジャンルで探す")
            .navigationTitle("お店")
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
        }
    }

    /// 最後に行った日の新しい順
    private var shownPlaces: [Place] {
        places
            .filter { !$0.visibleMeals.isEmpty || $0.wantAgain }
            .filter { !onlyWant || $0.wantAgain }
            .filter { query.isEmpty || matches($0) }
            .sorted { ($0.visibleMeals.first?.date ?? $0.firstVisit) > ($1.visibleMeals.first?.date ?? $1.firstVisit) }
    }

    private func matches(_ place: Place) -> Bool {
        let q = query
        if place.name.localizedStandardContains(q) || place.address.localizedStandardContains(q) { return true }
        return place.visibleMeals.contains { $0.genre.localizedStandardContains(q) || $0.dishes.contains { $0.localizedStandardContains(q) } }
    }

    private var hitMeals: [Meal] {
        let q = query
        return meals.filter { meal in
            meal.dishes.contains { $0.localizedStandardContains(q) }
                || meal.genre.localizedStandardContains(q)
                || meal.note.localizedStandardContains(q)
                || meal.summary.localizedStandardContains(q)
        }
        .prefix(50).map { $0 }
    }
}

struct PlaceRow: View {
    let place: Place

    var body: some View {
        let visits = place.visibleMeals
        HStack(spacing: 12) {
            PhotoThumb(id: visits.first?.photoIDs.first, side: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(place.name).font(.headline).lineLimit(1)
                    if place.wantAgain { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
                }
                HStack(spacing: 6) {
                    if let genre = visits.first?.genre { Text("\(Genre.emoji(genre)) \(genre)") }
                    Text("\(visits.count)回")
                    if let last = visits.first?.date { Text(last, format: .dateTime.year().month().day()) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// お店1つ（行った記録・また行きたい・マップで開く）
struct PlaceDetailView: View {
    @Bindable var place: Place

    var body: some View {
        List {
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500))) {
                    Marker(place.name, coordinate: coordinate).tint(place.wantAgain ? .pink : .orange)
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if !place.address.isEmpty { Text(place.address).font(.callout) }
                Toggle(isOn: $place.wantAgain) {
                    Label("また行きたい", systemImage: place.wantAgain ? "heart.fill" : "heart")
                }
                .tint(.pink)
                Button {
                    PlaceFinder.openInMaps(name: place.name, latitude: place.latitude, longitude: place.longitude)
                } label: {
                    Label("マップで開く", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                TextField("メモ（次に頼みたいもの など）", text: $place.note, axis: .vertical)
            }
            Section("行った記録（\(place.visibleMeals.count)回）") {
                ForEach(place.visibleMeals) { meal in
                    NavigationLink(value: meal) {
                        HStack(spacing: 12) {
                            PhotoThumb(id: meal.photoIDs.first, side: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.date, format: .dateTime.year().month().day().weekday())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(meal.dishText).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }
}

/// 行ったお店の地図
struct PlacesMapView: View {
    @Query private var places: [Place]
    @State private var onlyWant = false
    @State private var selected: Place?

    var body: some View {
        NavigationStack {
            Map {
                ForEach(shown) { place in
                    Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) {
                        Button {
                            selected = place
                        } label: {
                            Text(Genre.emoji(place.visibleMeals.first?.genre ?? ""))
                                .font(.title3)
                                .padding(6)
                                .background(place.wantAgain ? Color.pink : Color.orange, in: Circle())
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("表示", selection: $onlyWant) {
                    Text("すべて").tag(false)
                    Text("また行きたい").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.thinMaterial)
            }
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { PlaceDetailView(place: $0) }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
        }
    }

    private var shown: [Place] {
        places.filter { (!$0.visibleMeals.isEmpty || $0.wantAgain) && (!onlyWant || $0.wantAgain) }
    }
}
