import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SITE_ORIGINS = ["https://mohmokhtar1920.github.io", "https://rovy-store.pages.dev"];

function jsonResponse(body: Record<string, unknown>, status: number, cors: Record<string,string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}

function getSupabaseSecretKey(): string | null {
  try {
    const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
    if (raw) {
      const keys = JSON.parse(raw);
      if (typeof keys?.default === "string" && keys.default) return keys.default;
    }
  } catch (_error) {
    console.error("Could not parse Supabase secret-key configuration");
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? null;
}

async function hashClientIp(ip: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ip));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin") ?? "";
  const allowedOrigin = SITE_ORIGINS.includes(origin) ? origin : SITE_ORIGINS[0];
  const cors = {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: { ...cors, "Access-Control-Allow-Origin": SITE_ORIGINS.includes(origin) ? origin : "null" },
    });
  }
  if (!SITE_ORIGINS.includes(origin)) return jsonResponse({ success: false, error: "Origin not allowed" }, 403, cors);
  if (req.method !== "POST") return jsonResponse({ success: false, error: "Method not allowed" }, 405, cors);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseSecretKey = getSupabaseSecretKey();
  if (!supabaseUrl || !supabaseSecretKey) {
    console.error("Supabase server-side secret key is unavailable for order tracking");
    return jsonResponse({ success: false, error: "TRACKING_NOT_CONFIGURED" }, 503, cors);
  }

  try {
    let payload: Record<string, unknown>;
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ success: false, error: "INVALID_REQUEST" }, 400, cors);
    }

    const orderId = Number(payload.order_id);
    const phone = typeof payload.customer_phone === "string" ? payload.customer_phone.trim() : "";
    if (!Number.isSafeInteger(orderId) || orderId < 1 || phone.length < 8 || phone.length > 20) {
      return jsonResponse({ success: false, error: "INVALID_REQUEST" }, 400, cors);
    }

    const forwarded = req.headers.get("cf-connecting-ip") ??
      req.headers.get("x-real-ip") ??
      req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() ??
      "";
    if (!forwarded) return jsonResponse({ success: false, error: "RATE_LIMIT_UNAVAILABLE" }, 503, cors);

    const ipHash = await hashClientIp(forwarded, supabaseSecretKey);
    const rpcHeaders: Record<string,string> = {
      "apikey": supabaseSecretKey,
      "Content-Type": "application/json",
    };
    if (!supabaseSecretKey.startsWith("sb_secret_")) {
      rpcHeaders["Authorization"] = `Bearer ${supabaseSecretKey}`;
    }

    const quotaResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/consume_track_order_quota`, {
      method: "POST",
      headers: rpcHeaders,
      body: JSON.stringify({ p_ip_hash: ipHash }),
    });
    if (!quotaResponse.ok) {
      console.error("Order tracking rate-limit check failed:", quotaResponse.status);
      return jsonResponse({ success: false, error: "RATE_LIMIT_UNAVAILABLE" }, 503, cors);
    }
    const quotaResult = await quotaResponse.json().catch(() => false);
    const allowed = quotaResult === true || (Array.isArray(quotaResult) && quotaResult[0] === true);
    if (!allowed) return jsonResponse({ success: false, error: "RATE_LIMITED", retryAfterSeconds: 600 }, 429, cors);

    const orderResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/track_order_secure`, {
      method: "POST",
      headers: rpcHeaders,
      body: JSON.stringify({ p_order_id: orderId, p_customer_phone: phone }),
    });
    if (!orderResponse.ok) {
      console.error("Secure order lookup failed:", orderResponse.status);
      return jsonResponse({ success: false, error: "TRACKING_SERVICE_UNAVAILABLE" }, 502, cors);
    }

    const result = await orderResponse.json().catch(() => null);
    if (!result || typeof result !== "object") {
      return jsonResponse({ success: false, error: "TRACKING_SERVICE_UNAVAILABLE" }, 502, cors);
    }
    return jsonResponse(result, 200, cors);
  } catch (error) {
    console.error("Order tracking endpoint failed:", error);
    return jsonResponse({ success: false, error: "TRACKING_SERVICE_UNAVAILABLE" }, 502, cors);
  }
});
