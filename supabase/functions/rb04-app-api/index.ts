// Canonical RB04 authenticated read API. POST view requests authorize through
// public.rb04_app_readonly_dev using the Supabase Auth-verified user ID.
// rb04-app-readonly remains the legacy compatibility endpoint.

import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const SERVICE = "rb04-app-api";
const MAX_BODY_BYTES = 2048;
const MAX_RANGE_DAYS = 93; // inclusive calendar days: end - start <= 92

const ALLOWED_ORIGINS = new Set([
  "https://id-preview--b5201918-cc71-4086-81e8-65bf0d1a3486.lovable.app",
  "https://b5201918-cc71-4086-81e8-65bf0d1a3486.lovableproject.com",
  // Add the published address here once the app is published.
]);

// Existing schemaVersion 1.0 contract, values verified from the original deployed function.
const CONNECTIVITY_V1 = {
  environment: "DEV",
  permissions: {
    operationalDataEnabled: false,
    databaseWritesAllowed: false,
    ingestionAllowed: false,
  },
} as const;

const UNDATED_VIEWS = new Set(["me", "approval_rules"]);
const DATED_VIEWS = new Set([
  "daily_summary", "employee_weekly", "review_queue", "exceptions", "my_weekly", "my_activity",
]);
const ALLOWED_KEYS = new Set(["view", "merchantId", "start", "end"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

// Documented codes with fixed, safe messages. Internal details never reach the client.
const ERRORS = {
  UNAUTHENTICATED: { status: 401, message: "Sign in again to continue." },
  INVALID_REQUEST: { status: 400, message: "The request was not valid." },
  PAYLOAD_TOO_LARGE: { status: 413, message: "The request was too large." },
  NO_ACTIVE_MEMBERSHIP: { status: 403, message: "No active Red Barn access for this account." },
  AMBIGUOUS_MEMBERSHIP: { status: 403, message: "Choose a merchant to continue." },
  MERCHANT_NOT_ELIGIBLE: { status: 403, message: "This location is not available in the app." },
  EMPLOYEE_NOT_LINKED: { status: 403, message: "Employee account not yet linked — contact management." },
  FORBIDDEN: { status: 403, message: "Your role does not include this information." },
  METHOD_NOT_ALLOWED: { status: 405, message: "Use POST." },
  INTERNAL: { status: 500, message: "The request could not be completed." },
} as const;
type ErrorCode = keyof typeof ERRORS;

// Codes the SQL function is allowed to return. Anything else is treated as INTERNAL.
const RPC_CODES = new Set<ErrorCode>([
  "UNAUTHENTICATED", "INVALID_REQUEST", "NO_ACTIVE_MEMBERSHIP", "AMBIGUOUS_MEMBERSHIP",
  "MERCHANT_NOT_ELIGIBLE", "EMPLOYEE_NOT_LINKED", "FORBIDDEN",
]);

class RequestError extends Error {
  constructor(public code: ErrorCode) { super(code); }
}

function cors(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
    "Access-Control-Max-Age": "3600",
    "Vary": "Origin",
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(origin), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function fail(code: ErrorCode, origin: string | null): Response {
  const e = ERRORS[code];
  return json({
    ok: false, service: SERVICE, mode: "AUTHORIZED_READONLY", schemaVersion: "1.1",
    error: { code, message: e.message },
  }, e.status, origin);
}

// Safe calendar-date parser. Pure integer arithmetic: no Date objects, so invalid
// timestamps cannot throw and years 0001-0099 are not remapped to 1900-1999.
// Returns a day number (days since 0000-03-01, proleptic Gregorian) or null.
function parseDate(s: unknown): number | null {
  if (typeof s !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const y = Number(s.slice(0, 4));
  const m = Number(s.slice(5, 7));
  const d = Number(s.slice(8, 10));
  if (!Number.isInteger(y) || !Number.isInteger(m) || !Number.isInteger(d)) return null;
  if (y < 1 || y > 9999 || m < 1 || m > 12 || d < 1) return null;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
  if (d > dim) return null;
  // Days-from-civil (Howard Hinnant), shifted so March is month 0.
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const mp = (m + 9) % 12;
  const doy = Math.floor((153 * mp + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe;
}

// Exact calendar-day difference between two parseDate() day numbers.
function dayDiff(startDay: number, endDay: number): number {
  return endDay - startDay;
}

// Bounded read: never buffers more than MAX_BODY_BYTES + one chunk; counts UTF-8 bytes.
async function readBody(req: Request): Promise<string> {
  const declared = req.headers.get("Content-Length");
  if (declared !== null) {
    if (!/^\d+$/.test(declared)) throw new RequestError("INVALID_REQUEST");
    if (Number(declared) > MAX_BODY_BYTES) throw new RequestError("PAYLOAD_TOO_LARGE");
  }
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel().catch(() => {});
        throw new RequestError("PAYLOAD_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) { bytes.set(c, offset); offset += c.byteLength; }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new RequestError("INVALID_REQUEST");
  }
}

type ViewRequest = { view: string; merchantId: string | null; start: string | null; end: string | null };

function validate(raw: string): ViewRequest {
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { throw new RequestError("INVALID_REQUEST"); }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new RequestError("INVALID_REQUEST");
  }
  const body = parsed as Record<string, unknown>;
  // Unknown keys (userId, user_id, role, ...) are rejected outright.
  if (Object.keys(body).some((k) => !ALLOWED_KEYS.has(k))) throw new RequestError("INVALID_REQUEST");
  // Non-empty body must name a view; "{}" is not a connectivity check.
  if (!("view" in body) || typeof body.view !== "string") throw new RequestError("INVALID_REQUEST");

  const view = body.view;
  const merchantId = body.merchantId ?? null;
  if (merchantId !== null && (typeof merchantId !== "string" || !UUID.test(merchantId))) {
    throw new RequestError("INVALID_REQUEST");
  }
  const hasStart = body.start !== undefined && body.start !== null;
  const hasEnd = body.end !== undefined && body.end !== null;

  if (UNDATED_VIEWS.has(view)) {
    if (hasStart || hasEnd) throw new RequestError("INVALID_REQUEST");
    return { view, merchantId, start: null, end: null };
  }
  if (!DATED_VIEWS.has(view)) throw new RequestError("INVALID_REQUEST");
  // Dated views: both dates required, valid calendar dates, start <= end, <= 93 days inclusive.
  const s = parseDate(body.start);
  const e = parseDate(body.end);
  if (s === null || e === null) throw new RequestError("INVALID_REQUEST");
  const diff = dayDiff(s, e);
  if (diff < 0 || diff > MAX_RANGE_DAYS - 1) throw new RequestError("INVALID_REQUEST");
  return { view, merchantId, start: body.start as string, end: body.end as string };
}

async function handle(req: Request, origin: string | null): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return fail("METHOD_NOT_ALLOWED", origin);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    console.error("[rb04-app-api] missing environment configuration");
    return fail("INTERNAL", origin);
  }

  // 1. Verify identity with Supabase Auth (gateway verify_jwt already ran). Never trust JSON.
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  if (!jwt || jwt.split(".").length !== 3) return fail("UNAUTHENTICATED", origin);
  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userError } = await authClient.auth.getUser(jwt);
  const userId = userData?.user?.id;
  if (userError || !userId || !UUID.test(userId)) return fail("UNAUTHENTICATED", origin);

  // 2. Bounded body read. Empty (or whitespace-only) body = schemaVersion 1.0 connectivity.
  const raw = await readBody(req);
  if (!raw.trim()) {
    return json({
      ok: true, service: SERVICE, mode: "CONNECTIVITY_READONLY", schemaVersion: "1.0",
      environment: CONNECTIVITY_V1.environment,
      authentication: { verified: true },
      permissions: CONNECTIVITY_V1.permissions,
      data: { status: "CONNECTED", operationalDataAvailable: false },
      checkedAt: new Date().toISOString(),
    }, 200, origin);
  }
  const r = validate(raw);

  // 3. Authorize and read in the database with the verified user ID only.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await admin.rpc("rb04_app_readonly_dev", {
    p_user_id: userId, p_merchant_id: r.merchantId, p_view: r.view, p_start: r.start, p_end: r.end,
  });
  if (error) {
    // Includes 42501 "Service role required": a server misconfiguration, never a user error.
    console.error("[rb04-app-api] rpc failed", error.code);
    return fail("INTERNAL", origin);
  }
  const result = (data ?? {}) as Record<string, unknown>;
  if (result.ok !== true) {
    const code = String(result.code ?? "");
    if (RPC_CODES.has(code as ErrorCode)) return fail(code as ErrorCode, origin);
    console.error("[rb04-app-api] unmapped rpc code");
    return fail("INTERNAL", origin);
  }
  if (!Array.isArray(result.rows)) return fail("INTERNAL", origin);

  return json({
    ok: true, service: SERVICE, mode: "AUTHORIZED_READONLY", schemaVersion: "1.1",
    authentication: { verified: true },
    authorization: {
      role: result.role, merchantId: result.merchant_id, employeeLinked: result.employee_linked === true,
    },
    request: { view: r.view, start: r.start, end: r.end },
    data: {
      rows: result.rows, rowCount: result.row_count, truncated: result.truncated === true,
      reconciliation: "CLOVER_RECONCILIATION_PENDING",
    },
  }, 200, origin);
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  try {
    // Unchanged: disallowed origins get the existing rejection shape, before any other work.
    if (origin && !ALLOWED_ORIGINS.has(origin)) {
      return new Response(JSON.stringify({ ok: false, error: "Origin not allowed" }), {
        status: 403,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "Vary": "Origin" },
      });
    }
    return await handle(req, origin);
  } catch (err) {
    if (err instanceof RequestError) return fail(err.code, origin);
    console.error("[rb04-app-api] unhandled exception");
    return fail("INTERNAL", origin);
  }
});