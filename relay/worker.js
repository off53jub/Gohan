// ごはん帖の中継サーバー（便2。Cloudflare Workers で動かす）
// アプリは Claude の鍵を持たず、合言葉（APP_TOKEN）だけでここに頼む。ここが鍵を付けて Anthropic に送り、使った額を数える。
// 置くもの: 秘密 ANTHROPIC_API_KEY・APP_TOKEN、KV の SPEND、変数 CAP_USD（月の上限ドル）。手順は README.md。

const PRICES = {
  // 1M トークンあたりのドル（入力・出力）
  "claude-opus-5-5": [4, 20],
  "claude-sonnet-5-5": [2, 10],
  "claude-haiku-5-5": [0.1, 0.5],
};

function monthKey() {
  const d = new Date(Date.now() + 9 * 3600 * 1000); // 日本の月で数える
  return `spend-${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function cost(message, discount = 1) {
  const usage = message?.usage;
  if (!usage) return 0;
  const [inP, outP] = PRICES[message.model] || PRICES["claude-opus-5-5"];
  const input = (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0) * 1.25 + (usage.cache_read_input_tokens || 0) * 0.1;
  return ((input * inP) / 1e6 + ((usage.output_tokens || 0) * outP) / 1e6) * discount;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!env.APP_TOKEN || request.headers.get("x-gohan-token") !== env.APP_TOKEN) {
      return json({ error: { type: "forbidden", message: "合言葉が違います" } }, 403);
    }
    const key = monthKey();
    const spent = Number((await env.SPEND.get(key)) || 0);
    const cap = Number(env.CAP_USD || 10);

    // 本人が今月の額を見る: GET /spend
    if (url.pathname === "/spend") return json({ month: key, usd: Math.round(spent * 100) / 100, cap });

    const allowed = url.pathname === "/v1/messages" || url.pathname.startsWith("/v1/messages/batches");
    if (!allowed) return json({ error: { type: "not_found", message: "使えない道です" } }, 404);
    if (request.method === "POST" && spent >= cap) {
      return json({ error: { type: "cap", message: "今月の上限に届きました" } }, 402);
    }

    const headers = new Headers({
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": request.headers.get("anthropic-version") || "2023-06-01",
      "content-type": "application/json",
    });
    const beta = request.headers.get("anthropic-beta");
    if (beta) headers.set("anthropic-beta", beta);
    const upstream = await fetch("https://api.anthropic.com" + url.pathname + url.search, {
      method: request.method,
      headers,
      body: request.method === "GET" ? undefined : await request.text(),
    });
    const text = await upstream.text();

    if (upstream.ok) {
      let usd = 0;
      if (url.pathname === "/v1/messages") {
        try { usd = cost(JSON.parse(text)); } catch (_) {}
      } else if (url.pathname.endsWith("/results")) {
        // まとめ処理の答え（JSONL）。半額で数える
        for (const line of text.split("\n")) {
          if (!line.trim()) continue;
          try {
            const row = JSON.parse(line);
            if (row.result?.type === "succeeded") usd += cost(row.result.message, 0.5);
          } catch (_) {}
        }
      }
      if (usd > 0) await env.SPEND.put(key, String(spent + usd));
    }
    return new Response(text, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") || "application/json" },
    });
  },
};
