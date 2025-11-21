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
const SUPER_ADMIN_EMAIL = (Deno.env.get("SUPER_ADMIN_EMAIL") ?? "admin@elmam.com").toLowerCase();

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

    const callerEmail = (me.user.email ?? "").toLowerCase();
    let isSuper = false;
    if (SUPER_ADMIN_EMAIL && callerEmail === SUPER_ADMIN_EMAIL) {
      isSuper = true;
    } else {
      const { data: saRow, error: saError } = await admin
        .from("super_admins")
        .select("user_uid")
        .eq("user_uid", me.user.id)
        .maybeSingle();
      if (saError) {
        return json(
          { ok: false, message: "super_admins lookup failed", details: saError.message },
          500,
        );
      }
      isSuper = !!saRow;
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
