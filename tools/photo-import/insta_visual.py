# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch==2.7.1", "torchvision==0.22.1", "open_clip_torch", "pillow", "pillow-heif", "numpy"]
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
"""Instagram の投稿の写真と、pCloud の写真を見た目で照合する（大2。2026-11-28）。

食事と結べなかった麺の投稿（insta_match.py の meal が空のもの）について、
投稿の写真に見た目がいちばん近い pCloud の写真を、投稿日の 180 日前〜1 日後の中から探す。

    uv run insta_visual.py --insta D:\\GohanImport\\insta --work D:\\GohanImport\\toshu --out visual.json

out には投稿ごとに、近い写真の上位 3 枚（似ている度 0〜1）を書く。ここでは結ぶだけ。
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

import gohan_clip as gc


def load_unmatched(insta: Path) -> list[dict]:
    rows = json.loads((insta / "match_all.json").read_text(encoding="utf-8"))
    posts = json.loads((insta / "posts_all.json").read_text(encoding="utf-8"))
    by_first: dict[str, list[dict]] = {}
    for p in posts:
        by_first.setdefault(p["first"], []).append(p)
    out, seen = [], set()
    for r in rows:
        if r["meal"] or not r["time"]:
            continue
        t = datetime.fromisoformat(r["time"])
        cands = by_first.get(r["first"], [])
        # 同じ 1 行目の投稿のうち、時刻が合うもの
        def t_of(p):
            if p.get("taken"):
                return datetime.fromisoformat(p["taken"])
            return datetime.fromisoformat(p["posted"].replace("Z", "+00:00"))
        post = min(cands, key=lambda p: abs((t_of(p) - t).total_seconds()), default=None)
        if not post or abs((t_of(post) - t).total_seconds()) > 120:
            continue
        images = [insta / post["account"] / im for im in post["images"]]
        images = [im for im in images if im.exists() and im.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp", ".heic")]
        key = tuple(str(i) for i in images)
        if not images or key in seen:
            continue
        seen.add(key)
        out.append({"row": r, "time": t, "images": images})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--insta", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--days", type=int, default=180)
    a = ap.parse_args()
    insta, work = Path(a.insta), Path(a.work)
    items = load_unmatched(insta)
    photos = json.loads((work / "photos.json").read_text(encoding="utf-8"))
    for p in photos:
        p["dt"] = datetime.fromisoformat(p["date"])
    by_id = {p["id"]: p for p in photos}
    print(f"結べなかった投稿 {len(items)} 件（写真のあるもの）", flush=True)

    need: dict[str, dict] = {}
    for it in items:
        lo, hi = it["time"] - timedelta(days=a.days), it["time"] + timedelta(days=1)
        it["cands"] = [p["id"] for p in photos if lo <= p["dt"] <= hi]
        for pid in it["cands"]:
            need[pid] = by_id[pid]
    print(f"見比べる pCloud の写真 {len(need)} 枚", flush=True)

    clip = gc.Clip()

    def embed(paths: list[Path]) -> np.ndarray:
        vs = []
        for i in range(0, len(paths), 64):
            vs.append(clip.images(paths[i:i + 64]).float().cpu().numpy())
            if i and i % 1280 == 0:
                print(f"  {i} / {len(paths)}", flush=True)
        return np.concatenate(vs) if vs else np.zeros((0, 512), np.float32)

    ids = sorted(need)
    thumbs = [work / "thumbs" / f"{pid}.jpg" for pid in ids]
    ok = [i for i, t in enumerate(thumbs) if t.exists()]
    ids = [ids[i] for i in ok]
    pv = embed([thumbs[i] for i in ok])
    index = {pid: i for i, pid in enumerate(ids)}

    out = []
    for it in items:
        iv = embed(it["images"])
        cand = [index[c] for c in it["cands"] if c in index]
        best = []
        if cand:
            sims = iv @ pv[cand].T            # 投稿の写真 × 候補
            top = sims.max(axis=0)
            order = np.argsort(-top)[:20]
            for o in order:
                pid = ids[cand[o]]
                best.append({"id": pid, "sim": round(float(top[o]), 4), "path": need[pid]["path"], "date": need[pid]["date"]})
        out.append({"first": it["row"]["first"], "time": it["row"]["time"], "account": it["row"]["account"],
                    "images": [str(i) for i in it["images"]], "best": best})
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    sims = sorted((o["best"][0]["sim"] for o in out if o["best"]), reverse=True)
    print("いちばん似ている度:", [round(s, 3) for s in sims])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
