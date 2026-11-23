import Observation
import SwiftUI
import UIKit

// デザイン（2026-11-23「うつわ」→ 2026-11-24 本人の希望で「明瞭」に寄せた）: 白い地・藍の字・赤は印（また行きたい・◯回目）だけ。
// 料理の写真は暖色が多いので、まわりは寒色に寄せて写真を引き立てる。飾り（手書き風の字・傾いたはんこ・模様）は使わない。

/// 色（暗い画面では明るさを入れ替える）
enum Ink {
    /// 藍。店名・月・主なボタン
    static let ai = dynamic(light: 0x22346B, dark: 0x9DB2F0)
    /// 墨。本文
    static let sumi = dynamic(light: 0x2B3245, dark: 0xE8ECF5)
    /// 灰。日付・補足（白地で 4.5:1 以上）
    static let hai = dynamic(light: 0x586079, dark: 0xA9B1C6)
    /// 白磁。画面の地
    static let ground = dynamic(light: 0xF6F7FA, dark: 0x121829)
    /// カードの地
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1B2238)
    /// 赤。ハートとはんこだけに使う
    static let aka = dynamic(light: 0xC23B2A, dark: 0xF0705E)
    /// 区切りの線
    static let line = dynamic(light: 0xDFE3EC, dark: 0x2C3550)
    /// 札の地
    static let chip = dynamic(light: 0xEBEEF6, dark: 0x26304C)
    /// 藍の上の文字
    static let onAi = dynamic(light: 0xFFFFFF, dark: 0x121829)
    /// 写真が読めないときの色
    static let photo = dynamic(light: 0xE4E7EF, dark: 0x252E48)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 店名・月の字。2026-11-24 本人「明瞭 UI がいいかも」で、手書き風（クレー）をやめて太い角ゴシックにした
@MainActor
@Observable
final class Brush {
    static let shared = Brush()
    private(set) var family = "HiraginoSans-W6"

    func load() {}

    /// 字の大きさの設定に合わせて大きくなる
    func font(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(family, size: size, relativeTo: style)
    }
}

extension Font {
    @MainActor static func brush(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        Brush.shared.font(size, relativeTo: style)
    }
}

// MARK: - 部品

/// 「◯回目」のはんこ（赤い丸の枠・少し傾ける）
struct Stamp: View {
    let text: String
    var sub: String?
    var size: CGFloat = 54
    var filled = false
    var tilt: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            if let sub { Text(sub).font(.brush(size * 0.18, relativeTo: .caption2)) }
            Text(text).font(.brush(size * (sub == nil ? 0.26 : 0.24), relativeTo: .caption))
        }
        .foregroundStyle(filled ? Ink.card : Ink.aka)
        .frame(width: size, height: size)
        .background(Circle().fill(filled ? Ink.aka : Ink.card))
        .overlay(Circle().strokeBorder(Ink.aka, lineWidth: 2))
        .rotationEffect(.degrees(tilt))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([sub, text].compactMap { $0 }.joined(separator: " "))
    }
}

/// まだ行っていない「つぎ」の丸（点線）
struct NextStamp: View {
    var size: CGFloat = 54

    var body: some View {
        Text("つぎ")
            .font(.system(size: size * 0.22, weight: .bold))
            .foregroundStyle(Ink.hai)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Ink.hai, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
            .accessibilityLabel("次に来たときの場所")
    }
}

/// ジャンル・料理の札
struct Chip: View {
    let text: String
    var strong = false

    var body: some View {
        Text(text)
            .font(.system(.footnote, weight: strong ? .bold : .medium))
            .foregroundStyle(strong ? Ink.onAi : Ink.ai)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(strong ? Ink.ai : Ink.chip, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// 押すと、ぽんと押される「また行きたい」
struct HeartButton: View {
    let on: Bool
    var size: CGFloat = 22
    let toggle: () -> Void
    @State private var bump = false

    var body: some View {
        Button {
            toggle()
            bump.toggle()
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? Ink.aka : Ink.hai)
                .scaleEffect(bump ? 1.0 : 1.0)
                .symbolEffect(.bounce, value: bump)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: bump)
        .accessibilityLabel(on ? "また行きたい（オン）" : "また行きたい（オフ）")
    }
}

/// 区切りの細い線（月の見出しの下に引く）
struct Tokusa: View {
    var body: some View {
        Rectangle().fill(Ink.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// カードの見た目
struct CardBackground: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(Ink.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(radius: CGFloat = 20) -> some View { modifier(CardBackground(radius: radius)) }

    /// 小見出し（灰の太字）
    func sectionLabel() -> some View {
        font(.system(.caption, weight: .bold)).foregroundStyle(Ink.hai)
    }
}

/// 主なボタン（藍の地）
struct InkButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .bold))
            .foregroundStyle(filled ? Ink.onAi : Ink.ai)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(filled ? Ink.ai : Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if !filled { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.line) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 何もないときのアイコンと文
struct EmptyArt: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Ink.ai)
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Ink.sumi)
            Text(message).font(.callout).foregroundStyle(Ink.hai).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
