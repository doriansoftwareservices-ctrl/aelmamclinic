// supabase/functions/admin__list_employees/index.ts
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

type RpcEmployeeRow = {
  user_uid: string;
  email: string | null;
  role: string | null;
  disabled: boolean | null;
  created_at: string | null;
};

type AccountUserRow = {
  user_uid: string;
  role: string | null;
  disabled: boolean | null;
  created_at: string | null;
};

type Employee = {
  uid: string;
  email: string;
  role: string;
  disabled: boolean;
  created_at: string | null;
};

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

    const { account_id } = (await req.json()) as { account_id?: string };
    if (!account_id) return json({ ok: false, message: "missing account_id" }, 400);

    const authed = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: me, error: meErr } = await authed.auth.getUser();
    if (meErr || !me?.user) return json({ ok: false, message: "unauthenticated" }, 401);

    const email = (me.user.email ?? "").toLowerCase();
    let isSuper = false;
    if (SUPER_ADMIN_EMAIL && email === SUPER_ADMIN_EMAIL) {
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

    let allowed = isSuper;
    if (!allowed) {
      const { data: membership } = await authed
        .from("account_users")
        .select("role, disabled")
        .eq("account_id", account_id)
        .eq("user_uid", me.user.id)
        .in("role", ["owner", "admin"])
        .maybeSingle();
      allowed = !!membership && membership.disabled !== true;
    }

    if (!allowed) return json({ ok: false, message: "forbidden" }, 403);

    const { data: rpcData, error: rpcErr } = await authed.rpc<RpcEmployeeRow[]>(
      "list_employees_with_email",
      { p_account: account_id },
    );

    if (!rpcErr && Array.isArray(rpcData)) {
      const out: Employee[] = rpcData.map((row): Employee => ({
        uid: row.user_uid,
        email: row.email ?? "",
        role: row.role ?? "",
        disabled: Boolean(row.disabled),
        created_at: row.created_at ?? null,
      }));
      out.sort((a, b) => a.email.toLowerCase().localeCompare(b.email.toLowerCase()));
      return json(out, 200);
    }

    const { data: rows, error } = await admin
      .from("account_users")
      .select<AccountUserRow>("user_uid, role, disabled, created_at")
      .eq("account_id", account_id);

    if (error) throw error;

    const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    const emails = new Map<string, string>();
    for (const u of list?.users ?? []) {
      if (u?.id && u?.email) emails.set(u.id, String(u.email));
    }

    const out: Employee[] = (rows ?? [])
      .filter((row): row is AccountUserRow & { user_uid: string } => typeof row.user_uid === "string")
      .map((row) => ({
        uid: row.user_uid,
        email: emails.get(row.user_uid) ?? "",
        role: row.role ?? "",
        disabled: Boolean(row.disabled),
        created_at: row.created_at ?? null,
      }));

    out.sort((a, b) => a.email.toLowerCase().localeCompare(b.email.toLowerCase()));
    return json(out, 200);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ ok: false, message: msg }, 500);
  }
});
