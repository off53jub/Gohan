# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "pillow-heif"]
# ///
"""見た目で pCloud の写真と結べたインスタの投稿を、ごはん帖の取り込みファイルにする（大2。2026-11-28）。

    uv run insta_visual_apply.py verified.json --photos D:\\GohanImport\\toshu\\photos.json \\
        --meals D:\\GohanImport\\toshu\\out3 --out <書き出すファイル>

- 特徴点が 100 点以上そろったものだけ使う（同じ 1 枚。6 点ほどのものは別の写真だった）。
- 結べた写真の撮った時刻の前後 3 時間に、もう取り込んだ食事があれば、その食事にお店だけ入れる（写真は入れない）。
- 無ければ、その写真で新しい食事を作る（ラーメン・外食。写真は長い辺 1024 px の JPEG）。
- お店は店名と街だけ・自信 0.85（撮った時刻が写真で分かっているので「確か」）。
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image
from pillow_heif import register_heif_opener

sys.path.insert(0, str(Path(__file__).parent))
from insta_apply import SURE, split_first  # noqa: E402

register_heif_opener()
MIN_INLIERS = 100
NEAR = timedelta(hours=3)


def jpeg(path: str) -> str:
    im = Image.open(path).convert("RGB")
    im.thumbnail((1024, 1024))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=80)
    return base64.b64encode(buf.getvalue()).decode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("verified")
    ap.add_argument("--photos", required=True)
    ap.add_argument("--meals", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--names", help="1 行目 → [店名, 街] の手直し（1 行目が「再訪」などで店名が取れない投稿。PC の外に出さない）")
    a = ap.parse_args()
    rows = json.loads(Path(a.verified).read_text(encoding="utf-8"))
    names = json.loads(Path(a.names).read_text(encoding="utf-8")) if a.names else {}
    photos = {p["id"]: p for p in json.loads(Path(a.photos).read_text(encoding="utf-8"))}
    meals = []
    for f in sorted(Path(a.meals).glob("*.json")):
        for m in json.loads(f.read_text(encoding="utf-8"))["meals"]:
            meals.append(m)
    out, filled, made, skipped, weak = [], 0, 0, 0, 0
    used: set[int] = set()
    for r in rows:
        top = (r.get("verified") or [None])[0]
        if not top or top["inliers"] < MIN_INLIERS:
            weak += 1
            continue
        name, area = names.get(r["first"].strip()) or split_first(r["first"])
        if not name:
            skipped += 1
            continue
        photo = photos[top["id"]]
        t = datetime.fromisoformat(photo["date"])
        account = "@menrui_off" if r["account"].startswith("menrui") else "@offnuoff"
        place = {"name": name, "latitude": None, "longitude": None, "confidence": SURE, "area": area,
                 "reason": f"{account} の投稿「{r['first'][:30]}」から（写真が同じ）"}
        # 麺の食事を先に、次に時刻の近い順
        near = [((m.get("verdict") or {}).get("genre") not in ("ラーメン", "つけ麺"), abs(datetime.fromisoformat(m["date"]) - t), i)
                for i, m in enumerate(meals)
                if abs(datetime.fromisoformat(m["date"]) - t) <= NEAR and i not in used]
        if near:
            i = min(near)[2]
            used.add(i)
            m = dict(meals[i])
            m["photos"] = []
            m["place"] = place
            out.append(m)
            filled += 1
        else:
            out.append({
                "date": photo["date"], "endDate": photo["date"],
                "latitude": photo.get("lat"), "longitude": photo.get("lon"), "accuracy": photo.get("acc"),
                "verdict": {"is_meal": True, "eaten_out": True, "place_index": -1, "place_confidence": 0,
                            "genre": "ラーメン", "dishes": [], "summary": "", "kind": "meal", "reason": "", "name_seen": ""},
                "lines": [], "photos": [{"date": photo["date"], "jpeg": jpeg(photo["path"])}], "place": place,
            })
            made += 1
    made_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {"kind": "gohan.import", "version": 1, "made": made_at, "source": "Instagram", "meals": out}
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    print(f"{len(out)} 食 → {a.out}（前の食事にお店 {filled}・新しい食事 {made}）。"
          f"同じ写真が見つからない {weak}・店名でない {skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
