import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://mohmokhtar1920.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

const rateBuckets = new Map<string, { count: number; resetAt: number }>();
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 6;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function inferSlot(p: Record<string, unknown>): string {
  const text = [p.category, p.name, p.name_en, p.description].map(x => String(x ?? "")).join(" ").toLowerCase();
  if (/shoe|sneaker|boot|heel|حذاء|كوتشي|جزمة/.test(text)) return "shoes";
  if (/bag|watch|accessor|necklace|bracelet|حقيبة|شنطة|ساعة|إكسسوار/.test(text)) return "accessory";
  if (/pant|jean|skirt|short|trouser|بنطلون|تنورة|شورت/.test(text)) return "bottom";
  return "top";
}

function takeRate(ip: string): boolean {
  const now = Date.now();
  const current = rateBuckets.get(ip);
  if (!current || current.resetAt <= now) {
    rateBuckets.set(ip, { count: 1, resetAt: now + WINDOW_MS });
    if (rateBuckets.size > 5000) {
      for (const [key, value] of rateBuckets) if (value.resetAt <= now) rateBuckets.delete(key);
    }
    return true;
  }
  if (current.count >= MAX_PER_WINDOW) return false;
  current.count++;
  return true;
}

function extractOutputText(data: Record<string, unknown>): string {
  if (typeof data.output_text === "string") return data.output_text;
  const output = Array.isArray(data.output) ? data.output as Array<Record<string, unknown>> : [];
  for (const item of output) {
    if (item.type !== "message" || !Array.isArray(item.content)) continue;
    for (const part of item.content as Array<Record<string, unknown>>) {
      if (part.type === "output_text" && typeof part.text === "string") return part.text;
    }
  }
  return "";
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") {
    if (origin && origin !== corsHeaders["Access-Control-Allow-Origin"]) return new Response("Origin not allowed", { status: 403 });
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (origin && origin !== corsHeaders["Access-Control-Allow-Origin"]) return json({ error: "Origin not allowed" }, 403);

  const ip = (req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip") || "unknown").split(",")[0].trim();
  if (!takeRate(ip)) return json({ error: "طلبات كتير في وقت قصير. استنى دقيقة وجرب تاني." }, 429);

  const groqKey = Deno.env.get("GROQ_API_KEY");
  if (!groqKey) return json({ error: "GROQ_API_KEY is not configured" }, 503);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ||
    (() => {
      try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default; } catch { return ""; }
    })();
  if (!supabaseUrl || !anonKey) return json({ error: "Catalog service is not configured" }, 503);

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 5000) return json({ error: "Request too large" }, 413);
    body = JSON.parse(raw);
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const prompt = typeof body.prompt === "string" ? body.prompt.trim() : "";
  const occasion = typeof body.occasion === "string" ? body.occasion : "everyday";
  const mood = typeof body.mood === "string" ? body.mood : "casual";
  const budget = Number(body.budget) || 0;
  if (prompt.length < 8 || prompt.length > 700) return json({ error: "اكتب وصفًا من 8 إلى 700 حرف." }, 400);
  if (budget < 0 || budget > 100000) return json({ error: "Invalid budget" }, 400);

  const headers = { apikey: anonKey, Authorization: `Bearer ${anonKey}` };
  const [productsResponse, variantsResponse] = await Promise.all([
    fetch(`${supabaseUrl}/rest/v1/products?select=id,name,name_en,description,description_en,category,price,image_url,stock,is_active&is_active=eq.true&order=id.desc&limit=100`, { headers }),
    fetch(`${supabaseUrl}/rest/v1/product_variants?select=id,product_id,size,color,stock,image_url&limit=500`, { headers }),
  ]);
  if (!productsResponse.ok || !variantsResponse.ok) {
    console.error("Catalog fetch failed", productsResponse.status, variantsResponse.status);
    return json({ error: "تعذر تحميل كتالوج المنتجات." }, 502);
  }
  const products = await productsResponse.json() as Array<Record<string, unknown>>;
  const variants = await variantsResponse.json() as Array<Record<string, unknown>>;
  const variantsByProduct = new Map<string, Array<Record<string, unknown>>>();
  for (const variant of variants) {
    const key = String(variant.product_id);
    const list = variantsByProduct.get(key) || [];
    list.push(variant);
    variantsByProduct.set(key, list);
  }
  const catalog = products.filter(p => {
    const list = variantsByProduct.get(String(p.id));
    return list ? list.some(v => Number(v.stock) > 0) : Number(p.stock) > 0;
  }).map(p => ({
    id: String(p.id),
    name: p.name,
    english_name: p.name_en,
    description: p.description,
    category: p.category,
    price_egp: Number(p.price) || 0,
    slot: inferSlot(p),
    image_url: p.image_url,
    available_variants: (variantsByProduct.get(String(p.id)) || []).filter(v => Number(v.stock) > 0).map(v => ({
      id: String(v.id), size: v.size, color: v.color, stock: Number(v.stock) || 0,
    })),
    stock: variantsByProduct.has(String(p.id))
      ? (variantsByProduct.get(String(p.id)) || []).reduce((n, v) => n + (Number(v.stock) || 0), 0)
      : Number(p.stock) || 0,
  }));
  if (!catalog.length) return json({ intro: "مفيش منتجات متاحة حاليًا نقدر ننسق منها.", looks: [], tips: "تابعنا قريبًا مع وصول منتجات جديدة." });

  const schema = {
    type: "object",
    additionalProperties: false,
    properties: {
      intro: { type: "string" },
      looks: {
        type: "array", minItems: 1, maxItems: 3,
        items: {
          type: "object", additionalProperties: false,
          properties: {
            title: { type: "string" },
            summary: { type: "string" },
            reason: { type: "string" },
            product_ids: { type: "array", minItems: 1, maxItems: 4, items: { type: "string" } },
          },
          required: ["title", "summary", "reason", "product_ids"],
        },
      },
      tips: { type: "string" },
    },
    required: ["intro", "looks", "tips"],
  };

  const instructions = [
    "You are ROVY STORE's expert personal fashion stylist. Reply naturally in Egyptian Arabic.",
    "Use ONLY the supplied live catalog. Never invent products, prices, colors, sizes, stock, or IDs.",
    "Create up to three genuinely different outfit suggestions. Each look should use at most one product from each slot (top, bottom, shoes, accessory), and no duplicate slot within a look.",
    "Only choose products whose available stock is positive. Respect the requested budget for the SUM of each look; if the catalog cannot satisfy it, return the best valid partial suggestion and explain the missing categories in the summary.",
    "Use the customer's description, occasion and style preference. Explain why each suggestion fits. Do not claim that unavailable categories are covered.",
    "product_ids must contain exact string IDs from the supplied catalog. Do not add any products outside it.",
    "If only one item is suitable, return a single partial look and clearly say it is not a complete outfit.",
  ].join(" ");

  const requestBody = {
    model: "openai/gpt-oss-20b",
    messages: [
      { role: "system", content: instructions },
      {
        role: "user",
        content: JSON.stringify({
          customer_request: prompt,
          occasion,
          style: mood,
          max_budget_egp: budget || "open",
          live_catalog: catalog,
        }),
      },
    ],
    max_completion_tokens: 1200,
    reasoning_effort: "low",
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "rovy_style_recommendations",
        strict: true,
        schema,
      },
    },
  };

  let aiResponse: Response;
  try {
    aiResponse = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${groqKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(requestBody),
      signal: AbortSignal.timeout(25000),
    });
  } catch (error) {
    console.error("Groq request failed", error);
    return json({ error: "AI service timed out" }, 504);
  }
  if (!aiResponse.ok) {
    const errorText = await aiResponse.text();
    console.error("Groq API error", aiResponse.status, errorText.slice(0, 1000));
    return json({ error: "تعذر على الستايلست تجهيز الاقتراحات حاليًا." }, 502);
  }
  const aiData = await aiResponse.json() as Record<string, any>;
  const outputText = typeof aiData.choices?.[0]?.message?.content === "string"
    ? aiData.choices[0].message.content
    : "";
  if (!outputText) return json({ error: "AI returned no recommendation" }, 502);

  let recommendation: Record<string, unknown>;
  try { recommendation = JSON.parse(outputText); } catch { return json({ error: "AI response was not valid JSON" }, 502); }

  const byId = new Map(catalog.map(p => [String(p.id), p]));
  const cleanLooks = (Array.isArray(recommendation.looks) ? recommendation.looks : []).slice(0, 3).map((look: any) => {
    const seenIds = new Set<string>();
    const seenSlots = new Set<string>();
    let total = 0;
    const validIds: string[] = [];
    for (const rawId of Array.isArray(look.product_ids) ? look.product_ids : []) {
      const id = String(rawId);
      const product = byId.get(id);
      if (!product || seenIds.has(id) || seenSlots.has(String(product.slot))) continue;
      const price = Number(product.price_egp) || 0;
      if (budget && total + price > budget) continue;
      seenIds.add(id);
      seenSlots.add(String(product.slot));
      validIds.push(id);
      total += price;
    }
    return { title: String(look.title || "إطلالة ROVY").slice(0, 80), summary: String(look.summary || "").slice(0, 260), reason: String(look.reason || "").slice(0, 300), product_ids: validIds };
  }).filter((look: any) => look.product_ids.length > 0);

  return json({
    intro: String(recommendation.intro || "").slice(0, 400),
    looks: cleanLooks,
    tips: String(recommendation.tips || "").slice(0, 400),
    catalog_checked_at: new Date().toISOString(),
  });
});
