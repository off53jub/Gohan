"""Instagram の投稿と結べた食事を、ごはん帖の取り込みファイルにする（大1。2026-11-28）。

    python -I tools/photo-import/insta_apply.py <match.json> <取り込みのファイルのフォルダ> --out <書き出すファイル>

- 中身は「もう取り込んだ食事」と同じ日時・同じ答えで、写真は入れない（アプリは同じ食事と見て、お店だけを入れる）。
- お店は店名と街だけ（場所はアプリが地図で探す）。撮った時刻が合ったものは自信 0.85（確か）、
  投稿日から結んだものは 0.5（「たぶん」）。
- 「ハシゴ」「1杯目」のような、店名ではない 1 行目は入れない。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

NOT_NAME = ("ハシゴ", "杯目", "遠征", "編", "以前", "ぶり", "限定", "。", "、", "!", "！", "?", "？", "言葉", "今日", "本日",
            "再訪", "カップ", "ペヤング", "日清", "宅麺", "セブン", "ローソン", "ファミマ", "チートデイ")
SHOP_MARK = ("屋", "店", "家", "亭", "軒", "堂", "処", "庵")
NOODLE = ("ラーメン", "らーめん", "つけ麺", "つけめん", "まぜそば", "油そば", "中華そば", "ソバ", "蕎麦", "麺", "そば")
DISH_HEAD = ("小", "大", "並", "中盛", "特製", "味玉", "チャーシュー", "濃厚", "醤油", "塩", "味噌", "煮干", "全部")
DISH_MARK = ("並", "盛", "マシ", "コール", "トッピング", "&", "＆", "+", "＋")
SURE = 0.85
MAYBE = 0.5


def dish_like(t: str) -> bool:
    if any(m in t for m in SHOP_MARK):
        return False
    if any(m in t for m in DISH_MARK):
        return True
    return any(w in t for w in NOODLE) and (t.startswith(DISH_HEAD) or t.endswith(NOODLE))


def split_first(first: str) -> tuple[str | None, str | None]:
    """投稿の 1 行目 →（店名, 街）。「12/26 豚山 小ラーメン」「青葉台 らぁ麺すぎ本 醤油ワンタン」「池田屋 高田馬場店 ラーメン」"""
    tokens = [t for t in re.split(r"[\s　]+", first.strip()) if t]
    if tokens and re.fullmatch(r"\d{1,2}/\d{1,2}", tokens[0]):
        tokens = tokens[1:]
    if not tokens:
        return None, None
    head = tokens[0]
    # 「1/25 神保町」のように街の名前しか無いときは、店名が分からない
    if len(tokens) == 1 and len(head) <= 4 and not any(m in head for m in SHOP_MARK):
        return None, None
    area = None
    shop_i = 0
    if len(tokens) >= 2 and len(head) <= 5 and not any(m in head for m in SHOP_MARK) and not dish_like(tokens[1]):
        area, shop_i = head, 1
    name = tokens[shop_i]
    # 「池田屋 高田馬場店」のように、次が支店名ならつなぐ
    if shop_i + 1 < len(tokens) and tokens[shop_i + 1].endswith("店") and len(tokens[shop_i + 1]) <= 8:
        name += " " + tokens[shop_i + 1]
    return clean(name), area


def clean(name: str) -> str | None:
    name = re.sub(r"[（(].*?[）)]", "", name).strip()
    if not (2 <= len(name) <= 24):
        return None
    if any(w in name for w in NOT_NAME):
        return None
    if re.fullmatch(r"[\d\s年月日/]+", name) or dish_like(name):
        return None
    return name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("match")
    ap.add_argument("meals")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rows = json.loads(Path(a.match).read_text(encoding="utf-8"))
    files: dict[str, list] = {}
    out_meals = []
    skipped = 0
    for r in rows:
        meal = r.get("meal")
        if not meal:
            continue
        name, area = split_first(r["first"])
        if not name:
            skipped += 1
            continue
        src = files.setdefault(meal["file"], json.loads((Path(a.meals) / meal["file"]).read_text(encoding="utf-8"))["meals"])
        m = dict(src[meal["index"]])
        m["photos"] = []
        sure = r["exact"]
        account = "@menrui_off" if r["account"].startswith("menrui") else "@offnuoff"
        m["place"] = {
            "name": name,
            "latitude": None,
            "longitude": None,
            "confidence": SURE if sure else MAYBE,
            "reason": f"{account} の投稿「{r['first'][:30]}」から" + ("（撮った時刻が同じ）" if sure else "（投稿した日から）"),
            "area": area,
        }
        out_meals.append(m)
    made = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {"kind": "gohan.import", "version": 1, "made": made, "source": "Instagram", "meals": out_meals}
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    sure = sum(1 for m in out_meals if m["place"]["confidence"] == SURE)
    print(f"{len(out_meals)} 食（確か {sure}・たぶん {len(out_meals) - sure}）→ {a.out}。店名でないので外した {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
