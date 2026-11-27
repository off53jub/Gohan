import UIKit
import UniformTypeIdentifiers

// 共有ボタンから「行ってみたい」に送る（大18。2026-11-28）。
// インスタ・マップ・食べログで「共有 → ごはん帖」。文やリンクを置き場に入れ、ごはん帖を開いたときに保存する

final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "ごはん帖に送っています…"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        Task { @MainActor in await collect() }
    }

    @MainActor
    private func collect() async {
        var texts: [String] = []
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            if let text = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                texts.append(text)
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(text)
                }
            }
        }
        var seen = Set<String>()
        let joined = texts.filter { seen.insert($0).inserted }.joined(separator: "\n")
        if joined.isEmpty {
            label.text = "読めませんでした"
        } else {
            ShareInbox.add(joined)
            label.text = "ごはん帖に送りました。\nごはん帖を開くと「行ってみたい」に保存できます。"
        }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }
}
