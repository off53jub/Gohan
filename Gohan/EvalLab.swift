import Foundation
import SwiftData
import SwiftUI

// 試験（精度3。2026-11-24）: 本人が「正解」にした食事を、前に行ったお店や直した覚えを使わずに最初から当て直し、
// モデルや作りを変えたときに当たる数が増えたかを数字で比べる。作る人のメニューの中だけに置く（ういちゃんには見せない）

struct EvalCase: Codable, Equatable, Identifiable {
    var id: UUID
    var photoIDs: [String]
    var date: Date
    var name: String
    var latitude: Double
    var longitude: Double
    var genre: String
}

struct EvalDetail: Codable, Equatable {
    var caseID: UUID
    var truth: String
    var got: String
    var hit: Bool
    var genreHit: Bool
}

struct EvalRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var model: String
    var total: Int
    var hits: Int
    var noPlace: Int
    var genreHits: Int
    var usd: Double
    var details: [EvalDetail]
}

/// 試験のあいだは、本人が直した覚え（場所ごとの正解・ジャンルの覚え）を使わない
enum EvalMode {
    static var on = false
}

enum EvalStore {
    private static var casesURL: URL { URL.applicationSupportDirectory.appendingPathComponent("eval-cases.json") }
    private static var runsURL: URL { URL.applicationSupportDirectory.appendingPathComponent("eval-runs.json") }

    static func cases() -> [EvalCase] { read(casesURL) ?? [] }
    static func saveCases(_ cases: [EvalCase]) { write(cases, to: casesURL) }
    static func runs() -> [EvalRun] { read(runsURL) ?? [] }

    /// 新しい結果を先頭に足す（30 回分まで）
    static func addRun(_ run: EvalRun) {
        write(Array(([run] + runs()).prefix(30)), to: runsURL)
    }

    /// 当たりか: 名前がはっきり合う、または近くて名前もそこそこ合う
    static func isHit(truthName: String, truthLat: Double, truthLon: Double, gotName: String?, gotLat: Double?, gotLon: Double?) -> Bool {
        guard let gotName, !gotName.isEmpty else { return false }
        let s = Matcher.similarity(Matcher.coreName(truthName), Matcher.coreName(gotName))
        if s >= 0.8 { return true }
        guard let gotLat, let gotLon else { return false }
        let d = Matcher.distance(truthLat, truthLon, gotLat, gotLon)
        return (s >= 0.5 && d <= 150) || (s >= 0.3 && d <= 30)
    }

    static func modelName(_ model: String) -> String {
        switch model {
        case "claude-haiku-5-5": return "Haiku"
        case "claude-sonnet-5-5": return "Sonnet"
        case "claude-opus-5-5": return "Opus"
        case "device": return "端末だけ"
        default: return model
        }
    }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

extension Scanner {
    /// 試験を流す。食事は別の入れ物（保存しない）で作るので、本物の記録には何も足さない
    func evaluate(model: String) async -> EvalRun? {
        guard !isRunning else { return nil }
        let cases = EvalStore.cases()
        guard !cases.isEmpty,
              let box = try? ModelContainer(for: Meal.self, Place.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else { return nil }
        isRunning = true
        lastError = nil
        let deviceOnly = AISettings.deviceOnly
        let before = Spend.thisMonth
        EvalMode.on = true
        if model == "device" {
            AISettings.deviceOnly = true
        } else {
            AISettings.deviceOnly = false
            AIModel.forced = model
        }
        defer {
            EvalMode.on = false
            AIModel.forced = nil
            AISettings.deviceOnly = deviceOnly
            isRunning = false
            status = ""
        }
        let seen = SeenStore.load()
        let all = Array(seen.values)
        let context = box.mainContext
        var details: [EvalDetail] = []
        for (i, item) in cases.enumerated() {
            if Task.isCancelled { break }
            status = "試験 \(i + 1)/\(cases.count)"
            let group = item.photoIDs.compactMap { seen[$0] }.sorted { $0.date < $1.date }
            guard !group.isEmpty else { continue }
            let meal = await buildMeal(Matcher.fillLocations(group, among: all), all: all, context: context, old: false)
            let place = meal?.place
            let hit = EvalStore.isHit(truthName: item.name, truthLat: item.latitude, truthLon: item.longitude,
                                      gotName: place?.name, gotLat: place?.latitude, gotLon: place?.longitude)
            let got = place?.name ?? (meal == nil ? "（食事ではないと判断）" : "（お店なし）")
            details.append(EvalDetail(caseID: item.id, truth: item.name, got: got, hit: hit, genreHit: meal?.genre == item.genre))
        }
        guard !details.isEmpty else { return nil }
        let run = EvalRun(date: Date(), model: model, total: details.count, hits: details.filter(\.hit).count,
                          noPlace: details.filter { !$0.hit && $0.got.hasPrefix("（") }.count,
                          genreHits: details.filter(\.genreHit).count, usd: max(0, Spend.thisMonth - before), details: details)
        EvalStore.addRun(run)
        return run
    }
}

/// 作る人のメニュー → 試験
struct EvalView: View {
    @Query(filter: #Predicate<Meal> { !$0.hidden && $0.eatenOut }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var cases = EvalStore.cases()
    @State private var runs = EvalStore.runs()
    @State private var model = "claude-sonnet-5-5"
    @State private var running: Task<Void, Never>?
    @State private var scanner = Scanner.shared

    var body: some View {
        List {
            Section {
                Picker("モデル", selection: $model) {
                    Text("Haiku（軽い）").tag("claude-haiku-5-5")
                    Text("Sonnet（ふだん）").tag("claude-sonnet-5-5")
                    Text("Opus（強い）").tag("claude-opus-5-5")
                    Text("端末だけ").tag("device")
                }
                if running != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(scanner.status.isEmpty ? "準備しています" : scanner.status).font(.footnote)
                    }
                    Button("止める", role: .destructive) { running?.cancel() }
                } else {
                    Button("試験を流す（\(cases.count) 件）") { start() }
                        .disabled(cases.isEmpty || scanner.isRunning)
                }
            } header: {
                Text("流す")
            } footer: {
                Text("正解にした食事を、前に行ったお店や直した覚えを使わずに、最初から当て直します（初めて行ったつもりで）。記録には何も足しません。費用の目安は 1 件あたり Haiku 0.2円・Sonnet 2円・Opus 4円くらい（仮）で、今月の使った額に入ります。")
            }
            if !runs.isEmpty {
                Section("結果") {
                    ForEach(runs) { run in
                        DisclosureGroup {
                            ForEach(run.details.filter { !$0.hit }, id: \.caseID) { d in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("正解: \(d.truth)")
                                    Text("答え: \(d.got)").foregroundStyle(Ink.hai)
                                }
                                .font(.footnote)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(EvalStore.modelName(run.model))　当たり \(run.hits)/\(run.total)（\(percent(run.hits, run.total))）")
                                Text("\(run.date.formatted(date: .abbreviated, time: .shortened))・お店なし \(run.noPlace)・ジャンル \(run.genreHits)/\(run.total)・$\(String(format: "%.2f", run.usd))")
                                    .font(.caption)
                                    .foregroundStyle(Ink.hai)
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(meals.prefix(200)) { meal in
                    Button { toggle(meal) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isCase(meal) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isCase(meal) ? Ink.ai : Ink.hai)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.place?.name ?? "（お店なし）").foregroundStyle(Ink.sumi)
                                Text("\(meal.date.formatted(date: .abbreviated, time: .shortened))・\(meal.genre)")
                                    .font(.caption)
                                    .foregroundStyle(Ink.hai)
                            }
                        }
                    }
                    .disabled(meal.place == nil)
                }
            } header: {
                Text("正解にする食事（\(cases.count) 件）")
            } footer: {
                Text("お店が合っている食事に印をつけます。違っていた食事は、先に食事の画面で直してから印をつけてください。30〜50 件あると比べやすくなります。")
            }
        }
        .navigationTitle("試験")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func percent(_ a: Int, _ b: Int) -> String {
        b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%"
    }

    private func isCase(_ meal: Meal) -> Bool { cases.contains { $0.id == meal.id } }

    private func toggle(_ meal: Meal) {
        if let i = cases.firstIndex(where: { $0.id == meal.id }) {
            cases.remove(at: i)
        } else if let place = meal.place {
            cases.append(EvalCase(id: meal.id, photoIDs: meal.photoIDs, date: meal.date, name: place.name,
                                  latitude: place.latitude, longitude: place.longitude, genre: meal.genre))
        }
        EvalStore.saveCases(cases)
    }

    private func start() {
        let chosen = model
        running = Task {
            _ = await Scanner.shared.evaluate(model: chosen)
            runs = EvalStore.runs()
            running = nil
        }
    }
}
