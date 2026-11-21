import Photos
import SwiftUI
import UIKit

/// 写真アプリの写真を表示する（読み込んだ絵は少しだけ覚えておく）
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 300 }

    func image(_ id: String, side: CGFloat) async -> UIImage? {
        let key = "\(id)#\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let asset = PhotoLoader.asset(id), let image = await PhotoLoader.image(asset, side: side) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct PhotoThumb: View {
    let id: String?
    var side: CGFloat = 64
    var corner: CGFloat = 10
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "fork.knife").foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: id) {
            guard let id else { return }
            image = await ThumbCache.shared.image(id, side: side * scale)
        }
    }
}

/// 食事の写真を横にめくって見る
struct PhotoPager: View {
    let ids: [String]

    var body: some View {
        TabView {
            ForEach(ids, id: \.self) { id in
                BigPhoto(id: id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: ids.count > 1 ? .automatic : .never))
        .frame(height: 320)
    }
}

private struct BigPhoto: View {
    let id: String
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if missing {
                Label("写真アプリから消えています", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: id) {
            image = await ThumbCache.shared.image(id, side: 1200)
            missing = image == nil
        }
    }
}
