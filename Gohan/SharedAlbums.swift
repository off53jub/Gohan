import Photos
import SwiftData
import SwiftUI

// 2026-11-28 「ういきょ」で始まる共有アルバムの、ごはんの写真を数える（取り込む前の試し）。
// 数えるだけで、食事も写真も何も書き換えない。作る人のメニューにだけ出す。

enum SharedAlbums {
    static let prefix = "ういきょ"

    /// アルバムの名前が「ういきょ」で始まるか（カタカナの「ウイキョ」・前の空白も同じに見る）
    static func matches(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hira = t.applyingTransform(.hiraganaToKatakana, reverse: true) ?? t
        return hira.hasPrefix(prefix)
    }

    static func albums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        var out: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in
            if matches(c.localizedTitle ?? "") { out.append(c) }
        }
        return out
    }

    /// 1 つのアルバムの数
    struct Tally: Identifiable, Equatable {
        var name: String
        var id: String { name }
        var photos = 0
        var food = 0
        /// ごはんの写真のうち、位置が残っているもの
        var located = 0
        /// ごはんの写真のうち、本人の食事の時間（前後 30 分）に入るもの
        var duringMyMeal = 0
        /// ごはんの写真のうち、本人の写真ライブラリに同じ時刻（2 秒以内）の写真があるもの（自分で載せた写真らしい）
        var sameAsMine = 0
        var first: Date?
        var last: Date?

        mutating func add(date: Date?, isFood: Bool, hasLocation: Bool, inMyMeal: Bool, mine: Bool) {
            photos += 1
            if let date {
                first = min(first ?? date, date)
                last = max(last ?? date, date)
            }
            guard isFood else { return }
            food += 1
            if hasLocation { located += 1 }
            if inMyMeal { duringMyMeal += 1 }
            if mine { sameAsMine += 1 }
        }
    }

    /// 本人の食事の時間に入るか（spans は開始で並べたもの）
    static func inMeal(_ date: Date, spans: [(Date, Date)], margin: TimeInterval = 30 * 60) -> Bool {
        spans.contains { date >= $0.0.addingTimeInterval(-margin) && date <= $0.1.addingTimeInterval(margin) }
    }

    /// 本人のライブラリに、同じ時刻の写真があるか
    static func hasOwnPhoto(at date: Date) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).count > 0
    }
}

/// 作る人のメニューの「ういきょのアルバムを数える」
struct SharedAlbumSection: View {
    @Environment(\.modelContext) private var context
    @State private var tallies: [SharedAlbums.Tally] = []
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var note: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        Section {
            if running {
                HStack {
                    ProgressView()
                    Text("数えています \(done) / \(total)")
                }
                Button("やめる", role: .cancel) { job?.cancel() }
            } else {
                Button("ういきょのアルバムを数える") { job = Task { await count() } }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            ForEach(tallies) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.subheadline.bold())
                    Text("写真 \(t.photos) 枚・ごはんらしい \(t.food) 枚")
                    Text("ごはんのうち 位置あり \(t.located)・自分の食事の時間 \(t.duringMyMeal)・自分の写真と同じ時刻 \(t.sameAsMine)")
                    if let f = t.first, let l = t.last {
                        Text("\(f.formatted(.dateTime.year().month().day()))〜\(l.formatted(.dateTime.year().month().day()))")
                    }
                }
                .font(.caption)
            }
        } header: {
            Text("共有アルバム（試し・2026-11-28）")
        } footer: {
            Text("「ういきょ」で始まる共有アルバムの写真を、端末の中で見て数えるだけです。食事も写真も変えません。写真が多いと数分かかります。")
        }
        .onDisappear { job?.cancel() }
    }

    private func count() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            note = "写真へのアクセスが「すべての写真」になっていないので、共有アルバムが読めません。"
            return
        }
        let albums = SharedAlbums.albums()
        guard !albums.isEmpty else {
            note = "「ういきょ」で始まる共有アルバムが見つかりませんでした（写真の設定で「共有アルバム」がオンか確かめてください）。"
            return
        }
        running = true
        defer { running = false }
        note = nil
        tallies = []
        done = 0
        let meals = (try? context.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let spans = meals.filter { !$0.hidden }.map { ($0.date, $0.endDate) }
        var lists: [(String, PHFetchResult<PHAsset>)] = []
        for album in albums {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            lists.append((album.localizedTitle ?? "?", PHAsset.fetchAssets(in: album, options: options)))
        }
        total = lists.reduce(0) { $0 + $1.1.count }
        for (name, assets) in lists {
            var tally = SharedAlbums.Tally(name: name)
            tallies.append(tally)
            for i in 0..<assets.count {
                if Task.isCancelled { note = "途中でやめました。"; return }
                let asset = assets.object(at: i)
                var food = false
                if let image = await PhotoLoader.image(asset, side: 360) {
                    let look = await Task.detached(priority: .utility) { PhotoVision.look(image) }.value
                    food = look.food >= Matcher.foodThreshold
                }
                let date = asset.creationDate
                tally.add(date: date, isFood: food, hasLocation: asset.location != nil,
                          inMyMeal: date.map { SharedAlbums.inMeal($0, spans: spans) } ?? false,
                          mine: food && date.map(SharedAlbums.hasOwnPhoto(at:)) == true)
                done += 1
                if i % 10 == 0 { tallies[tallies.count - 1] = tally }
            }
            tallies[tallies.count - 1] = tally
        }
        note = "数え終わりました。"
    }
}
