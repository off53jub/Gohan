# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "pillow-heif"]
# ///
"""ごはん帖: PC にある写真（pCloud・Google フォトの書き出し）から、取り込み用のファイルを作る。

ご飯かどうか・料理の名前・看板の店名は、Claude Code の会話の中で見る（アプリの API は使わない）。
流れ（くわしくは README.md）:
  1. scan    写真の一覧（撮った時刻・位置）を作る          → work/photos.json
  2. sheets  20 枚ずつの一覧画像を作る                   → work/sheets/*.jpg
     （Claude が見て work/screen.json を書く: {"p0001": "food" | "clue" | "no"}）
  3. group   ご飯の写真を食事にまとめ、食事ごとの画像を作る → work/meals.json, work/meals/*.jpg
  4. nearby  食事の場所の近くのお店を OpenStreetMap で調べる  → work/meals.json の candidates
     （Claude が画像と候補を見て work/verdicts.json を書く。お店も選ぶ）
  5. pack    アプリで読むファイルを作る                   → ごはん帖の取り込み-*.json

写真は作業フォルダ（既定 D:\\GohanImport）にだけ置く。公開リポジトリには入れない。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:  # HEIC が無ければ要らない
    pass

DEFAULT_WORK = Path(r"D:\GohanImport")
JST = timezone(timedelta(hours=9))
PHOTO_EXT = {".heic", ".heif", ".jpg", ".jpeg"}
MEAL_GAP_MIN = 40      # アプリの Matcher.groupMeals と同じ
MEAL_GAP_M = 250
CLUE_WINDOW_MIN = 30
CLUE_DIST_M = 300
GENRES = ["ラーメン", "つけ麺", "そば・うどん", "寿司", "和食", "定食", "丼", "焼肉", "焼き鳥", "居酒屋",
          "中華", "韓国料理", "カレー", "エスニック", "イタリアン", "フレンチ", "洋食", "ハンバーガー",
          "ファストフード", "カフェ", "スイーツ", "パン", "バー", "鍋", "お好み焼き", "その他"]


# ---------------------------------------------------------------- 共通

def load(path: Path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def save(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def distance_m(a, b) -> float | None:
    if a.get("lat") is None or b.get("lat") is None:
        return None
    r = 6371000
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    dp = p2 - p1
    dl = math.radians(b["lon"] - a["lon"])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def when(p) -> datetime:
    return datetime.fromisoformat(p["date"])


def open_image(path: str, side: int) -> Image.Image:
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    im.thumbnail((side, side))
    return im.convert("RGB")


def font(size: int):
    for name in ("meiryo.ttc", "msgothic.ttc", "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


# ---------------------------------------------------------------- 1. scan

def parse_exif_date(value: str | None, offset: str | None) -> datetime | None:
    if not value or value.startswith("0000"):
        return None
    try:
        d = datetime.strptime(value[:19], "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None
    tz = JST
    if offset and len(offset) >= 6 and offset[0] in "+-":
        sign = 1 if offset[0] == "+" else -1
        tz = timezone(sign * timedelta(hours=int(offset[1:3]), minutes=int(offset[4:6])))
    return d.replace(tzinfo=tz)


def takeout_sidecar(path: Path) -> dict | None:
    """Google フォトの書き出し（Takeout）は、時刻と位置を横の .json に入れている"""
    for cand in (path.with_name(path.name + ".json"), path.with_name(path.name + ".supplemental-metadata.json")):
        if cand.exists():
            try:
                return json.loads(cand.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return None
    return None


def cmd_scan(args) -> None:
    work = Path(args.work)
    since = datetime.fromisoformat(args.since).replace(tzinfo=JST) if args.since else None
    until = datetime.fromisoformat(args.until).replace(tzinfo=JST) + timedelta(days=1) if args.until else None
    old = {p["path"]: p for p in load(work / "photos.json", [])}
    # 何万枚もあると 1 本の exiftool では何時間もかかり、途中も見えない。
    # すぐ下のフォルダ（年ごとなど）に分けて、新しい順に同時に読む。読み終えた分は scan-parts に残し、やり直しでは飛ばす
    jobs: list[tuple[str, bool]] = []
    for source in args.source:
        subs = sorted((d for d in Path(source).iterdir() if d.is_dir()), key=lambda d: d.name, reverse=True)
        jobs += [(str(d), True) for d in subs] + [(source, False)]
    parts = work / "scan-parts"
    parts.mkdir(parents=True, exist_ok=True)

    def read(job: tuple[str, bool]) -> list[dict]:
        folder, recursive = job
        # 引数ファイルの名前も日本語だと exiftool が開けないので、英数字だけにする
        key = hashlib.sha1(folder.encode("utf-8")).hexdigest()[:12] + ("" if recursive else "_top")
        cached = parts / f"{key}.json"
        if cached.exists():
            return load(cached, [])
        started = time.time()
        # Windows では日本語のフォルダ名をコマンドの引数で渡すと exiftool が読めない → UTF-8 の引数ファイルで渡す
        argfile = parts / f"{key}.args"
        argfile.write_text(folder + "\n", encoding="utf-8")
        out = subprocess.run(
            ["exiftool", "-json", "-n", *(["-r"] if recursive else []), "-q", "-q", "-charset", "filename=utf8",
             *sum((["-ext", e.lstrip(".")] for e in PHOTO_EXT), []),
             "-DateTimeOriginal", "-OffsetTimeOriginal", "-CreateDate", "-GPSLatitude", "-GPSLongitude",
             "-GPSHPositioningError", "-Model", "-@", str(argfile)],
            capture_output=True, check=False)
        found = json.loads(out.stdout.decode("utf-8") or "[]")
        save(cached, found)
        print(f"  読み終えた: {folder}{'' if recursive else '（直下）'} {len(found)} 枚・{(time.time() - started) / 60:.0f} 分",
              flush=True)
        return found

    print(f"写真を読んでいます: {len(jobs)} フォルダを {args.threads} 本ずつ", flush=True)
    rows = []
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        for found in pool.map(read, jobs):
            rows += found
    photos = []
    for r in rows:
        path = Path(r["SourceFile"])
        date = parse_exif_date(r.get("DateTimeOriginal"), r.get("OffsetTimeOriginal"))
        lat, lon = r.get("GPSLatitude"), r.get("GPSLongitude")
        side = takeout_sidecar(path) if date is None or lat is None else None
        if side:
            ts = (side.get("photoTakenTime") or {}).get("timestamp")
            if date is None and ts:
                date = datetime.fromtimestamp(int(ts), tz=timezone.utc).astimezone(JST)
            geo = side.get("geoDataExif") or side.get("geoData") or {}
            if lat is None and geo.get("latitude"):
                lat, lon = geo["latitude"], geo["longitude"]
        # カメラで撮っていない画像（保存した画像・スクリーンショット）は外す
        if date is None or not r.get("Model"):
            continue
        if (since and date < since) or (until and date >= until):
            continue
        photos.append({"path": str(path), "date": date.isoformat(timespec="seconds"),
                       "lat": lat, "lon": lon, "acc": r.get("GPSHPositioningError")})
    photos.sort(key=lambda p: p["date"])
    # 前に付けた番号は変えない（Claude の答えとずれないように）
    used = {int(p["id"][1:]) for p in old.values()}
    next_id = max(used, default=0) + 1
    for p in photos:
        if p["path"] in old:
            p["id"] = old[p["path"]]["id"]
        else:
            p["id"] = f"p{next_id:05d}"
            next_id += 1
    save(work / "photos.json", photos)
    print(f"{len(photos)} 枚（新しく {sum(1 for p in photos if p['path'] not in old)} 枚）", flush=True)


# ---------------------------------------------------------------- 2. sheets

def make_thumb(work: Path, p) -> Path | None:
    out = work / "thumbs" / f"{p['id']}.jpg"
    if out.exists():
        return out
    try:
        im = open_image(p["path"], 768)
    except Exception as e:  # 壊れた写真・読めない形式
        print(f"  読めません: {p['path']} ({e})", file=sys.stderr)
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, quality=82)
    return out


def tile(images: list[tuple[str, Path]], cols: int, cell: int, out: Path) -> None:
    rows = math.ceil(len(images) / cols)
    sheet = Image.new("RGB", (cols * cell, rows * (cell + 22)), "white")
    draw = ImageDraw.Draw(sheet)
    f = font(16)
    for i, (label, path) in enumerate(images):
        x, y = (i % cols) * cell, (i // cols) * (cell + 22)
        im = Image.open(path)
        im.thumbnail((cell - 4, cell - 4))
        sheet.paste(im, (x + (cell - im.width) // 2, y + 22 + (cell - im.height) // 2))
        draw.text((x + 4, y + 2), label, fill="black", font=f)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, quality=80)


def cmd_sheets(args) -> None:
    work = Path(args.work)
    photos = load(work / "photos.json", [])
    screen = load(work / "screen.json", {})
    todo = [p for p in photos if p["id"] not in screen]
    print(f"小さな写真を作っています: {len(todo)} 枚", flush=True)
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        thumbs = list(pool.map(lambda p: make_thumb(work, p), todo))
    ready = [(p, t) for p, t in zip(todo, thumbs) if t]
    for old in (work / "sheets").glob("*.jpg"):
        old.unlink()
    per = 20
    for n in range(0, len(ready), per):
        chunk = ready[n:n + per]
        tile([(f"{p['id']} {when(p):%m/%d %H:%M}", t) for p, t in chunk], cols=5, cell=256,
             out=work / "sheets" / f"sheet{n // per + 1:03d}.jpg")
    print(f"一覧画像 {math.ceil(len(ready) / per)} 枚 → {work / 'sheets'}", flush=True)


# ---------------------------------------------------------------- 3. group

def cmd_group(args) -> None:
    work = Path(args.work)
    photos = load(work / "photos.json", [])
    screen = load(work / "screen.json", {})
    done = load(work / "verdicts.json", {})
    food = [p for p in photos if screen.get(p["id"]) == "food"]
    clues = [p for p in photos if screen.get(p["id"]) == "clue"]
    groups: list[list[dict]] = []
    for p in food:
        last = groups[-1][-1] if groups else None
        if last and (when(p) - when(last)) <= timedelta(minutes=MEAL_GAP_MIN):
            d = distance_m(p, last)
            if d is None or d <= MEAL_GAP_M:
                groups[-1].append(p)
                continue
        groups.append([p])
    meals = []
    for g in groups:
        start, end = when(g[0]), when(g[-1])
        center = next((x for x in g if x.get("lat") is not None), None)
        near = [c for c in clues
                if start - timedelta(minutes=CLUE_WINDOW_MIN) <= when(c) <= end + timedelta(minutes=CLUE_WINDOW_MIN)
                and (center is None or (distance_m(c, center) or 0) <= CLUE_DIST_M)]
        mid = "m" + g[0]["id"][1:]   # 最初の写真の番号から作る（やり直しても同じ番号）
        acc = [x["acc"] for x in g if x.get("acc")]
        meals.append({"id": mid, "date": g[0]["date"], "end": g[-1]["date"], "food": [x["id"] for x in g],
                      "clues": [c["id"] for c in near][:3],
                      "lat": center["lat"] if center else None, "lon": center["lon"] if center else None,
                      "acc": round(min(acc)) if acc else None})
    old = {m["id"]: m for m in load(work / "meals.json", [])}
    for m in meals:   # 前に調べた近くのお店は残す
        if "candidates" in old.get(m["id"], {}):
            m["candidates"] = old[m["id"]]["candidates"]
    save(work / "meals.json", meals)
    by_id = {p["id"]: p for p in photos}
    todo = [m for m in meals if m["id"] not in done]
    for old in (work / "meals").glob("*.jpg"):
        old.unlink()
    for m in todo:
        ids = spread(m["food"], 4) + m["clues"][:2]
        items = [(f"{i} {'看板など' if i in m['clues'] else '料理'} {when(by_id[i]):%Y/%m/%d %H:%M}", work / "thumbs" / f"{i}.jpg")
                 for i in ids if (work / "thumbs" / f"{i}.jpg").exists()]
        tile(items, cols=3, cell=512, out=work / "meals" / f"{m['id']}.jpg")
    print(f"食事 {len(meals)} 回（まだ見ていない {len(todo)} 回）→ {work / 'meals'}", flush=True)


def spread(ids: list[str], count: int) -> list[str]:
    if len(ids) <= count:
        return list(ids)
    step = (len(ids) - 1) / (count - 1)
    return [ids[round(i * step)] for i in range(count)]


# ---------------------------------------------------------------- 4. nearby

OVERPASS = ["https://overpass-api.de/api/interpreter", "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"]
HEADERS = {"User-Agent": "gohan-photo-import/1.0"}


def address(lat: float, lon: float) -> str:
    """住所（OpenStreetMap の Nominatim。1 秒に 1 回まで）"""
    url = "https://nominatim.openstreetmap.org/reverse?" + urllib.parse.urlencode(
        {"format": "jsonv2", "lat": lat, "lon": lon, "zoom": 18, "accept-language": "ja"})
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30) as r:
        a = json.loads(r.read().decode("utf-8")).get("address", {})
    parts = [a.get(k, "") for k in ("province", "state", "city", "town", "suburb", "quarter", "neighbourhood", "road")]
    return " ".join(dict.fromkeys(x for x in parts if x))


def overpass(lat: float, lon: float, radius: int) -> list[dict]:
    q = f"""[out:json][timeout:25];
(nwr(around:{radius},{lat},{lon})["amenity"~"^(restaurant|cafe|fast_food|bar|pub|food_court|ice_cream|biergarten)$"]["name"];
 nwr(around:{radius},{lat},{lon})["shop"~"^(bakery|confectionery|pastry|deli|tea|coffee)$"]["name"];);
out center tags;"""
    elements = None
    for server in OVERPASS:
        try:
            req = urllib.request.Request(server, data=urllib.parse.urlencode({"data": q}).encode(), headers=HEADERS)
            with urllib.request.urlopen(req, timeout=35) as r:
                elements = json.loads(r.read().decode("utf-8")).get("elements", [])
            break
        except Exception as e:  # 混んでいる・時間切れ → 次のサーバー
            print(f"    {server.split('/')[2]}: {e}", file=sys.stderr, flush=True)
    if elements is None:
        raise RuntimeError("どのサーバーも答えませんでした")
    out = []
    here = {"lat": lat, "lon": lon}
    for e in elements:
        t = e.get("tags", {})
        la, lo = e.get("lat") or (e.get("center") or {}).get("lat"), e.get("lon") or (e.get("center") or {}).get("lon")
        if la is None:
            continue
        name = t.get("name:ja") or t.get("name")
        out.append({"name": name, "lat": la, "lon": lo, "dist": round(distance_m(here, {"lat": la, "lon": lo})),
                    "kind": t.get("amenity") or t.get("shop"), "cuisine": t.get("cuisine", ""),
                    "branch": t.get("branch", ""), "floor": t.get("level", "")})
    out.sort(key=lambda c: c["dist"])
    return out[:30]


TILE = 0.02   # 約 2km 四方。食事が何千回でも、Overpass への問い合わせはタイルの数だけで済む


def overpass_box(s: float, w: float, n: float, e: float) -> list[dict]:
    q = f"""[out:json][timeout:90];
(nwr({s},{w},{n},{e})["amenity"~"^(restaurant|cafe|fast_food|bar|pub|food_court|ice_cream|biergarten)$"]["name"];
 nwr({s},{w},{n},{e})["shop"~"^(bakery|confectionery|pastry|deli|tea|coffee)$"]["name"];);
out center tags;"""
    last = None
    for attempt in range(3):
        for server in OVERPASS:
            try:
                req = urllib.request.Request(server, data=urllib.parse.urlencode({"data": q}).encode(), headers=HEADERS)
                with urllib.request.urlopen(req, timeout=120) as r:
                    elements = json.loads(r.read().decode("utf-8")).get("elements", [])
                out = []
                for el in elements:
                    t = el.get("tags", {})
                    la = el.get("lat") or (el.get("center") or {}).get("lat")
                    lo = el.get("lon") or (el.get("center") or {}).get("lon")
                    if la is not None:
                        out.append({"name": t.get("name:ja") or t.get("name"), "lat": la, "lon": lo,
                                    "kind": t.get("amenity") or t.get("shop"), "cuisine": t.get("cuisine", ""),
                                    "branch": t.get("branch", ""), "floor": t.get("level", "")})
                return out
            except Exception as ex:
                last = ex
                print(f"    {server.split('/')[2]}: {ex}", file=sys.stderr, flush=True)
        time.sleep(10 * (attempt + 1))
    raise RuntimeError(f"どのサーバーも答えませんでした（{last}）")


def cmd_nearby_tiles(args) -> None:
    """食事の多いとき: 2km 四方ずつまとめて OpenStreetMap のお店を取り、食事ごとの候補はこちらで計算する"""
    work = Path(args.work)
    meals = load(work / "meals.json", [])
    cache = work / "osm"
    cache.mkdir(parents=True, exist_ok=True)
    keys = sorted({(math.floor(m["lat"] / TILE), math.floor(m["lon"] / TILE)) for m in meals if m.get("lat") is not None})
    todo = [k for k in keys if not (cache / f"{k[0]}_{k[1]}.json").exists()]
    print(f"お店の地図: {len(keys)} 区画（まだ {len(todo)}）", flush=True)
    margin = 0.005   # 区画の端の食事のため、少しはみ出して取る（約 500m）
    for i, (a, b) in enumerate(todo):
        try:
            shops = overpass_box(a * TILE - margin, b * TILE - margin, (a + 1) * TILE + margin, (b + 1) * TILE + margin)
        except Exception as e:  # あとでもう一度流せば、ここだけやり直す
            print(f"  {a}_{b}: {e}", file=sys.stderr, flush=True)
            continue
        save(cache / f"{a}_{b}.json", shops)
        print(f"  {i + 1}/{len(todo)} {a}_{b}: {len(shops)} 軒", flush=True)
        time.sleep(2)
    done = 0
    for m in meals:
        if m.get("lat") is None:
            continue
        f = cache / f"{math.floor(m['lat'] / TILE)}_{math.floor(m['lon'] / TILE)}.json"
        if not f.exists():
            continue
        acc = m.get("acc") or 30
        radius = 400 if acc > 65 else int(max(120, min(300, acc * 3)))
        near = []
        for s in load(f, []):
            d = distance_m(m, s)
            if d is not None and d <= radius:
                near.append({**s, "dist": round(d)})
        near.sort(key=lambda c: c["dist"])
        m["candidates"] = near[:30]
        done += 1
    save(work / "meals.json", meals)
    print(f"近くのお店を付けた食事: {done} 回", flush=True)


def cmd_nearby(args) -> None:
    work = Path(args.work)
    if args.tiles:
        return cmd_nearby_tiles(args)
    meals = load(work / "meals.json", [])
    todo = [m for m in meals if m.get("lat") is not None and ("candidates" not in m or "address" not in m)]
    print(f"近くのお店を調べています: {len(todo)} 回", flush=True)
    for i, m in enumerate(todo):
        if "address" not in m:
            try:
                m["address"] = address(m["lat"], m["lon"])
            except Exception as e:
                print(f"  {m['id']} 住所: {e}", file=sys.stderr, flush=True)
        if "candidates" not in m:
            acc = m.get("acc") or 30
            radius = 400 if acc > 65 else int(max(120, min(300, acc * 3)))
            try:
                m["candidates"] = overpass(m["lat"], m["lon"], radius)
            except Exception as e:  # あとでもう一度 nearby を流せば、ここだけやり直す
                print(f"  {m['id']} お店: {e}", file=sys.stderr, flush=True)
        save(work / "meals.json", meals)
        print(f"  {i + 1}/{len(todo)} {m['id']}: {len(m.get('candidates', []))} 軒", flush=True)
        time.sleep(1.5)   # 無料のサーバーなので、ゆっくり


# ---------------------------------------------------------------- 5. pack

def jpeg_b64(path: str, side: int) -> str:
    im = open_image(path, side)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=75)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def check_verdict(mid: str, v: dict) -> list[str]:
    problems = []
    for key in ("is_meal", "eaten_out", "genre", "dishes", "summary", "kind", "name_seen"):
        if key not in v:
            problems.append(f"{mid}: {key} がありません")
    if v.get("genre") not in GENRES:
        problems.append(f"{mid}: genre「{v.get('genre')}」は一覧にありません")
    if v.get("kind") not in ("meal", "cafe", "snack", "drink"):
        problems.append(f"{mid}: kind「{v.get('kind')}」")
    if v.get("place_name") and not isinstance(v.get("place_confidence"), (int, float)):
        problems.append(f"{mid}: place_confidence がありません")
    return problems


def cmd_pack(args) -> None:
    work = Path(args.work)
    photos = {p["id"]: p for p in load(work / "photos.json", [])}
    meals = load(work / "meals.json", [])
    by_meal = {m["id"]: m for m in meals}
    verdicts = load(work / "verdicts.json", {})
    packed = set(load(work / "packed.json", []))
    problems = [x for m in meals if m["id"] in verdicts for x in check_verdict(m["id"], verdicts[m["id"]])]
    if problems:
        sys.exit("答えに足りないところがあります:\n" + "\n".join(problems))
    todo = [m for m in meals if m["id"] in verdicts and (args.all or m["id"] not in packed)]
    # 自信のないもの（Claude が unsure と書いた）・食事でないものは載せない（本人の方針。2026-11-25）
    unsure = [m for m in todo if verdicts[m["id"]].get("unsure") or not verdicts[m["id"]]["is_meal"]]
    todo = [m for m in todo if m not in unsure]
    # 別の作業フォルダでもう入れた食事（前後 45 分）は飛ばす
    other = []
    for w in args.skip_near or []:
        om = {x["id"]: x for x in load(Path(w) / "meals.json", [])}
        other += [datetime.fromisoformat(om[i]["date"]) for i in load(Path(w) / "packed.json", []) if i in om]
    near = [m for m in todo if any(abs(datetime.fromisoformat(m["date"]) - d) <= timedelta(minutes=45) for d in other)]
    todo = [m for m in todo if m not in near]
    print(f"載せる {len(todo)} 食（自信なし・食事でない {len(unsure)}、ほかで入れた {len(near)} は飛ばす）", flush=True)
    if not todo:
        print("新しく入れる食事はありません")
        return
    todo.sort(key=lambda m: m["date"], reverse=True)   # 新しい年から
    for n in range(0, len(todo), args.per_file):
        pack_file(args, work, todo[n:n + args.per_file], photos, by_meal, verdicts, n // args.per_file + 1)
        packed |= {m["id"] for m in todo[n:n + args.per_file]}
        save(work / "packed.json", sorted(packed))


def pack_file(args, work: Path, todo, photos, by_meal, verdicts, part: int) -> None:
    out_meals = []
    for m in todo:
        v = verdicts[m["id"]]
        food = [photos[i] for i in m["food"] if i in photos]
        located = [p for p in food if p.get("lat") is not None]
        acc = [p["acc"] for p in located if p.get("acc")]
        verdict = {"is_meal": bool(v["is_meal"]), "eaten_out": bool(v["eaten_out"]), "place_index": -1,
                   "place_confidence": 0, "genre": v["genre"], "dishes": v["dishes"], "summary": v["summary"],
                   "kind": v["kind"], "reason": "", "name_seen": v.get("name_seen", "")}
        out_meals.append({
            "date": food[0]["date"], "endDate": food[-1]["date"],
            "latitude": located[0]["lat"] if located else None,
            "longitude": located[0]["lon"] if located else None,
            "accuracy": min(acc) if acc else None,
            "verdict": verdict, "lines": v.get("lines", []),
            "photos": [{"date": p["date"], "jpeg": jpeg_b64(p["path"], args.side)} for p in spread([p for p in food], args.max_photos)]
            if v["is_meal"] else [],
        })
        place = None
        if v.get("place_name") and float(v.get("place_confidence", 0)) >= args.min_place:
            hit = next((c for c in by_meal[m["id"]].get("candidates", []) if c["name"] == v["place_name"]), None)
            place = {"name": v["place_name"], "latitude": hit["lat"] if hit else None, "longitude": hit["lon"] if hit else None,
                     "confidence": float(v.get("place_confidence", 0.5)), "reason": v.get("place_reason", "")}
        out_meals[-1]["place"] = place
        print(f"  {m['id']} {food[0]['date'][:16]} {v['summary']} @ {v.get('place_name') or '-'}", flush=True)
    stamp = datetime.now(JST).strftime("%Y%m%d-%H%M")
    first, last = todo[-1]["date"][:7], todo[0]["date"][:7]
    out = Path(args.out or work) / f"ごはん帖の取り込み-{stamp}-{part:02d}（{first}〜{last}）.json"
    data = {"kind": "gohan.import", "version": 1, "made": datetime.now(JST).isoformat(timespec="seconds"),
            "source": args.label, "meals": out_meals}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    size = out.stat().st_size / 1_000_000
    print(f"{len(out_meals)} 食 → {out}（{size:.1f} MB）", flush=True)


# ---------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=str(DEFAULT_WORK), help="作業フォルダ（写真の写しを置く。リポジトリの外に）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--source", action="append", required=True, help="写真のフォルダ（何回でも）")
    s.add_argument("--since", help="この日から（YYYY-MM-DD）")
    s.add_argument("--until", help="この日まで（YYYY-MM-DD）")
    s.add_argument("--threads", type=int, default=4, help="同時に読むフォルダの数")
    s.set_defaults(func=cmd_scan)
    s = sub.add_parser("sheets")
    s.add_argument("--threads", type=int, default=8)
    s.set_defaults(func=cmd_sheets)
    sub.add_parser("group").set_defaults(func=cmd_group)
    s = sub.add_parser("nearby")
    s.add_argument("--tiles", action="store_true", help="食事が多いとき: 2km 四方ずつまとめて取る（住所は付けない）")
    s.set_defaults(func=cmd_nearby)
    s = sub.add_parser("pack")
    s.add_argument("--out", help="ファイルを置くフォルダ（既定は作業フォルダ）")
    s.add_argument("--label", default="PC", help="どこの写真か（アプリに表示）")
    s.add_argument("--all", action="store_true", help="前に入れた食事も入れ直す")
    s.add_argument("--per-file", type=int, default=150, help="1 つのファイルに入れる食事の数（iPhone で一度に読む量）")
    s.add_argument("--side", type=int, default=1280, help="写真の長い辺（px）")
    s.add_argument("--max-photos", type=int, default=6, help="1 食あたりの写真の数")
    s.add_argument("--min-place", type=float, default=0.0, help="この自信より低いお店は載せない（アプリに任せる）")
    s.add_argument("--skip-near", action="append", help="別の作業フォルダでもう入れた食事を飛ばす（何回でも）")
    s.set_defaults(func=cmd_pack)
    args = ap.parse_args()
    if Path(args.work).resolve().is_relative_to(Path(__file__).resolve().parents[2]):
        sys.exit("作業フォルダはリポジトリの外にしてください（写真が公開されないように）")
    args.func(args)


if __name__ == "__main__":
    os.environ.setdefault("PYTHONUTF8", "1")
    main()
