import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const ORIGINS = new Set([
  "https://id-preview--b5201918-cc71-4086-81e8-65bf0d1a3486.lovable.app",
  "https://b5201918-cc71-4086-81e8-65bf0d1a3486.lovableproject.com",
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEYS: Record<string, string[]> = {
  financial_summary: ["start", "end"],
  list_rules: [],
  history: ["eventId"],
  review: ["eventId", "decision", "reason"],
  save_rule: ["eventType", "approverRole", "maxAmountCents", "requiresApproval", "effectiveFrom", "effectiveTo", "policyReference"],
};
const MESSAGES: Record<string, [number, string]> = {
  UNAUTHENTICATED: [401, "Sign in again to continue."],
  FORBIDDEN: [403, "Your role does not include this action."],
  INVALID_REQUEST: [400, "The request was not valid."],
  NOT_FOUND: [404, "The event is not available."],
  POLICY_REQUIRED: [409, "An owner must configure an applicable approval rule before this decision."],
  APPROVAL_REQUIRED: [409, "This event requires an approval or rejection; acknowledgement cannot close it."],
  INTERNAL: [500, "The operation could not be completed."],
};

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  const headers: Record<string, string> = {
    "Content-Type": "application/json", "Cache-Control": "no-store", "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  };
  if (origin && ORIGINS.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  const fail = (code: string) => {
    const [status, message] = MESSAGES[code] ?? MESSAGES.INTERNAL;
    return reply({ ok: false, error: { code: MESSAGES[code] ? code : "INTERNAL", message } }, status);
  };
  if (origin && !ORIGINS.has(origin)) return fail("FORBIDDEN");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply({ ok: false, error: { code: "METHOD_NOT_ALLOWED", message: "Use POST." } }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anon || !service) return fail("INTERNAL");
    const token = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(\S+)$/i)?.[1];
    if (!token) return fail("UNAUTHENTICATED");
    const auth = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error: authError } = await auth.auth.getUser(token);
    if (authError || !user) return fail("UNAUTHENTICATED");
    const reader = req.body?.getReader();
    if (!reader) return fail("INVALID_REQUEST");
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 16384) { await reader.cancel(); return fail("INVALID_REQUEST"); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    let body: Record<string, unknown>;
    try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
    catch { return fail("INVALID_REQUEST"); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return fail("INVALID_REQUEST");
    const action = typeof body.action === "string" ? body.action : "";
    const allowed = KEYS[action];
    if (!allowed || Object.keys(body).some(k => k !== "action" && !allowed.includes(k))) return fail("INVALID_REQUEST");
    const params = Object.fromEntries(Object.entries(body).filter(([k]) => k !== "action"));
    if (["review", "history"].includes(action) && (typeof params.eventId !== "string" || !UUID.test(params.eventId))) return fail("INVALID_REQUEST");
    if (action === "review" &&
        (typeof params.decision !== "string" || !["APPROVED", "REJECTED", "NEEDS_INFORMATION", "ESCALATED", "ACKNOWLEDGED"].includes(params.decision)
         || typeof params.reason !== "string" || params.reason.trim().length < 1 || params.reason.trim().length > 2000)) return fail("INVALID_REQUEST");
    if (action === "financial_summary" && [params.start, params.end].some(v => typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v))) return fail("INVALID_REQUEST");
    if (action === "save_rule" &&
        (typeof params.eventType !== "string" || !["COMP", "DISCOUNT", "VOID", "REFUND", "OTHER"].includes(params.eventType)
         || !["OWNER", "MANAGER"].includes(String(params.approverRole)) || typeof params.requiresApproval !== "boolean"
         || typeof params.policyReference !== "string" || !params.policyReference.trim() || params.policyReference.length > 500
         || typeof params.effectiveFrom !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(params.effectiveFrom)
         || (params.effectiveTo != null && (typeof params.effectiveTo !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(params.effectiveTo)))
         || (params.maxAmountCents != null && (!Number.isSafeInteger(params.maxAmountCents) || Number(params.maxAmountCents) < 0)))) return fail("INVALID_REQUEST");
    const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data, error } = await db.rpc("rb04_app_operations_dev", { p_user_id: user.id, p_action: action, p_params: params });
    if (error) return fail(["22007", "22008", "22P02", "23514"].includes(error.code) ? "INVALID_REQUEST" : "INTERNAL");
    if (data?.ok !== true) return fail(String(data?.code ?? "INTERNAL"));
    return reply({ ok: true, service: "rb04-app-operations", schemaVersion: "1.0", data });
  } catch {
    console.error("[rb04-app-operations] operation failed");
    return fail("INTERNAL");
  }
});
