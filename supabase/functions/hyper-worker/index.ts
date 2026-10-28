/**
 * Red Barn RB-04 DEV — Clover diagnostics + dormant ingestion implementation.
 * FULL replacement index.ts. All existing modes retained.
 *
 * SAFETY: commit_page_dev and import ALWAYS return 403.
 * rb04CommitPageImplementation is defined but never called by any route.
 * Clover requests use GET only. No scheduler or cursor-completion path.
 */
const MERCHANT_ID = "X3MHXR2NA6FG1";
const DEV_MERCHANT_UUID = "44b7802c-9152-4a58-a81f-b12280f809e7";
const BASE = "https://api.clover.com";
const PAGE_SIZE = 10, MAX_ATTEMPTS = 4, MAX_PAGES = 10;
const SETTLE_MS = 300_000, COMMIT_SETTLE_MS = 3_600_000, MAX_WINDOW_MS = 14_400_000;
const HIST_START = 1792903171105, HIST_END = 1792917571105;
const CONT_START = 1792903171105, CONT_END = 1792989571105;
type Resource = "orders" | "payments";
type Item = Record<string, unknown> & { id: string };
type Body = Record<string, unknown> & {
  mode?: unknown; resource?: unknown; startMs?: unknown;
  endMs?: unknown; expectedOffset?: unknown;
};
const MODES = [
  "preview", "import", "prepare_page_readonly", "db_connectivity_readonly",
  "diagnose", "diagnose_filters", "diagnose_bounded", "diagnose_sort",
  "diagnose_retry", "scan_readonly", "scan_continue", "verify_window_readonly",
  "verify_subwindows_readonly", "verify_range_readonly", "commit_page_dev",
  "validate_commit_readonly", "test_network_retry_readonly"
] as const;
type Mode = typeof MODES[number];
const ALLOWED_ORIGINS = new Set([
  "https://id-preview--b5201918-cc71-4086-81e8-65bf0d1a3486.lovable.app",
  "https://b5201918-cc71-4086-81e8-65bf0d1a3486.lovableproject.com"
]);

function corsHeaders(request: Request): Record<string, string> {
  const origin = request.headers.get("Origin");

  if (!origin || !ALLOWED_ORIGINS.has(origin)) {
    return {};
  }

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "3600",
    "Vary": "Origin"
  };
}
function respond(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
  });
}
function message(error: unknown): string {
  return error instanceof Error ? error.message : "Unknown error";
}
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
function urlFor(resource: Resource): URL {
  return new URL(`${BASE}/v3/merchants/${encodeURIComponent(MERCHANT_ID)}/${resource}`);
}
function delayFor(response: Response, attempt: number): number {
  const retryAfter = response.headers.get("Retry-After");
  if (retryAfter) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds * 1000, 15_000);
    const date = Date.parse(retryAfter);
    if (Number.isFinite(date)) return Math.min(Math.max(0, date - Date.now()), 15_000);
  }
  return Math.min(1000 * 2 ** (attempt - 1) + Math.floor(Math.random() * 500), 15_000);
}
type FetchLike = (input: string, init: RequestInit) => Promise<Response>;
async function get(url: URL, token: string, fetcher: FetchLike = fetch):
  Promise<{ response: Response; attempts: number }> {
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    let response: Response;
    try {
      response = await fetcher(url.toString(), {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
        signal: AbortSignal.timeout(15_000)
      });
    } catch {
      if (attempt === MAX_ATTEMPTS)
        throw new Error(`Clover network request failed after ${attempt} attempt(s)`);
      await sleep(delayFor(new Response(null, { status: 503 }), attempt));
      continue;
    }
    if (response.ok) return { response, attempts: attempt };
    const retryable = [429, 500, 502, 503, 504].includes(response.status);
    if (!retryable || attempt === MAX_ATTEMPTS) {
      await response.body?.cancel();
      throw new Error(`Clover HTTP ${response.status} after ${attempt} attempt(s)`);
    }
    const wait = delayFor(response, attempt);
    await response.body?.cancel();
    await sleep(wait);
  }
  throw new Error("Clover retry limit exhausted");
}
function records(data: unknown, resource: Resource, limit: number): Item[] {
  if (!data || typeof data !== "object" || Array.isArray(data) ||
      !Array.isArray((data as { elements?: unknown }).elements))
    throw new Error(`Invalid Clover ${resource} response`);
  const elements = (data as { elements: unknown[] }).elements;
  if (elements.length > limit) throw new Error(`Clover ${resource} response exceeds page limit`);
  const seen = new Set<string>(), validated: Item[] = [];
  for (const [index, value] of elements.entries()) {
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error(`Invalid Clover ${resource} record at index ${index}`);
    const record = value as Record<string, unknown>, id = record.id;
    if (typeof id !== "string" || id.length < 1 || id.length > 128)
      throw new Error(`Invalid Clover ${resource} record ID at index ${index}`);
    if (seen.has(id)) throw new Error(`Duplicate Clover ${resource} record ID within page`);
    seen.add(id);
    validated.push(record as Item);
  }
  return validated;
}
async function page(resource: Resource, token: string, offset: number, limit: number,
  start?: number, end?: number) {
  const url = urlFor(resource);
  if (start !== undefined && end !== undefined) {
    url.searchParams.append("filter", `modifiedTime>=${start}`);
    url.searchParams.append("filter", `modifiedTime<${end}`);
  }
  url.searchParams.set("limit", String(limit));
  url.searchParams.set("offset", String(offset));
  const { response, attempts } = await get(url, token);
  return { items: records(await response.json(), resource, limit), attempts };
}
function checkWindow(start: number, end: number) {
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 ||
      start >= end || end - start > MAX_WINDOW_MS || end > Date.now() - SETTLE_MS)
    throw new Error("Invalid verification window. Use a settled interval of up to four hours.");
}
function validateCommitRequest(body: Body): string[] {
  const errors: string[] = [];
  if (body.resource !== "orders" && body.resource !== "payments")
    errors.push("resource must be orders or payments");
  const start = body.startMs, end = body.endMs;
  if (typeof start !== "number" || typeof end !== "number" ||
      !Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || end <= start || end - start > MAX_WINDOW_MS ||
      end > Date.now() - COMMIT_SETTLE_MS)
    errors.push("scan window must be valid, no longer than four hours, and at least 60 minutes old");
  const offset = body.expectedOffset;
  if (typeof offset !== "number" || !Number.isSafeInteger(offset) ||
      offset < 0 || offset > 2147483647 - PAGE_SIZE)
    errors.push("expectedOffset must be a valid nonnegative integer");
  for (const field of ["p_records", "p_merchant_id", "rpcArguments", "records",
                       "merchantId", "merchant_id"])
    if (Object.prototype.hasOwnProperty.call(body, field))
      errors.push(`Caller-supplied field is prohibited: ${field}`);
  return errors;
}
async function preparePageReadonly(body: Body, token: string) {
  const errors = validateCommitRequest(body);
  if (errors.length) throw new Error(errors.join("; "));
  const resource = body.resource as Resource, startMs = body.startMs as number;
  const endMs = body.endMs as number, expectedOffset = body.expectedOffset as number;
  const result = await page(resource, token, expectedOffset, PAGE_SIZE, startMs, endMs);
  const validationErrors: string[] = [];
  for (const [index, item] of result.items.entries()) {
    const modified = item.modifiedTime;
    if (typeof modified !== "number" || !Number.isSafeInteger(modified) ||
        modified < startMs || modified >= endMs)
      validationErrors.push(`record ${index}: modifiedTime outside window or not an integer`);
  }
  const valid = validationErrors.length === 0;
  return {
    ok: valid, environment: "DEV", mode: "PREPARE_PAGE_READONLY", resource,
    scanWindow: { startMs, endMs }, expectedOffset, pageSize: PAGE_SIZE,
    recordsReceived: result.items.length, uniqueIdsInPage: result.items.length,
    terminalPageObserved: result.items.length < PAGE_SIZE,
    nextOffset: expectedOffset + result.items.length,
    retryAttempts: result.attempts - 1,
    validation: { passed: valid, errors: validationErrors },
    rpcFunction: "public.rb04_commit_clover_page_dev",
    rpcArgumentsIncluded: false, recordPayloadsIncluded: false,
    pageEligibleForFutureCommit: valid,
    scanCompletenessProven: false, independentlyVerified: false,
    cursorAdvanceAllowed: false, databaseWrites: false,
    normalizationExecuted: false, checkpointsUpdated: false, rpcExecuted: false,
    checkedAt: new Date().toISOString()
  };
}
async function windowScan(resource: Resource, start: number, end: number,
  token: string, maxPages = MAX_PAGES, offsetStart = 0) {
  const seen = new Set<string>(), duplicateIds: string[] = [], pages: unknown[] = [];
  let recordsRead = 0, retries = 0, terminalPageObserved = false;
  let allWithinWindow = true, stoppedReason = "PAGE_LIMIT";
  for (let i = 0; i < maxPages; i++) {
    const offset = offsetStart + i * PAGE_SIZE;
    const result = await page(resource, token, offset, PAGE_SIZE, start, end);
    const details = result.items.map(r => ({
      id: r.id, modifiedTime: r.modifiedTime ?? null, createdTime: r.createdTime ?? null
    }));
    const valid = details.every(r => typeof r.modifiedTime === "number" &&
      Number.isSafeInteger(r.modifiedTime) && r.modifiedTime >= start && r.modifiedTime < end);
    for (const r of details) {
      if (seen.has(r.id)) duplicateIds.push(r.id);
      seen.add(r.id);
    }
    recordsRead += details.length;
    retries += result.attempts - 1;
    allWithinWindow &&= valid;
    pages.push({ page: i + 1, offset, count: details.length,
      attempts: result.attempts, allWithinWindow: valid });
    if (!valid) { stoppedReason = "VALIDATION_FAILED"; break; }
    if (details.length < PAGE_SIZE) {
      terminalPageObserved = true; stoppedReason = "SHORT_PAGE_OBSERVED"; break;
    }
    if (i < maxPages - 1) await sleep(500);
  }
  return { startMs: start, endMs: end, ids: [...seen].sort(),
    duplicateIds: [...new Set(duplicateIds)].sort(), pagesRead: pages.length,
    recordsRead, retries, terminalPageObserved, allWithinWindow, stoppedReason, pages };
}
async function verify(resource: Resource, start: number, end: number, token: string) {
  checkWindow(start, end);
  const original = await windowScan(resource, start, end, token);
  const subwindows = [];
  for (let from = start; from < end; from += 3_600_000)
    subwindows.push(await windowScan(resource, from, Math.min(from + 3_600_000, end), token));
  const originalIds = new Set(original.ids), combined = new Set<string>(), cross: string[] = [];
  for (const window of subwindows) for (const id of window.ids) {
    if (combined.has(id)) cross.push(id);
    combined.add(id);
  }
  const missingFromSubwindows = original.ids.filter(id => !combined.has(id));
  const additionalInSubwindows = [...combined].filter(id => !originalIds.has(id));
  const all = [original, ...subwindows];
  const idsMatch = !missingFromSubwindows.length && !additionalInSubwindows.length;
  const duplicateFree = all.every(w => !w.duplicateIds.length) && !cross.length;
  const allWindowsTerminated = all.every(w => w.terminalPageObserved);
  const allRecordsValid = all.every(w => w.allWithinWindow);
  return {
    resource, startMs: start, endMs: end,
    result: idsMatch && duplicateFree && allWindowsTerminated && allRecordsValid ? "PASS" : "FAIL",
    original: { recordsRead: original.recordsRead, uniqueIds: original.ids.length,
      pagesRead: original.pagesRead, terminalPageObserved: original.terminalPageObserved,
      duplicateCount: original.duplicateIds.length, stoppedReason: original.stoppedReason },
    subwindows: subwindows.map((w, i) => ({
      number: i + 1, startMs: w.startMs, endMs: w.endMs, recordsRead: w.recordsRead,
      uniqueIds: w.ids.length, pagesRead: w.pagesRead,
      terminalPageObserved: w.terminalPageObserved, allWithinWindow: w.allWithinWindow,
      duplicateCount: w.duplicateIds.length, stoppedReason: w.stoppedReason
    })),
    combinedUniqueIds: combined.size, missingFromSubwindowsCount: missingFromSubwindows.length,
    additionalInSubwindowsCount: additionalInSubwindows.length,
    crossWindowDuplicateCount: new Set(cross).size, idsMatch, duplicateFree,
    allWindowsTerminated, allRecordsValid,
    totalRetries: all.reduce((n, w) => n + w.retries, 0),
    independentlyVerified: false, cursorAdvanceAllowed: false, databaseWrites: false
  };
}
async function pagination(resource: Resource, token: string) {
  const first = await page(resource, token, 0, 5), second = await page(resource, token, 5, 5);
  const format = (p: typeof first, offset: number) => ({
    offset, count: p.items.length, createdTimes: p.items.map(x => x.createdTime ?? null),
    modifiedTimes: p.items.map(x => x.modifiedTime ?? null)
  });
  const firstIds = new Set(first.items.map(x => x.id));
  return { resource, firstPage: format(first, 0), secondPage: format(second, 5),
    overlappingIdCount: second.items.filter(x => firstIds.has(x.id)).length,
    readOnly: true, databaseWrites: false };
}
async function filters(resource: Resource, token: string) {
  const end = Date.now(), start = end - 86_400_000, results = [];
  for (const field of ["createdTime", "modifiedTime"] as const) {
    const url = urlFor(resource);
    url.searchParams.append("filter", `${field}>=${start}`);
    url.searchParams.append("filter", `${field}<${end}`);
    url.searchParams.set("limit", "10"); url.searchParams.set("offset", "0");
    const { response } = await get(url, token);
    const items = records(await response.json(), resource, 10);
    const timestamps = items.map(r => r[field]);
    results.push({ field, httpStatus: response.status, accepted: true,
      returned: items.length, withinWindow: timestamps.every(t =>
        typeof t === "number" && t >= start && t < end),
      allowedFilterFields: response.headers.get("X-Clover-Allowed-Filter-Fields") });
  }
  return { resource, windowStartMs: start, windowEndMs: end, results, readOnly: true };
}
async function bounded(resource: Resource, token: string) {
  const end = Date.now() - 60_000, start = end - 86_400_000;
  const read = async (offset: number) => {
    const p = await page(resource, token, offset, 5, start, end);
    return { offset, httpStatus: 200, accepted: true, count: p.items.length,
      allWithinWindow: p.items.every(r => typeof r.modifiedTime === "number" &&
        r.modifiedTime >= start && r.modifiedTime < end), ids: p.items.map(r => r.id) };
  };
  const first = await read(0), second = await read(5), ids = new Set(first.ids);
  return { resource, startMs: start, endMs: end,
    page0: { ...first, ids: undefined }, page1: { ...second, ids: undefined },
    overlappingIdCount: second.ids.filter(id => ids.has(id)).length, readOnly: true };
}
async function sorting(resource: Resource, token: string) {
  const results = [];
  for (const sort of ["createdTime DESC", "modifiedTime DESC", "id ASC"]) {
    const url = urlFor(resource);
    url.searchParams.set("limit", "10"); url.searchParams.set("offset", "0");
    url.searchParams.set("sort", sort);
    const { response } = await get(url, token);
    const items = records(await response.json(), resource, 10);
    const field = sort.split(" ")[0] as "id" | "createdTime" | "modifiedTime";
    const ascending = sort.endsWith("ASC");
    const correctlyOrdered = items.every((item, i) => {
      if (!i) return true;
      const left = items[i - 1][field], right = item[field];
      if (typeof left !== typeof right) return false;
      if (typeof left === "number" && typeof right === "number")
        return ascending ? right >= left : right <= left;
      if (typeof left === "string" && typeof right === "string")
        return ascending ? right >= left : right <= left;
      return false;
    });
    results.push({ sort, httpStatus: response.status, accepted: true,
      returned: items.length, correctlyOrdered });
  }
  return { resource, results, readOnly: true };
}
async function checkDatabaseConnectivityReadonly() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) throw new Error("Supabase connectivity configuration missing");
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/rest/v1/rpc/rb04_check_connection_dev`,
    { method: "POST", headers: { apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`, "Content-Type": "application/json" },
      body: "{}", signal: AbortSignal.timeout(15_000) }
  );
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`Database connectivity HTTP ${response.status}`);
  }
  const result = await response.json();
  if (result?.ok !== true || result?.connectivity !== "PASS" ||
      result?.merchantId !== DEV_MERCHANT_UUID)
    throw new Error("Database connectivity baseline mismatch");
  return { ...result, checkedAt: new Date().toISOString() };
}
async function testNetworkRetryReadonly() {
  let attempts = 0;
  const mockFetch: FetchLike = async () => {
    attempts++;
    if (attempts === 1) throw new TypeError("Simulated network failure");
    return new Response(JSON.stringify({ elements: [] }), {
      status: 200, headers: { "Content-Type": "application/json" }
    });
  };
  const { response, attempts: reportedAttempts } =
    await get(urlFor("orders"), "MOCK_TOKEN_NOT_REAL", mockFetch);
  await response.body?.cancel();
  const passed = response.ok && attempts === 2 && reportedAttempts === 2;
  return { ok: passed, environment: "DEV", mode: "TEST_NETWORK_RETRY_READONLY",
    simulatedAttempts: attempts, networkFailureRecovered: passed,
    cloverRequests: 0, rpcExecuted: false, databaseWrites: false, checkpointsUpdated: false };
}

/**
 * DORMANT implementation — not referenced by the request handler.
 * Keep disabled until an explicitly approved DEV write phase.
 */
type RB04CommitPageRequest = {
  resource: Resource; startMs: number; endMs: number; expectedOffset: number;
};
async function rb04FetchValidatedPage(input: RB04CommitPageRequest, token: string) {
  const { resource, startMs, endMs, expectedOffset } = input;
  const result = await page(resource, token, expectedOffset, PAGE_SIZE, startMs, endMs);
  for (const [index, record] of result.items.entries()) {
    const modified = record.modifiedTime;
    if (typeof modified !== "number" || !Number.isSafeInteger(modified) ||
        modified < startMs || modified >= endMs)
      throw new Error(`Invalid Clover modifiedTime at page index ${index}`);
  }
  return { records: result.items, retryAttempts: result.attempts - 1,
    terminalPageObserved: result.items.length < PAGE_SIZE };
}
async function rb04CommitPageImplementation(input: RB04CommitPageRequest, token: string) {
  const errors = validateCommitRequest({ mode: "commit_page_dev", ...input });
  if (errors.length) throw new Error(`Invalid commit request: ${errors.join("; ")}`);
  const { records: pageRecords, retryAttempts, terminalPageObserved } =
    await rb04FetchValidatedPage(input, token);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) throw new Error("Supabase RPC configuration missing");
  const rpcResponse = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/rest/v1/rpc/rb04_commit_clover_page_dev`,
    { method: "POST", headers: {
        apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json", Accept: "application/json"
      },
      body: JSON.stringify({
        p_merchant_id: DEV_MERCHANT_UUID, p_resource: input.resource,
        p_scan_start_ms: input.startMs, p_scan_end_ms: input.endMs,
        p_expected_offset: input.expectedOffset, p_records: pageRecords,
        p_page_complete: terminalPageObserved, p_retry_attempts: retryAttempts
      }),
      signal: AbortSignal.timeout(15_000)
    }
  );
  if (!rpcResponse.ok) {
    await rpcResponse.body?.cancel();
    throw new Error(`RB-04 commit RPC rejected request (HTTP ${rpcResponse.status})`);
  }
  const data: unknown = await rpcResponse.json();
  if (!data || typeof data !== "object" || Array.isArray(data))
    throw new Error("Invalid RB-04 commit RPC response");
  const result = data as Record<string, unknown>;
  if (result.ok !== true || result.resource !== input.resource ||
      result.recordsReceived !== pageRecords.length ||
      result.nextOffset !== input.expectedOffset + pageRecords.length ||
      result.status !== (terminalPageObserved ? "PAUSED" : "RUNNING") ||
      result.reconciled !== false || result.independentlyVerified !== false ||
      result.cursorAdvanceAllowed !== false)
    throw new Error("RB-04 commit RPC response mismatch; inspect DB state before retrying");
  return { ok: true, resource: input.resource, recordsReceived: pageRecords.length,
    nextOffset: result.nextOffset, status: result.status,
    terminalPageReported: terminalPageObserved,
    reconciled: false, independentlyVerified: false, cursorAdvanceAllowed: false };
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") return respond({ ok: false, error: "POST required" }, 405);
  const secret = Deno.env.get("RB04_TEST_SECRET");
  if (!secret || request.headers.get("x-rb04-test-secret") !== secret)
    return respond({ ok: false, error: "Unauthorized" }, 401);
  let body: Body;
  try {
    const parsed: unknown = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    body = parsed as Body;
  } catch {
    return respond({ ok: false, error: "Invalid JSON object" }, 400);
  }
  const requested = body.mode ?? "preview";
  if (typeof requested !== "string" || !MODES.includes(requested as Mode))
    return respond({ ok: false, error: "Invalid mode", allowedModes: MODES }, 400);
  const mode = requested as Mode;

  // HARD STOP: no request can reach the dormant ingestion implementation.
  if (mode === "commit_page_dev") {
    const errors = validateCommitRequest(body);
    return respond({ ok: false, environment: "DEV", mode: "COMMIT_PAGE_DEV",
      error: "DEV page commits remain administratively disabled",
      validation: { passed: errors.length === 0, errors },
      writeGateEnabled: Deno.env.get("RB04_ALLOW_DEV_WRITES") === "true",
      commitExecutionEnabled: false, cloverRequests: 0, rpcExecuted: false,
      databaseWrites: false, normalizationExecuted: false,
      checkpointsUpdated: false, cursorAdvanceAllowed: false }, 403);
  }
  if (mode === "import")
    return respond({ ok: false, environment: "DEV", mode: "IMPORT",
      error: "DEV import is disabled in this read-only build",
      cloverRequests: 0, rpcExecuted: false, databaseWrites: false,
      normalizationExecuted: false, checkpointsUpdated: false,
      cursorAdvanceAllowed: false }, 403);
  if (mode === "validate_commit_readonly") {
    const errors = validateCommitRequest(body);
    return respond({ ok: errors.length === 0, environment: "DEV",
      mode: "VALIDATE_COMMIT_READONLY",
      validation: { passed: errors.length === 0, errors },
      writeGateEnabled: false, cloverRequests: 0, rpcExecuted: false,
      databaseWrites: false, normalizationExecuted: false,
      checkpointsUpdated: false, cursorAdvanceAllowed: false }, errors.length ? 422 : 200);
  }

  try {
    if (mode === "test_network_retry_readonly") {
      const result = await testNetworkRetryReadonly();
      return respond(result, result.ok ? 200 : 500);
    }
    if (mode === "diagnose_retry") {
      const explicit = delayFor(new Response(null, {
        status: 429, headers: { "Retry-After": "3" }
      }), 1);
      const fallback = delayFor(new Response(null, { status: 503 }), 2);
      const passed = explicit === 3000 && fallback >= 2000 && fallback <= 2500;
      return respond({ ok: passed, environment: "DEV", mode: "DIAGNOSE_RETRY",
        databaseWrites: false, cloverRequests: 0,
        explicitRetryAfterMs: explicit, fallbackRetryMs: fallback,
        maxAttempts: MAX_ATTEMPTS, testPassed: passed }, passed ? 200 : 500);
    }
    if (mode === "db_connectivity_readonly")
      return respond(await checkDatabaseConnectivityReadonly());
    if (Deno.env.get("CLOVER_MERCHANT_ID") !== MERCHANT_ID ||
        !Deno.env.get("CLOVER_ACCESS_TOKEN"))
      return respond({ ok: false, error: "Clover configuration invalid" }, 500);
    const token = Deno.env.get("CLOVER_ACCESS_TOKEN")!;
    if (mode === "prepare_page_readonly") {
      const result = await preparePageReadonly(body, token);
      return respond(result, result.ok ? 200 : 422);
    }
    if (mode === "verify_range_readonly") {
      if (body.resource !== "orders" && body.resource !== "payments")
        return respond({ ok: false, error: "Resource must be orders or payments" }, 400);
      if (typeof body.startMs !== "number" || typeof body.endMs !== "number")
        return respond({ ok: false, error: "startMs and endMs must be numbers" }, 400);
      const verification = await verify(body.resource, body.startMs, body.endMs, token);
      return respond({ ok: true, environment: "DEV", mode: "VERIFY_RANGE_READONLY",
        verification, databaseWrites: false, normalizationExecuted: false,
        checkpointsUpdated: false, checkedAt: new Date().toISOString() });
    }
    if (mode === "verify_window_readonly") {
      const result = await windowScan("payments", HIST_START, HIST_END, token, 5);
      return respond({ ok: true, environment: "DEV", mode: "VERIFY_WINDOW_READONLY",
        verification: { resource: "payments",
          window: { startMs: HIST_START, endMs: HIST_END },
          pageSize: PAGE_SIZE, maxPages: 5, pagesRead: result.pagesRead,
          recordsRead: result.recordsRead, uniqueIds: result.ids.length,
          duplicateCount: result.duplicateIds.length,
          nextOffset: result.recordsRead, retryAttempts: result.retries,
          terminalPageObserved: result.terminalPageObserved,
          stoppedReason: result.stoppedReason, independentlyVerified: false,
          cursorAdvanceAllowed: false, databaseWrites: false, pages: result.pages },
        databaseWrites: false, normalizationExecuted: false,
        checkpointsUpdated: false, checkedAt: new Date().toISOString() });
    }
    if (mode === "verify_subwindows_readonly") {
      const windows = [], combined = new Set<string>();
      let totalRetries = 0, allWindowsTerminated = true, allRecordsValid = true;
      for (let i = 0; i < 4; i++) {
        const start = HIST_START + i * 3_600_000;
        const end = Math.min(start + 3_600_000, HIST_END);
        const result = await windowScan("payments", start, end, token, 5);
        for (const id of result.ids) combined.add(id);
        totalRetries += result.retries;
        allWindowsTerminated &&= result.terminalPageObserved;
        allRecordsValid &&= result.allWithinWindow;
        windows.push({ window: i + 1, startMs: start, endMs: end,
          count: result.recordsRead, uniqueIds: result.ids.length,
          allWithinWindow: result.allWithinWindow,
          terminalPageObserved: result.terminalPageObserved,
          pagesRead: result.pagesRead, duplicateCount: result.duplicateIds.length });
      }
      return respond({ ok: true, environment: "DEV", mode: "VERIFY_SUBWINDOWS_READONLY",
        verification: { resource: "payments",
          originalWindow: { startMs: HIST_START, endMs: HIST_END },
          combinedSubwindowCount: combined.size, windows,
          allWindowsTerminated, allRecordsValid, totalRetries,
          independentlyVerified: false, cursorAdvanceAllowed: false,
          databaseWrites: false },
        databaseWrites: false, normalizationExecuted: false,
        checkpointsUpdated: false, checkedAt: new Date().toISOString() });
    }
    if (mode === "diagnose") {
      const orders = await pagination("orders", token);
      const payments = await pagination("payments", token);
      return respond({ ok: true, environment: "DEV", mode: "DIAGNOSE",
        databaseWrites: false, normalizationExecuted: false,
        orders, payments, checkedAt: new Date().toISOString() });
    }
    if (mode === "diagnose_filters")
      return respond({ ok: true, environment: "DEV", mode: "DIAGNOSE_FILTERS",
        databaseWrites: false, normalizationExecuted: false,
        orders: await filters("orders", token), payments: await filters("payments", token) });
    if (mode === "diagnose_bounded")
      return respond({ ok: true, environment: "DEV", mode: "DIAGNOSE_BOUNDED",
        databaseWrites: false, normalizationExecuted: false,
        orders: await bounded("orders", token), payments: await bounded("payments", token) });
    if (mode === "diagnose_sort")
      return respond({ ok: true, environment: "DEV", mode: "DIAGNOSE_SORT",
        databaseWrites: false, normalizationExecuted: false,
        orders: await sorting("orders", token), payments: await sorting("payments", token) });
    if (mode === "scan_readonly" || mode === "scan_continue") {
      const continuation = mode === "scan_continue";
      const end = continuation ? CONT_END : Date.now() - SETTLE_MS;
      const start = continuation ? CONT_START : end - 86_400_000;
      const offset = continuation ? 50 : 0;
      const scan = async (resource: Resource) => {
        const result = await windowScan(resource, start, end, token, 5, offset);
        return { startingOffset: offset, nextOffset: offset + result.recordsRead,
          resource, startMs: start, endMs: end, pageSize: PAGE_SIZE,
          maxPages: 5, pagesRead: result.pagesRead,
          totalRecords: result.recordsRead, uniqueRecords: result.ids.length,
          duplicateCount: result.duplicateIds.length,
          retryAttempts: result.retries, complete: result.terminalPageObserved,
          stoppedReason: result.terminalPageObserved ?
            "END_OF_RESULTS_OBSERVED" : result.stoppedReason,
          pages: result.pages, readOnly: true };
      };
      const orders = await scan("orders");
      await sleep(1000);
      const payments = await scan("payments");
      return respond({ ok: true, environment: "DEV",
        mode: continuation ? "SCAN_CONTINUE" : "SCAN_READONLY",
        databaseWrites: false, normalizationExecuted: false,
        checkpointsUpdated: false, scanWindow: { startMs: start, endMs: end },
        startingOffset: offset, orders, payments, checkedAt: new Date().toISOString() });
    }
    const orders = (await page("orders", token, 0, 5)).items;
    const payments = (await page("payments", token, 0, 5)).items;
    return respond({ ok: true, environment: "DEV", mode: "PREVIEW",
      merchantId: MERCHANT_ID,
      results: { orders: { fetched: orders.length, inserted: 0, duplicates: 0 },
        payments: { fetched: payments.length, inserted: 0, duplicates: 0 } },
      databaseWrites: false, normalizationExecuted: false,
      checkpointsUpdated: false, checkedAt: new Date().toISOString() });
  } catch (error) {
    console.error("RB04 read-only mode failed", mode, message(error));
    return respond({ ok: false, environment: "DEV", mode: mode.toUpperCase(),
      databaseWrites: false, normalizationExecuted: false,
      checkpointsUpdated: false,
      error: "Read-only operation failed; inspect Edge Function logs" }, 502);
  }
});
