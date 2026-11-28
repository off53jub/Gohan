# /// script
# requires-python = ">=3.11"
# dependencies = ["opencv-python-headless", "numpy", "pillow", "pillow-heif"]
# ///
"""insta_visual.py の候補が「同じ 1 枚」かを、特徴点の突き合わせで確かめる（大2。2026-11-28）。

CLIP の似ている度は、同じお店の別の写真・似たラーメンでも高くなる。
同じ写真（インスタで切り抜き・色を変えたもの）なら、特徴点が位置ごとそろう（ホモグラフィーの inlier が多い）。

    uv run insta_verify.py D:\\GohanImport\\insta\\visual.json --thumbs D:\\GohanImport\\toshu\\thumbs --out verified.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from pillow_heif import register_heif_opener

register_heif_opener()
SIFT = cv2.SIFT_create(nfeatures=2000)
MATCHER = cv2.BFMatcher()


def gray(path: str, side: int = 768) -> np.ndarray:
    im = Image.open(path).convert("L")
    im.thumbnail((side, side))
    return np.asarray(im)


def features(path: str):
    return SIFT.detectAndCompute(gray(path), None)


def inliers(a, b) -> int:
    (ka, da), (kb, db) = a, b
    if da is None or db is None or len(ka) < 8 or len(kb) < 8:
        return 0
    good = [m for m, n in (p for p in MATCHER.knnMatch(da, db, k=2) if len(p) == 2) if m.distance < 0.75 * n.distance]
    if len(good) < 8:
        return 0
    src = np.float32([ka[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
    dst = np.float32([kb[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)
    _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
    return int(mask.sum()) if mask is not None else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("visual")
    ap.add_argument("--thumbs", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rows = json.loads(Path(a.visual).read_text(encoding="utf-8"))
    cache: dict[str, tuple] = {}
    for n, r in enumerate(rows):
        posts = [features(p) for p in r["images"]]
        scored = []
        for c in r["best"]:
            if c["id"] not in cache:
                cache[c["id"]] = features(str(Path(a.thumbs) / f"{c['id']}.jpg"))
            scored.append((max(inliers(p, cache[c["id"]]) for p in posts), c))
        scored.sort(key=lambda x: -x[0])
        r["verified"] = [{"inliers": s, **c} for s, c in scored[:3]]
        top = r["verified"][0] if r["verified"] else None
        print(n, r["first"][:20], top["inliers"] if top else "-", top["sim"] if top else "", flush=True)
    Path(a.out).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
