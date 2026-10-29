// AVAZ smart features: translation and listing descriptions through Claude.
// The Anthropic key lives only in Supabase secrets (ANTHROPIC_API_KEY), never in the page.
// Signed-in users only, 40 calls per user per day (counted by public.ai_take()).

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MODEL = "claude-haiku-5-5";
const LANGS: Record<string, string> = {
  ar: "Arabic", en: "English", ur: "Urdu", tl: "Filipino (Tagalog)", hi: "Hindi",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }

  // lets the page know whether to show the smart buttons; costs nothing
  if (body.task === "ping") return json({ ok: true, configured: Boolean(key) });

  const auth = req.headers.get("authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? "";
  if (!auth.startsWith("Bearer ") || !apikey || !url) return json({ error: "not_signed_in" }, 401);

  const who = await fetch(`${url}/auth/v1/user`, { headers: { authorization: auth, apikey } });
  if (!who.ok) return json({ error: "not_signed_in" }, 401);
  if (!key) return json({ error: "ai_not_configured" }, 503);

  const take = await fetch(`${url}/rest/v1/rpc/ai_take`, {
    method: "POST",
    headers: { authorization: auth, apikey, "content-type": "application/json" },
    body: "{}",
  });
  if (!take.ok || (await take.json()) !== true) return json({ error: "daily_limit" }, 429);

  let system = "";
  let user = "";
  if (body.task === "translate") {
    const to = LANGS[String(body.to ?? "")];
    const text = String(body.text ?? "").slice(0, 4000);
    if (!to || !text.trim()) return json({ error: "bad_request" }, 400);
    system = "You translate short texts from a worker-housing app in Saudi Arabia. Reply with only the translation and nothing else. Keep numbers, prices and place names as they are.";
    user = `Translate into ${to}:\n\n${text}`;
  } else if (body.task === "describe") {
    const facts = body.facts;
    if (!facts || typeof facts !== "object") return json({ error: "bad_request" }, 400);
    system = 'You write short, factual rental descriptions for worker housing in Saudi Arabia. Use only the facts given and never invent prices, distances or services. Skip facts that are null. Reply with only JSON in this shape: {"ar": "...", "en": "..."}, with 2 to 4 plain sentences in each language.';
    user = "Facts: " + JSON.stringify(facts).slice(0, 4000);
  } else {
    return json({ error: "bad_request" }, 400);
  }

  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 900, system, messages: [{ role: "user", content: user }] }),
  });
  if (!r.ok) {
    console.error("anthropic error", r.status, (await r.text()).slice(0, 300));
    return json({ error: "ai_failed", status: r.status }, 502);
  }
  const data = await r.json();
  const text = (data.content ?? [])
    .filter((c: { type: string }) => c.type === "text")
    .map((c: { text: string }) => c.text)
    .join("")
    .trim();

  if (body.task === "describe") {
    const m = text.match(/\{[\s\S]*\}/);
    try {
      const o = JSON.parse(m ? m[0] : text);
      return json({ ar: String(o.ar ?? ""), en: String(o.en ?? "") });
    } catch {
      return json({ error: "ai_failed" }, 502);
    }
  }
  return json({ text });
});
