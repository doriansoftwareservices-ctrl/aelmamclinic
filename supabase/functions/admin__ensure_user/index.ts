import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;              // متغير منصّة جاهز تلقائيًا
const serviceKey =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
if (!serviceKey) throw new Error("Missing SUPABASE_SERVICE_ROLE_KEY / SERVICE_ROLE_KEY env");

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");

    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

    // هوية المستدعي
    const { data: caller } = await admin.auth.getUser(jwt);
    if (!caller?.user) return new Response("Unauthorized", { status: 401 });

    // تحقّق أنّه سوبر أدمن (اختر إحدى الطريقتين أو أبقهما معًا)
    const { data: sa } = await admin.from("super_admins")
      .select("user_uid").eq("user_uid", caller.user.id).maybeSingle();
    const isSA = !!sa;
    if (!isSA) return new Response("Forbidden", { status: 403 });

    const { email, password } = await req.json();

    // إنشاء المستخدم أو جلبه
    const created = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { created_by: "admin__ensure_user" },
    });

    let userId = created.data?.user?.id ?? null;
    if (!userId) {
      const r = await admin.schema("auth").from("users")
        .select("id").eq("email", email).maybeSingle();
      userId = r.data?.id ?? null;
    }
    if (!userId) {
      return new Response(JSON.stringify({ error: "could_not_create_or_find_user" }),
        { status: 400, headers: { "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ user_uid: userId }),
      { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }),
      { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
