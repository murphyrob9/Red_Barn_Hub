
import { createClient } from "npm:@supabase/supabase-js@2";

const respond = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return respond({ error: "POST required" }, 405);
  }

  const expectedSecret = Deno.env.get("RB04_TEST_SECRET");

  if (
    !expectedSecret ||
    req.headers.get("x-rb04-test-secret") !== expectedSecret
  ) {
    return respond({ error: "Unauthorized" }, 401);
  }

  // Fail closed unless DEV writes are explicitly disabled.
  if (Deno.env.get("RB04_ALLOW_DEV_WRITES") !== "false") {
    return respond({
      ok: false,
      error: "DEV write safety gate is not disabled",
      databaseWrites: false,
    }, 403);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey =
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!url || !serviceKey) {
    return respond({
      ok: false,
      error: "Supabase credentials unavailable",
      databaseWrites: false,
    }, 500);
  }

  try {
    const supabase = createClient(url, serviceKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    // Calls a restricted function in the public schema.
    // No direct access to the rb04 schema through Data API.
    const { data, error } = await supabase.rpc(
      "rb04_check_connection_dev"
    );

    if (error) {
      return respond({
        ok: false,
        connectivity: "FAILED",
        error: error.message,
        databaseWrites: false,
      }, 502);
    }

    const result = data as Record<string, unknown>;

    return respond({
      ...result,
      diagnosticFunction: "public.rb04_check_connection_dev",
      checkedAt: new Date().toISOString(),
    }, result.ok === true ? 200 : 409);

  } catch {
    return respond({
      ok: false,
      connectivity: "FAILED",
      error: "Unexpected connectivity diagnostic failure",
      databaseWrites: false,
    }, 502);
  }
});
