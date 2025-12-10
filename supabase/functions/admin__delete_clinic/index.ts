// supabase/functions/admin__delete_clinic/index.ts
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { serve } from "jsr:@supabase/functions-js";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
if (!SERVICE_ROLE_KEY) throw new Error("Missing SUPABASE_SERVICE_ROLE_KEY / SERVICE_ROLE_KEY env");
function normalizeEmail(email?: string | null) {
  return (email ?? "").trim().toLowerCase();
}

async function isSuperAdminUser(
  adminClient: ReturnType<typeof createClient>,
  userId: string | null,
  email: string | null,
) {
  const normalized = normalizeEmail(email);
  if (!userId && !normalized) return false;

  let query = adminClient.from("super_admins").select("id").limit(1);
  if (userId && normalized) {
    query = query.or(`user_uid.eq.${userId},email.eq.${normalized}`);
  } else if (userId) {
    query = query.eq("user_uid", userId);
  } else {
    query = query.eq("email", normalized);
  }

  const { data, error } = await query.maybeSingle();
  if (error && error.code !== "PGRST116") {
    throw new Error(`[admin__delete_clinic] super_admins lookup failed: ${error.message}`);
  }
  return !!data;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") {
      return json({ ok: false, message: "Method not allowed" }, 405);
    }

    const { account_id, clinicId } =
      (await req.json()) as { account_id?: string; clinicId?: string };
    const target: string | undefined = account_id ?? clinicId;
    if (!target) return json({ ok: false, message: "missing account_id/clinicId" }, 400);

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: me, error: meErr } = await userClient.auth.getUser();
    if (meErr || !me?.user) return json({ ok: false, message: "unauthenticated" }, 401);

    let isSuper = false;
    try {
      isSuper = await isSuperAdminUser(admin, me.user.id, me.user.email);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      return json(
        { ok: false, message: "super_admins lookup failed", details: detail },
        500,
      );
    }

    if (!isSuper) {
      return json({ ok: false, message: "not allowed" }, 403);
    }

    const { error } = await admin.from("accounts").delete().eq("id", target);
    if (error) throw error;

    return json({ ok: true });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ ok: false, message: msg }, 500);
  }
});
