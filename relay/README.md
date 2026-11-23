# ごはん帖の中継サーバー（便2）

アプリに Claude の鍵を置かずに使うための、小さな中継です。Cloudflare Workers（無料の枠で足ります）で動かします。

- アプリは「合言葉」だけを持ち、この中継に頼みます。中継が鍵を付けて Anthropic に送ります。
- 使った額は中継で数え、月の上限（`CAP_USD`）に届くと止めます。
- 本人は `GET /spend`（ヘッダー `x-gohan-token: 合言葉`）で今月の額を見られます（便76: 彼女さんの画面に費用を出さなくても、本人が分かる）。

## 立て方（本人の手順。Cloudflare のアカウントが要ります）

```powershell
cd D:\Gohan\relay
npx wrangler login
npx wrangler kv namespace create SPEND
```

出てきた `id` を `wrangler.toml` の `id = "…"` に書きます。

```powershell
npx wrangler secret put ANTHROPIC_API_KEY
```

```powershell
npx wrangler secret put APP_TOKEN
```

`APP_TOKEN` は長めの合言葉（20 文字以上の英数字）にします。

```powershell
npx wrangler deploy
```

出てきた URL（`https://gohan-relay.…workers.dev`）を、アプリの「設定 → くわしい設定 → 中継サーバー」に入れ、合言葉も入れます。
そのあと「鍵を渡す（QR）」で渡すと、相手の iPhone にも中継の設定が入ります（鍵そのものは渡りません）。

## 通す道

- `POST /v1/messages`
- `POST /v1/messages/batches`・`GET /v1/messages/batches/{id}`・`GET /v1/messages/batches/{id}/results`
- `GET /spend`
