import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? `https://${Deno.env.get("PROJECT_REF")}.supabase.co`;
const ANON_KEY =
  Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY =
  Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPER_ADMIN_EMAIL = (Deno.env.get("SUPER_ADMIN_EMAIL") ?? "").toLowerCase();
const ADMIN_INTERNAL_TOKEN = Deno.env.get("ADMIN_INTERNAL_TOKEN") ?? "";

if (!SUPABASE_URL || !ANON_KEY || !SERVICE_ROLE_KEY) {
  throw new Error("Missing Supabase configuration envs");
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-admin-internal-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, payload: unknown) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json().catch(() => ({}));
    const userUid = String(body.user_uid ?? body.userUid ?? "").trim();
    const accountId = String(body.account_id ?? body.accountId ?? "").trim();
    const role = String(body.role ?? "").trim();

    if (!userUid || !accountId || !role) {
      return json(400, { error: "user_uid, account_id and role are required" });
    }

    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });

    const internalToken = req.headers.get("x-admin-internal-token");
    if (!(internalToken && internalToken === ADMIN_INTERNAL_TOKEN)) {
      const authHeader = req.headers.get("authorization") ?? "";
      if (!/^bearer /i.test(authHeader)) {
        return json(401, { error: "missing bearer token" });
      }
      const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
        auth: { persistSession: false },
      });
      const { data: caller, error } = await callerClient.auth.getUser();
      if (error || !caller?.user) {
        return json(401, { error: "invalid jwt", details: error?.message });
      }
      const callerEmail = (caller.user.email ?? "").toLowerCase();
      let isSuper = SUPER_ADMIN_EMAIL && callerEmail === SUPER_ADMIN_EMAIL;
      if (!isSuper) {
        const { data: saRow, error: saError } = await adminClient
          .from("super_admins")
          .select("user_uid")
          .eq("user_uid", caller.user.id)
          .maybeSingle();
        if (saError) {
          return json(500, { error: "super_admins lookup failed", details: saError.message });
        }
        isSuper = !!saRow;
      }
      if (!isSuper) {
        return json(403, { error: "not a super admin" });
      }
    }

    const { data: existing, error: fetchErr } = await adminClient.auth.admin.getUserById(userUid);
    if (fetchErr || !existing?.user) {
      return json(404, { error: "user not found", details: fetchErr?.message });
    }

    const baseAppMeta = (existing.user.app_metadata ?? {}) as Record<string, unknown>;
    const baseUserMeta = (existing.user.user_metadata ?? {}) as Record<string, unknown>;

    await adminClient.auth.admin.updateUserById(userUid, {
      app_metadata: { ...baseAppMeta, account_id: accountId, role },
      user_metadata: { ...baseUserMeta, account_id: accountId, role },
    });

    return json(200, { ok: true });
  } catch (error) {
    return json(500, { error: String(error) });
  }
});
