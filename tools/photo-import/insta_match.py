"""Instagram の投稿と、PC から取り込んだ食事を突き合わせる（大1。2026-11-28）。

    python -I tools/photo-import/insta_match.py <posts.json> <取り込みのファイルのフォルダ> --out match.json

- 投稿の「撮った日時」（無ければ投稿日時の 3 日前まで）と、同じ日の麺の食事を結ぶ。
- 撮った日時があれば、食事の時刻との差がいちばん小さいもの（6 時間まで）。
- 店名は投稿の 1 行目から取る（「街 店名」なら街を外す。「再訪」などは 2 行目も見る）。
ここでは結ぶだけで、取り込みのファイルは書き換えない。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9))
NOODLE = ("ラーメン", "らーめん", "つけ麺", "中華そば", "蕎麦", "麺", "二郎", "ramen", "まぜそば", "油そば", "担々")
SKIP_FIRST = ("再訪", "再々訪", "初訪問", "久々", "今日の", "本日の")


def is_noodle(post: dict) -> bool:
    t = post["caption"] + " " + " ".join(post["tags"])
    return any(w in t for w in NOODLE)


def shop_name(post: dict, areas: set[str]) -> str:
    first = post["first"].replace("　", " ").strip()
    if not first or any(first.startswith(w) for w in SKIP_FIRST):
        first = post["second"].replace("　", " ").strip()
    parts = first.split(" ")
    # 「神保町 黒須」「新宿 BUTAKIN 大ラーメン全マシ」: 頭の 1 語が街なら外す
    if len(parts) >= 2 and (parts[0] in areas or len(parts[0]) <= 4):
        parts = parts[1:]
    name = parts[0] if parts else ""
    if len(parts) >= 2 and len(parts[0]) <= 3:
        name = " ".join(parts[:2])
    return re.sub(r"[#＃].*$", "", name).strip()


def when(post: dict) -> tuple[datetime | None, bool]:
    """(時刻, 撮った時刻か)"""
    if post.get("taken"):
        return datetime.fromisoformat(post["taken"]), True
    if post.get("posted"):
        return datetime.fromisoformat(post["posted"].replace("Z", "+00:00")).astimezone(JST), False
    return None, False


def load_meals(folder: Path) -> list[dict]:
    meals = []
    for f in sorted(folder.glob("*.json")):
        for i, m in enumerate(json.loads(f.read_text(encoding="utf-8"))["meals"]):
            v = m.get("verdict") or {}
            meals.append({"file": f.name, "index": i, "date": datetime.fromisoformat(m["date"]),
                          "genre": v.get("genre"), "dishes": v.get("dishes") or [],
                          "has_place": bool(m.get("place"))})
    return meals


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("posts")
    ap.add_argument("meals")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    posts = json.loads(Path(a.posts).read_text(encoding="utf-8"))
    # 同じ写真の投稿は 1 つに（アーカイブと通常の両方に出ることがある）
    seen, uniq = set(), []
    for p in posts:
        key = tuple(p["images"]) or (p["caption"],)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(p)
    noodles = [p for p in uniq if is_noodle(p)]
    meals = [m for m in load_meals(Path(a.meals)) if m["genre"] in ("ラーメン", "つけ麺")]
    areas = {"新宿", "渋谷", "池袋", "上野", "神保町", "中野", "高田馬場", "秋葉原", "大阪", "横浜", "川崎", "吉祥寺", "荻窪"}
    used: set[tuple[str, int]] = set()
    out = []
    for p in sorted(noodles, key=lambda p: when(p)[0] or datetime.min.replace(tzinfo=JST)):
        t, exact = when(p)
        row = {"shop": shop_name(p, areas), "first": p["first"], "second": p["second"], "account": p["account"],
               "archived": p["archived"], "time": t.isoformat() if t else None, "exact": exact, "meal": None}
        if t:
            if exact:
                cands = [m for m in meals if abs((m["date"] - t).total_seconds()) <= 6 * 3600]
            else:
                cands = [m for m in meals if timedelta(0) <= t - m["date"] <= timedelta(days=3)]
            cands = [m for m in cands if (m["file"], m["index"]) not in used]
            if cands:
                best = min(cands, key=lambda m: abs((m["date"] - t).total_seconds()))
                used.add((best["file"], best["index"]))
                row["meal"] = {"file": best["file"], "index": best["index"], "date": best["date"].isoformat(),
                               "dishes": best["dishes"], "had_place": best["has_place"]}
        out.append(row)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    hit = sum(1 for r in out if r["meal"])
    print(f"麺の投稿 {len(noodles)} 件（重なりを除く）・食事と結べた {hit} 件"
          f"（撮った時刻で {sum(1 for r in out if r['meal'] and r['exact'])}・投稿日で {sum(1 for r in out if r['meal'] and not r['exact'])}）"
          f"・もともとお店が付いていなかった {sum(1 for r in out if r['meal'] and not r['meal']['had_place'])} 件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
