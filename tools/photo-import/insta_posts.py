"""Instagram の書き出し（HTML）から、投稿を 1 件ずつ取り出す（大1。2026-11-28）。

    python -I tools/photo-import/insta_posts.py <広げたフォルダ>... --out D:/GohanImport/insta/posts.json

広げたフォルダ（instagram-<アカウント>-….zip を展開したもの）の
your_instagram_activity/media/posts*.html と archived_posts.html を読む。
1 件ごとに: アカウント・アーカイブか・文・1 行目（「街 店名」のことが多い）・2 行目（料理名のことが多い）・
撮った日時（写真の情報。無ければ投稿日時）・投稿日時・写真のファイル・ハッシュタグ。
書き出しは本人の手元のファイル。ここでは読むだけで、どこにも送らない。
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from datetime import datetime
from pathlib import Path

TAG = re.compile(r"<[^>]+>")
MONTHS = r"(\d{1,2})月 (\d{1,2}), (\d{4}) (\d{1,2}):(\d{2}) (AM|PM)"


def text(s: str) -> str:
    return html.unescape(TAG.sub("", s)).strip()


def posted_at(s: str) -> str | None:
    """「8月 09, 2022 6:56 AM」→ ISO（書き出しの時刻は UTC と見なす＝仮説）"""
    m = re.search(MONTHS, s)
    if not m:
        return None
    mo, d, y, h, mi, ap = m.groups()
    hour = int(h) % 12 + (12 if ap == "PM" else 0)
    return datetime(int(y), int(mo), int(d), hour, int(mi)).isoformat() + "Z"


def taken_at(block: str) -> str | None:
    """写真の情報の「撮影日」（端末の時刻。日本の時刻と見なす）。いちばん早いもの"""
    found = re.findall(r'撮影日</div><div><div class="_a6-q">(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})', block)
    if not found:
        return None
    y, mo, d, h, mi, se = min(found)
    return f"{y}-{mo}-{d}T{h}:{mi}:{se}+09:00"


def parse(path: Path, account: str, archived: bool) -> list[dict]:
    """投稿は「日時の行（_3-94 _a6-o）」で終わる。その前の部分から、文・写真・撮った日時を拾う"""
    s = path.read_text(encoding="utf-8")
    parts = re.split(r'<div class="_3-94 _a6-o">([^<]+)</div>', s)
    out = []
    for seg, date in zip(parts[0::2], parts[1::2]):
        caption = ""
        m = re.search(r"<h2[^>]*>(.*?)</h2>", seg, re.S)
        if m:
            caption = text(m.group(1))
        # 写真が何枚もある投稿は、見出し（h2）が「メディア」「ハッシュタグ」の札になっている
        if caption in ("メディア", "ハッシュタグ", "メディア所有者"):
            caption = ""
        if not caption:
            m = re.search(r"キャプション</td><td[^>]*>(.*?)</td>", seg, re.S)
            caption = text(m.group(1)) if m else ""
        if not caption:
            m = re.search(r'<img src="media/[^"]+"[^>]*/></a><div>(.*?)</div>', seg, re.S)
            caption = text(m.group(1)) if m else ""
        images = re.findall(r'src="(media/[^"]+\.(?:jpg|png|heic|webp))"', seg)
        if not images and not caption:
            continue
        lines = [l.strip() for l in caption.splitlines() if l.strip() and not l.strip().startswith("#")]
        out.append({
            "account": account,
            "archived": archived,
            "first": lines[0] if lines else "",
            "second": lines[1] if len(lines) > 1 else "",
            "caption": caption,
            "tags": re.findall(r"#([^\s#]+)", caption),
            "taken": taken_at(seg),
            "posted": posted_at(date),
            "images": sorted(set(images)),
        })
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("folders", nargs="+")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    posts: list[dict] = []
    for folder in a.folders:
        root = Path(folder)
        account = root.name
        media = root / "your_instagram_activity" / "media"
        for f in sorted(media.glob("posts.html")):  # posts_1.html は同じ写真の重複だった
            posts += parse(f, account, False)
        if (media / "archived_posts.html").exists():
            posts += parse(media / "archived_posts.html", account, True)
    Path(a.out).write_text(json.dumps(posts, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{len(posts)} 件 → {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
