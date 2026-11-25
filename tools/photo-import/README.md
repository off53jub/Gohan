# PC から取り込む（作る人用）

pCloud や Google フォトにある昔のご飯の写真を、ごはん帖に入れるための道具です。
ご飯かどうか・料理の名前・看板の店名は **Claude Code の会話の中で** 見ます。アプリの Claude API は使いません。
お店は、PC で食事の場所の近くのお店（OpenStreetMap・無料）と写真から選び、アプリが地図とホットペッパーで名前を確かめます。

写真の写しは作業フォルダ（既定 `D:\GohanImport`）にだけ置きます。**公開リポジトリの中には置かない**でください（道具が止めます）。

## 使い方

```powershell
cd D:\Gohan\tools\photo-import
uv run gohan_import.py scan --source "P:\Automatic Upload" --since 2026-09-01
uv run gohan_import.py sheets
# ここで Claude に D:\GohanImport\sheets\*.jpg を見てもらい、screen.json を書いてもらう
uv run gohan_import.py group
uv run gohan_import.py nearby   # Overpass が混んでいて取れなかった分は、もう一度流すとそこだけやり直す
# ここで Claude に D:\GohanImport\meals\*.jpg と meals.json を見てもらい、verdicts.json を書いてもらう
uv run gohan_import.py pack --label pCloud
```

できた `ごはん帖の取り込み-*.json` を iPhone に送り（iCloud Drive・LINE の自分あてなど）、
アプリの「設定 →（版を5回たたく）作る人のメニュー → 精度 → PC から取り込む」で選びます。

- Google フォトは、takeout.google.com で「Google フォト」だけを書き出し、展開したフォルダを `--source` に渡します（時刻と位置は横の `.json` から読みます）。
- 2 回目からは、前に見た写真・入れた食事は飛ばします（`photos.json`・`screen.json`・`verdicts.json`・`packed.json` が覚えています）。
- iPhone の写真アプリに同じ写真があれば（撮った時刻が 2 秒以内）、アプリはそちらを使います。無ければ写真をアプリの中に置きます。
- もう記録にある食事（前後 45 分・300m 以内）は足しません。

## 何年分もあるとき（PC の無料モデルで一次判定）

何万枚もあると、全部を Claude に見せるのは重いので、PC の無料モデル（CLIP・GPU）で先に分けます。
自信のあるものは無料モデルの答えのまま、自信のないものだけ Claude（軽いモデル）に見せ、それでも自信のないものは載せません。

```powershell
uv run gohan_import.py --work D:\GohanImport\toshu scan --source "P:\れんげ食堂toshu"
uv run gohan_clip.py   --work D:\GohanImport\toshu screen     # ご飯・手がかり・ほか。迷った写真は screen_unsure.json
uv run gohan_import.py --work D:\GohanImport\toshu sheets     # 迷った写真だけの一覧画像 → Claude が screen.json に足す
uv run gohan_import.py --work D:\GohanImport\toshu group
uv run gohan_clip.py   --work D:\GohanImport\toshu meals      # ジャンルに自信のある食事は verdicts.json へ
uv run gohan_import.py --work D:\GohanImport\toshu group      # 残りの食事の画像を作り直す → Claude が verdicts へ（unsure も）
uv run gohan_import.py --work D:\GohanImport\toshu nearby --tiles
uv run gohan_clip.py   --work D:\GohanImport\toshu places     # 近くに合うお店が 1 軒だけのときだけお店を決める
uv run gohan_import.py --work D:\GohanImport\toshu pack --label pCloud --per-file 150 --side 1024 --max-photos 3 --min-place 0.6 --skip-near D:\GohanImport
```

- 無料モデルが決めた食事は、料理の細かい名前（醤油・味噌など）を付けず、ジャンルだけにします（外れが多かったため）。
- しきい値は仮です（前の 414 枚・40 食で Claude の答えと比べて決めた）。
- ファイルは 150 食ずつ、新しい年から。アプリは食事が多いファイルを 1 食 6 秒ずつ取り込みます（地図の検索の上限のため）。

## Claude に頼むこと

### screen.json（一覧画像を見て）

各マスの左上の番号ごとに、次のどれかを書きます。

```json
{"p00001": "food", "p00002": "clue", "p00003": "no"}
```

- `food`: 料理・飲み物・お菓子が主に写っている（お店でも家でも）
- `clue`: 看板・のれん・メニュー・レシート・店の外観・店内（料理は写っていない）
- `no`: それ以外（人・風景・物・画面）

### verdicts.json（食事ごとの画像を見て）

```json
{"m00012": {"is_meal": true, "eaten_out": true, "genre": "ラーメン", "dishes": ["味玉醤油ラーメン"],
            "summary": "澄んだ醤油ラーメン", "kind": "meal", "name_seen": "麺屋こもれび", "lines": ["麺屋こもれび", "味玉醤油"]}}
```

- アプリの AI と同じ決まり（`Gohan/ClaudeVision.swift` の `system`）で決めます。
- `genre` は `Genre.all` の一覧から 1 つ（ラーメン・つけ麺・そば・うどん・寿司・和食・定食・丼・焼肉・焼き鳥・居酒屋・中華・韓国料理・カレー・エスニック・イタリアン・フレンチ・洋食・ハンバーガー・ファストフード・カフェ・スイーツ・パン・バー・鍋・お好み焼き・その他）。
- `name_seen` は写真から**読めた**店名だけ（推測では書かない）。`lines` は看板・メニュー・レシートから読めた文字（店名・料理名など、10 行まで）。
- 家の食卓・手料理・コンビニの持ち帰りらしければ `eaten_out` を false に。食事でなければ `is_meal` を false に。
- お店: `place_name`（meals.json の candidates から選ぶときは名前をそのまま）・`place_confidence`（0〜1）・`place_reason`。決め手が無ければ `place_name` を空に。
- 頼み方の全文は `tools/photo-import/JUDGE.md`（そのまま Claude に読ませる。担当の範囲と書き出し先だけ伝える）。
