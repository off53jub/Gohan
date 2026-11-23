import Photos
import SwiftUI
import UIKit

/// 写真アプリの写真を表示する（読み込んだ絵は少しだけ覚えておく）
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 400 }

    func image(_ id: String, side: CGFloat) async -> UIImage? {
        guard !id.isEmpty else { return nil }
        let key = "\(id)#\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let asset = PhotoLoader.asset(id), let image = await PhotoLoader.image(asset, side: side) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 先に読んでおく（一覧をなめらかに。便69）
    func prefetch(_ ids: [String], side: CGFloat) {
        Task {
            for id in ids { _ = await image(id, side: side) }
        }
    }
}

struct PhotoThumb: View {
    let id: String?
    var side: CGFloat = 64
    var corner: CGFloat = 12
    var circle = false
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Ink.photo)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "fork.knife").foregroundStyle(Ink.hai)
            }
        }
        .frame(width: side, height: side)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
        .task(id: id) {
            guard let id else { return }
            image = await ThumbCache.shared.image(id, side: side * scale)
        }
        .accessibilityHidden(true)
    }
}

/// 幅いっぱいに広がる写真（高さは決める）
struct FillPhoto: View {
    let id: String
    var side: CGFloat = 800
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(Ink.photo)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: id) { image = await ThumbCache.shared.image(id, side: side) }
    }
}

/// 組み写真（1枚: いっぱい / 2枚: 半分ずつ / 3枚以上: 大1＋小2）
struct Collage: View {
    let ids: [String]
    var height: CGFloat = 200

    var body: some View {
        Group {
            if ids.count >= 3 {
                HStack(spacing: 3) {
                    FillPhoto(id: ids[0])
                        .frame(maxWidth: .infinity)
                        .layoutPriority(2)
                    VStack(spacing: 3) {
                        FillPhoto(id: ids[1], side: 400)
                        FillPhoto(id: ids[2], side: 400)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if ids.count == 2 {
                HStack(spacing: 3) {
                    FillPhoto(id: ids[0], side: 500)
                    FillPhoto(id: ids[1], side: 500)
                }
            } else if let first = ids.first {
                FillPhoto(id: first)
            } else {
                Rectangle().fill(Ink.photo)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 食事の写真を横にめくって見る（押すと全画面。便67）
struct PhotoPager: View {
    let ids: [String]
    var height: CGFloat = 310
    @State private var index = 0
    @State private var full = false

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                BigPhoto(id: id)
                    .tag(i)
                    .onTapGesture { full = true }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: ids.count > 1 ? .automatic : .never))
        .frame(height: height)
        .fullScreenCover(isPresented: $full) {
            FullPhotos(ids: ids, index: index)
        }
    }
}

private struct BigPhoto: View {
    let id: String
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            Rectangle().fill(Ink.photo)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if missing {
                Label("写真アプリから消えています", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(Ink.hai)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: id) {
            image = await ThumbCache.shared.image(id, side: 1200)
            missing = image == nil
        }
        .accessibilityLabel("料理の写真")
    }
}

/// 全画面の写真（つまんで拡大）
struct FullPhotos: View {
    let ids: [String]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                    ZoomPhoto(id: id).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: ids.count > 1 ? .automatic : .never))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.2), in: Circle())
            }
            .padding()
            .accessibilityLabel("閉じる")
        }
    }
}

private struct ZoomPhoto: View {
    let id: String
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1, min(5, lastScale * $0)) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale == 1 { offset = .zero; lastOffset = .zero }
                            }
                    )
                    // 拡大していないときは、横にめくれるよう動かす手を外す
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset },
                        including: scale > 1 ? .all : .subviews
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: id) { image = await ThumbCache.shared.image(id, side: 2400) }
    }
}
