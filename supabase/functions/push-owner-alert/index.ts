// Tells a school when something arrives that is waiting on them.
//
// Three Database Webhooks point here, all INSERT, all with the same secret:
//   registration_requests   a student asked to join
//   shop_orders             somebody ordered kit
//   payment_claims          somebody says they paid
//
// One function rather than three, because the only thing that differs is the
// table name -- which the webhook already sends -- and the wording, which lives
// in the database with the row it describes.
//
// Deploy:
//   supabase functions deploy push-owner-alert --no-verify-jwt
//
// ...or paste it into the dashboard editor and turn Verify JWT off afterwards.
// The caller is a webhook, not a signed-in person; this authenticates it on
// PUSH_HOOK_SECRET instead, the same secret push-announcement uses.
//
// It needs no secrets of its own beyond those four, which are already set.

import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HOOK_SECRET  = Deno.env.get("PUSH_HOOK_SECRET") ?? "";

// The three the webhooks are allowed to name. Anything else is refused rather
// than passed through to the database to puzzle over.
const TABLES = ["registration_requests", "shop_orders", "payment_claims"];

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:hello@paystamp.app",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

function sameSecret(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function rpc(name: string, body: unknown) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${name} ${r.status} ${await r.text()}`);
  return await r.json();
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });

  if (!HOOK_SECRET || !sameSecret(req.headers.get("x-push-secret") ?? "", HOOK_SECRET)) {
    return new Response("no", { status: 401 });
  }

  let payload: any;
  try { payload = await req.json(); } catch { return new Response("body", { status: 400 }); }

  const table = payload?.table;
  const id    = payload?.record?.id;
  if (!TABLES.includes(table)) return new Response("table", { status: 400 });
  if (!id) return new Response("no id", { status: 400 });

  const a = await rpc("push_owner_alert", { p_table: table, p_id: id });
  if (a?.error) {
    // nothing_to_say and not_approved are ordinary: a row that is not pending,
    // or a school that cannot open its own dashboard yet.
    return new Response(JSON.stringify({ skipped: a.error }), {
      status: 200, headers: { "Content-Type": "application/json" } });
  }

  // No badge. The number on the icon belongs to the family portal and means
  // unread announcements; a second writer with a different meaning is the
  // drift that made us count it in the database in the first place.
  const body = JSON.stringify({
    title: a.title || "PayStamp",
    body: a.body || "",
    url: "/app/",
    // Per row, so two orders do not replace one another.
    tag: table + "-" + id,
  });

  const subs: Array<{ endpoint: string; p256dh: string; auth: string }> =
    a.subscriptions ?? [];

  let sent = 0, gone = 0, failed = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        body,
        { TTL: 86400 },
      );
      sent++;
    } catch (e: any) {
      const code = e?.statusCode;
      if (code === 404 || code === 410) {
        gone++;
        try { await rpc("push_mark_gone", { p_endpoint: s.endpoint }); } catch { /* next time */ }
      } else {
        failed++;
        console.error("owner push failed", code, e?.body ?? e?.message);
      }
    }
  }

  console.log(`${table} ${id}: sent=${sent} gone=${gone} failed=${failed}`);
  return new Response(JSON.stringify({ sent, gone, failed }), {
    status: 200, headers: { "Content-Type": "application/json" } });
});
