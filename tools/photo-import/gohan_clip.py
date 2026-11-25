# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch==2.7.1", "torchvision==0.22.1", "open_clip_torch", "pillow", "pillow-heif"]
#
# [[tool.uv.index]]
# name = "pytorch-cu118"
# url = "https://download.pytorch.org/whl/cu118"
# explicit = true
#
# [tool.uv.sources]
# torch = { index = "pytorch-cu118" }
# torchvision = { index = "pytorch-cu118" }
# ///
"""ごはん帖: PC の無料モデル（CLIP）で、写真がご飯かどうか・ジャンルを一次判定する。

自信のあるものだけ答えを書き、自信のないものは Claude（軽いモデル）に回す。
  screen  写真ごと: food / clue / no           → work/clip.json, work/screen.json（自信のあるものだけ）
  meals   食事ごと: ジャンル・料理・お店で食べたか → work/verdicts.json（自信のあるものだけ）
しきい値は仮（D:\\GohanImport の 414 枚・40 食で Claude の答えと比べて決めた）。
"""
from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import gohan_import as gi

MODEL, PRETRAINED = "ViT-B-16", "datacomp_xl_s13b_b90k"

SCREEN = {
    "food": ["a close-up photo of food", "a photo of a meal on a table", "a photo of a plate of food at a restaurant",
             "a photo of a bowl of noodles", "a photo of sushi", "a photo of a dessert", "a photo of a drink in a glass",
             "a photo of a cup of coffee", "a photo of a bento box", "a photo of bread", "a photo of meat on a grill",
             "a photo of a hamburger", "a photo of a pizza", "a photo of a rice bowl", "a photo of ice cream"],
    "clue": ["a photo of a restaurant sign", "a photo of a restaurant storefront", "a photo of a restaurant menu",
             "a photo of a receipt", "a photo of a meal ticket vending machine", "a photo of a noren curtain at a shop entrance",
             "a photo of a shop signboard with japanese text", "a photo of a menu board on a wall"],
    "no": ["a photo of people", "a selfie", "a group photo of friends", "a photo of a landscape", "a photo of a city street",
           "a photo of a building", "a screenshot of a phone screen", "a photo of a document", "a photo of a car",
           "a photo of a room", "a photo of a cat", "a photo of a dog", "a photo of clothes", "a photo of a stage performance",
           "a photo of people dancing", "a photo of a train", "a photo of a computer screen", "a photo of the sky",
           "a photo of a toy or figure", "a photo of a whiteboard", "a photo of a mirror selfie", "a photo of a shopping mall",
           "a photo of a park", "a photo of a hotel room", "a photo of a television screen"],
}

# 料理（名前, ジャンル, CLIP への言い方）
DISHES = [
    ("醤油ラーメン", "ラーメン", "a bowl of soy sauce ramen with brown broth"),
    ("味噌ラーメン", "ラーメン", "a bowl of miso ramen"),
    ("豚骨ラーメン", "ラーメン", "a bowl of tonkotsu ramen with creamy white pork broth"),
    ("塩ラーメン", "ラーメン", "a bowl of shio ramen with clear golden broth"),
    ("家系ラーメン", "ラーメン", "a bowl of iekei ramen with spinach and large nori sheets"),
    ("二郎系ラーメン", "ラーメン", "a bowl of jiro style ramen piled high with bean sprouts, cabbage and thick pork"),
    ("担々麺", "ラーメン", "a bowl of spicy red tantanmen noodles"),
    ("まぜそば", "ラーメン", "a bowl of soupless mazesoba noodles with toppings"),
    ("ラーメン", "ラーメン", "a bowl of ramen noodle soup"),
    ("つけ麺", "つけ麺", "tsukemen: cold noodles on a plate with a separate bowl of thick dipping soup"),
    ("うどん", "そば・うどん", "a bowl of thick white udon noodles"),
    ("そば", "そば・うどん", "soba buckwheat noodles"),
    ("寿司", "寿司", "nigiri sushi"),
    ("海鮮丼", "丼", "a kaisendon bowl of raw seafood on rice"),
    ("刺身", "和食", "a plate of sashimi"),
    ("天ぷら", "和食", "japanese tempura"),
    ("和食", "和食", "a japanese kaiseki course dish"),
    ("定食", "定食", "a japanese teishoku set meal on a tray with rice, miso soup and a main dish"),
    ("とんかつ定食", "定食", "tonkatsu fried pork cutlet with shredded cabbage"),
    ("カツ丼", "丼", "a katsudon pork cutlet and egg rice bowl"),
    ("牛丼", "丼", "a gyudon beef rice bowl"),
    ("天丼", "丼", "a tendon tempura rice bowl"),
    ("親子丼", "丼", "an oyakodon chicken and egg rice bowl"),
    ("焼肉", "焼肉", "yakiniku: slices of meat grilled on a tabletop grill"),
    ("焼き鳥", "焼き鳥", "yakitori chicken skewers"),
    ("居酒屋の料理", "居酒屋", "izakaya small dishes with mugs of beer"),
    ("餃子", "中華", "gyoza dumplings"),
    ("チャーハン", "中華", "a plate of chinese fried rice"),
    ("麻婆豆腐", "中華", "mapo tofu"),
    ("小籠包", "中華", "xiaolongbao soup dumplings in a steamer"),
    ("中華料理", "中華", "chinese restaurant dishes"),
    ("韓国料理", "韓国料理", "korean food such as bibimbap, kimchi and samgyeopsal"),
    ("カレーライス", "カレー", "japanese curry rice"),
    ("インドカレー", "カレー", "indian curry with naan bread"),
    ("エスニック料理", "エスニック", "thai or vietnamese food such as pho or gapao rice"),
    ("ピザ", "イタリアン", "a pizza"),
    ("パスタ", "イタリアン", "a plate of spaghetti pasta"),
    ("フレンチ", "フレンチ", "an elegant french fine dining dish with sauce"),
    ("ハンバーグ", "洋食", "a japanese hamburg steak with demi-glace sauce"),
    ("オムライス", "洋食", "omurice: an omelette over rice with ketchup"),
    ("ステーキ", "洋食", "a grilled steak"),
    ("ハンバーガー", "ハンバーガー", "a hamburger"),
    ("ファストフード", "ファストフード", "fast food french fries and fried chicken"),
    ("コーヒー", "カフェ", "a cup of coffee or latte at a cafe"),
    ("カフェごはん", "カフェ", "a cafe lunch plate"),
    ("ケーキ", "スイーツ", "a slice of cake"),
    ("パフェ", "スイーツ", "a parfait in a tall glass"),
    ("かき氷", "スイーツ", "japanese shaved ice kakigori"),
    ("アイスクリーム", "スイーツ", "ice cream"),
    ("パンケーキ", "スイーツ", "a stack of pancakes"),
    ("和菓子", "スイーツ", "japanese wagashi sweets"),
    ("パン", "パン", "bread and pastries from a bakery"),
    ("カクテル", "バー", "a cocktail at a bar"),
    ("鍋", "鍋", "a japanese hot pot nabe"),
    ("しゃぶしゃぶ", "鍋", "shabu-shabu thin meat slices and a pot of broth"),
    ("お好み焼き", "お好み焼き", "okonomiyaki on an iron griddle"),
    ("もんじゃ焼き", "お好み焼き", "monjayaki on an iron griddle"),
    ("たこ焼き", "お好み焼き", "takoyaki octopus balls"),
    ("コンビニのごはん", "その他", "convenience store food in plastic packaging"),
]
KIND = {"カフェ": "cafe", "スイーツ": "snack", "パン": "snack", "バー": "drink"}
DISH_LIKE_GENRES = {"ラーメン", "つけ麺", "寿司", "焼肉", "焼き鳥", "カレー", "ハンバーガー", "パン", "鍋", "お好み焼き"}

HOME = ["a home-cooked meal on a dining table at home", "food in plastic takeout containers on a desk",
        "a convenience store meal at home", "home cooking on a kitchen counter"]
OUT = ["a meal served at a restaurant", "food on a restaurant counter", "a dish at a ramen shop counter",
       "food on a table in a restaurant"]


class Clip:
    def __init__(self):
        import open_clip
        import torch
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"モデルを読んでいます（{MODEL} / {self.device}）", flush=True)
        self.model, _, self.prep = open_clip.create_model_and_transforms(MODEL, pretrained=PRETRAINED, device=self.device)
        self.model.eval()
        if self.device == "cuda":
            self.model = self.model.half()
        self.tok = open_clip.get_tokenizer(MODEL)

    def text(self, prompts: list[str]):
        with self.torch.no_grad():
            t = self.model.encode_text(self.tok(prompts).to(self.device))
            return t / t.norm(dim=-1, keepdim=True)

    def images(self, paths: list[Path]):
        from PIL import Image
        x = self.torch.stack([self.prep(Image.open(p).convert("RGB")) for p in paths]).to(self.device)
        if self.device == "cuda":
            x = x.half()
        with self.torch.no_grad():
            v = self.model.encode_image(x)
            return v / v.norm(dim=-1, keepdim=True)


def softmax_groups(img, txt, sizes: list[int]):
    """全部の言い方で softmax を取り、グループごとに足す"""
    p = (100 * img @ txt.T).float().softmax(dim=-1)
    out, i = [], 0
    for s in sizes:
        out.append(p[:, i:i + s].sum(dim=-1))
        i += s
    return out, p


def cmd_screen(args) -> None:
    work = Path(args.work)
    photos = gi.load(work / "photos.json", [])
    result = gi.load(work / "clip.json", {})
    todo = [p for p in photos if p["id"] not in result]
    print(f"写真を見ています: {len(todo)} 枚", flush=True)
    clip = Clip()
    prompts = SCREEN["food"] + SCREEN["clue"] + SCREEN["no"]
    txt = clip.text(prompts)
    sizes = [len(SCREEN["food"]), len(SCREEN["clue"]), len(SCREEN["no"])]
    dish_txt = clip.text([d[2] for d in DISHES])
    io_txt = clip.text(HOME + OUT)
    batch = 256
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        for n in range(0, len(todo), batch):
            chunk = todo[n:n + batch]
            thumbs = list(pool.map(lambda p: gi.make_thumb(work, p), chunk))
            ready = [(p, t) for p, t in zip(chunk, thumbs) if t]
            for p, t in zip(chunk, thumbs):
                if not t:
                    result[p["id"]] = {"bad": True}
            if ready:
                img = clip.images([t for _, t in ready])
                (food, clue, no), _ = softmax_groups(img, txt, sizes)
                dish = (100 * img @ dish_txt.T).float().softmax(dim=-1)
                (home, out), _ = softmax_groups(img, io_txt, [len(HOME), len(OUT)])
                for k, (p, _) in enumerate(ready):
                    top = dish[k].topk(5)
                    result[p["id"]] = {"food": round(food[k].item(), 3), "clue": round(clue[k].item(), 3),
                                       "no": round(no[k].item(), 3), "out": round(out[k].item(), 3),
                                       "dish": {DISHES[i][0]: round(v, 3) for v, i in zip(top.values.tolist(), top.indices.tolist())}}
            gi.save(work / "clip.json", result)
            print(f"  {min(n + batch, len(todo))}/{len(todo)}", flush=True)
    decide_screen(work, photos, result, args)


def decide_screen(work: Path, photos, result, args) -> None:
    screen = gi.load(work / "screen.json", {})
    unsure = []
    for p in photos:
        if p["id"] in screen:
            continue
        r = result.get(p["id"])
        if not r or r.get("bad"):
            screen[p["id"]] = "no"
        elif r["food"] >= args.sure:
            screen[p["id"]] = "food"
        elif r["clue"] >= args.sure:
            screen[p["id"]] = "clue"
        elif r["no"] >= args.sure_no or r["food"] < 0.05:
            # 414 枚で比べると、ご飯の見込みが 5% 未満の迷いは、ほぼ全部ご飯ではなかった（手がかりは少し落とす）
            screen[p["id"]] = "no"
        else:
            unsure.append(p["id"])
    gi.save(work / "screen.json", screen)
    gi.save(work / "screen_unsure.json", unsure)
    count = {k: sum(1 for v in screen.values() if v == k) for k in ("food", "clue", "no")}
    print(f"決めた: ご飯 {count['food']}・手がかり {count['clue']}・ほか {count['no']} / 迷った {len(unsure)} 枚 → screen_unsure.json",
          flush=True)


def meal_guess(m, clip_result) -> dict:
    rows = [clip_result[i] for i in m["food"] if i in clip_result and not clip_result[i].get("bad")]
    genre: dict[str, float] = {}
    dish: dict[str, float] = {}
    for r in rows:
        for name, v in r["dish"].items():
            dish[name] = dish.get(name, 0) + v / len(rows)
            g = next(d[1] for d in DISHES if d[0] == name)
            genre[g] = genre.get(g, 0) + v / len(rows)
    out = sum(r["out"] for r in rows) / len(rows) if rows else 0.5
    best_g = max(genre, key=genre.get) if genre else "その他"
    in_g = {k: v for k, v in dish.items() if next(d[1] for d in DISHES if d[0] == k) == best_g}
    best_d = max(in_g, key=in_g.get) if in_g else best_g
    return {"genre": best_g, "genre_p": round(genre.get(best_g, 0), 3), "dish": best_d,
            "dish_p": round(in_g.get(best_d, 0) / max(genre.get(best_g, 1e-9), 1e-9), 3), "out": round(out, 3)}


def cmd_meals(args) -> None:
    work = Path(args.work)
    meals = gi.load(work / "meals.json", [])
    result = gi.load(work / "clip.json", {})
    verdicts = gi.load(work / "verdicts.json", {})
    guesses, sure = {}, 0
    for m in meals:
        g = meal_guess(m, result)
        guesses[m["id"]] = g
        if m["id"] in verdicts:
            continue
        decisive_out = g["out"] >= args.sure_out or g["out"] <= 1 - args.sure_out
        if g["genre_p"] >= args.sure_genre and decisive_out and g["genre"] != "その他":
            # 料理の細かい名前（醤油・味噌・二郎系など）は 40 食で比べると外れが多かった → ジャンルの名前だけにする
            dishes = [g["genre"]] if g["genre"] in DISH_LIKE_GENRES else []
            verdicts[m["id"]] = {"is_meal": True, "eaten_out": g["out"] >= 0.5, "genre": g["genre"], "dishes": dishes,
                                 "summary": g["genre"], "kind": KIND.get(g["genre"], "meal"), "name_seen": "", "lines": [],
                                 "from": "clip"}
            sure += 1
    gi.save(work / "clip_meals.json", guesses)
    gi.save(work / "verdicts.json", verdicts)
    print(f"食事 {len(meals)} 回のうち、無料モデルで決めた {sure} 回（残り {sum(1 for m in meals if m['id'] not in verdicts)} 回は Claude へ）",
          flush=True)


# ジャンル → OpenStreetMap の cuisine・店名の手がかり
SHOP_HINTS = {
    "ラーメン": (["ramen", "noodle", "chinese_noodle"], ["ラーメン", "らーめん", "拉麺", "中華そば", "麺", "ramen"]),
    "つけ麺": (["ramen", "noodle", "tsukemen"], ["つけ麺", "ラーメン", "らーめん", "中華そば", "麺"]),
    "そば・うどん": (["soba", "udon", "noodle"], ["そば", "蕎麦", "うどん", "饂飩"]),
    "寿司": (["sushi"], ["寿司", "鮨", "すし", "スシ"]),
    "焼肉": (["bbq", "yakiniku", "barbecue", "korean"], ["焼肉", "焼き肉", "ホルモン"]),
    "焼き鳥": (["yakitori"], ["焼鳥", "焼き鳥", "やきとり"]),
    "カレー": (["curry", "indian"], ["カレー", "curry"]),
    "ハンバーガー": (["burger"], ["バーガー", "burger"]),
    "中華": (["chinese"], ["中華", "飯店", "餃子", "酒家"]),
    "韓国料理": (["korean"], ["韓国", "韓国料理"]),
    "イタリアン": (["italian", "pizza", "pasta"], ["ピッツァ", "ピザ", "トラットリア", "パスタ", "pizza"]),
    "フレンチ": (["french"], ["ビストロ", "フレンチ", "bistro"]),
    "お好み焼き": (["okonomiyaki", "monjayaki"], ["お好み焼", "もんじゃ"]),
    "丼": (["donburi", "beef_bowl"], ["丼", "牛丼", "天丼", "かつや"]),
    "鍋": (["shabu-shabu", "hot_pot", "sukiyaki"], ["しゃぶ", "鍋", "すき焼"]),
    "パン": (["bakery"], ["パン", "ベーカリー", "bakery"]),
    "スイーツ": (["dessert", "cake", "ice_cream", "pancake", "crepe"], ["パフェ", "ケーキ", "スイーツ", "パティスリー"]),
}


def shop_fits(genre: str, c: dict) -> bool:
    cuisines, words = SHOP_HINTS.get(genre, ([], []))
    cu = (c.get("cuisine") or "").lower()
    name = c.get("name") or ""
    if genre == "パン" and c.get("kind") == "bakery":
        return True
    return any(x in cu for x in cuisines) or any(w in name for w in words)


def cmd_places(args) -> None:
    """無料モデルで決めた食事のお店を、近くに合うお店が 1 軒だけのときに限って決める（自信のないものは載せない）"""
    work = Path(args.work)
    meals = gi.load(work / "meals.json", [])
    verdicts = gi.load(work / "verdicts.json", {})
    picked = 0
    for m in meals:
        v = verdicts.get(m["id"])
        if not v or v.get("from") != "clip" or not v["eaten_out"] or v.get("place_name"):
            continue
        fits = [c for c in m.get("candidates", []) if c.get("name") and shop_fits(v["genre"], c)]
        if not fits:
            continue
        best = fits[0]
        nxt = fits[1]["dist"] if len(fits) > 1 else 10_000
        if best["dist"] <= args.max_dist and nxt >= max(2 * best["dist"], best["dist"] + 60):
            v["place_name"] = best["name"]
            v["place_confidence"] = 0.6
            v["place_reason"] = f"近くの{v['genre']}のお店がここだけ（{best['dist']}m）"
            picked += 1
    gi.save(work / "verdicts.json", verdicts)
    print(f"お店を決めた: {picked} 回（無料モデルの食事のうち）", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=str(gi.DEFAULT_WORK))
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("screen")
    s.add_argument("--threads", type=int, default=16, help="写真を同時に読む数（pCloud は 16 本で約 6 枚/秒）")
    s.add_argument("--sure", type=float, default=0.85, help="ご飯・手がかりと決めるしきい値（仮）")
    s.add_argument("--sure-no", type=float, default=0.9, help="ほかと決めるしきい値（仮）")
    s.set_defaults(func=cmd_screen)
    s = sub.add_parser("meals")
    s.add_argument("--sure-genre", type=float, default=0.85,
                   help="ジャンルを決めるしきい値（仮。40 食で 0.6 は 30 食中 6 外れ、0.85 は 19 食中 1 外れ）")
    s.add_argument("--sure-out", type=float, default=0.75, help="お店で食べたかを決めるしきい値（仮）")
    s.set_defaults(func=cmd_meals)
    s = sub.add_parser("places")
    s.add_argument("--max-dist", type=int, default=80, help="これより遠いお店は選ばない（m）")
    s.set_defaults(func=cmd_places)
    args = ap.parse_args()
    if Path(args.work).resolve().is_relative_to(Path(__file__).resolve().parents[2]):
        sys.exit("作業フォルダはリポジトリの外にしてください（写真が公開されないように）")
    args.func(args)


if __name__ == "__main__":
    main()
