// deno-lint-ignore-file no-explicit-any
import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? `https://${Deno.env.get("SUPABASE_PROJECT_REF")}.supabase.co`;
const ANON_KEY =
  Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY =
  Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ADMIN_INTERNAL_TOKEN = Deno.env.get("ADMIN_INTERNAL_TOKEN") ?? "";

const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function fetchUserByEmail(email: string) {
  try {
    const { data, error } = await service.auth.admin.listUsers({
      page: 1,
      perPage: 200,
      filter: `email.eq.${email}`,
    });
    if (error) {
      console.error("[admin__create_employee] listUsers error", error);
      return null;
    }
    const lower = email.toLowerCase();
    return data?.users?.find((u) => (u.email ?? "").toLowerCase() === lower) ?? null;
  } catch (err) {
    console.error("[admin__create_employee] listUsers threw", err);
    return null;
  }
}

async function isInternal(req: Request) {
  const h1 = req.headers.get("x-admin-internal-token");
  const h2 = req.headers.get("x-admin-internal");
  return !!ADMIN_INTERNAL_TOKEN &&
         (h1 === ADMIN_INTERNAL_TOKEN || h2 === ADMIN_INTERNAL_TOKEN);
}
async function assertSuperAdmin(req: Request) {
  if (await isInternal(req)) return;
  const auth = req.headers.get("authorization") ?? req.headers.get("Authorization");
  if (!auth?.toLowerCase().startsWith("bearer ")) throw new Response(null, { status: 401 });
  const anon = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } } });
  const { data } = await anon.auth.getUser();
  const { data: sa } = await service.from("super_admins").select("user_uid").eq("user_uid", data?.user?.id ?? "").maybeSingle();
  if (!sa) throw new Response(null, { status: 403 });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors() });
  try {
    await assertSuperAdmin(req);

    const body = await req.json().catch(() => ({} as any));
    const account_id = (body.account_id ?? body.accountId ?? "").toString();
    const email = (body.email ?? "").toString().trim().toLowerCase();
    const password = (body.password ?? "").toString();

    if (!account_id || !email || !password)
      return json({ error: "missing fields (account_id, email, password)" }, 400);

    // ensure user
    let uid: string;
    const existing = await fetchUserByEmail(email);
    if (existing?.id) {
      uid = existing.id;
    } else {
      const { data: created, error } = await service.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });
      if (error) {
        const msg = (error.message ?? "").toLowerCase();
        const already =
          msg.includes("already registered") ||
          msg.includes("already exists") ||
          msg.includes("user with email");
        if (!already) {
          console.error("[admin__create_employee] createUser failed", error);
          return json({ error: "failed to create user", detail: error.message }, 500);
        }
        const reused = await fetchUserByEmail(email);
        if (!reused?.id) {
          return json({ error: "failed to resolve existing user" }, 500);
        }
        uid = reused.id;
      } else if (created?.user?.id) {
        uid = created.user.id;
      } else {
        return json({ error: "failed to create user" }, 500);
      }
    }

    // prefer your SECURITY DEFINER function
    const { error: attachError } = await service.rpc(
      "admin_attach_employee",
      { p_account: account_id, p_user_uid: uid },
    );
    if (attachError) {
      console.error(
        "[admin__create_employee] admin_attach_employee failed",
        { account_id, uid, error: attachError },
      );
      // fallback direct upsert
      const { error: fallbackError } = await service.from("account_users").upsert({
        account_id,
        user_uid: uid,
        role: "employee",
        disabled: false,
        email,
      }, { onConflict: "account_id,user_uid" });
      if (fallbackError) {
        console.error(
          "[admin__create_employee] fallback upsert failed",
          { account_id, uid, error: fallbackError },
        );
        return json({ error: "failed to link employee", detail: fallbackError.message }, 500);
      }
      console.warn(
        "[admin__create_employee] fallback upsert succeeded after RPC failure",
        { account_id, uid },
      );
    }

    return json({ ok: true, user_uid: uid, account_id }, 200);
  } catch (r) {
    if (r instanceof Response) return withCors(r);
    return json({ error: "unexpected", detail: String(r) }, 500);
  }
});

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type, x-admin-internal-token, x-admin-internal",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
function withCors(r: Response) {
  const h = new Headers(r.headers);
  for (const [k, v] of Object.entries(cors())) h.set(k, v);
  return new Response(r.body, { status: r.status, headers: h });
}
function json(data: any, status = 200) {
  return withCors(new Response(JSON.stringify(data), {
    status, headers: { "Content-Type": "application/json; charset=utf-8" },
  }));
}
