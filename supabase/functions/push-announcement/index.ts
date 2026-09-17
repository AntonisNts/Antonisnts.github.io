// Sends a Web Push to every parent an announcement is for.
//
// Triggered by a Database Webhook on INSERT into public.announcements. It is a
// server because signing a Web Push request needs the VAPID private key, and a
// private key cannot live in a page that every parent downloads.
//
// Deploy:
//   supabase functions deploy push-announcement --no-verify-jwt
//
//   --no-verify-jwt because the caller is a database webhook, not a signed-in
//   person. The function does its own authentication instead, on a shared
//   secret -- see PUSH_HOOK_SECRET below. Without that check this URL would be
//   a way for anyone to make every parent's phone buzz.
//
// Secrets it needs (Project Settings -> Edge Functions -> Secrets):
//   VAPID_PUBLIC_KEY    the same key the app ships
//   VAPID_PRIVATE_KEY   never in the repo, never in the app
//   VAPID_SUBJECT       mailto:you@yourdomain  (push services want a contact)
//   PUSH_HOOK_SECRET    any long random string; also set as a webhook header
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HOOK_SECRET  = Deno.env.get("PUSH_HOOK_SECRET") ?? "";

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:hello@paystamp.app",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

// Compare without leaking how much of the secret was right through timing.
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

// A notification is a preview, not the message. It is read on a lock screen,
// possibly by whoever picks the phone up, so it carries the school's name and
// the headline and stops there -- the rest is behind the app.
function trim(s: string | null, n: number): string {
  const t = (s ?? "").replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n - 1) + "…" : t;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });

  if (!HOOK_SECRET || !sameSecret(req.headers.get("x-push-secret") ?? "", HOOK_SECRET)) {
    // Deliberately says nothing about which part was wrong.
    return new Response("no", { status: 401 });
  }

  let payload: any;
  try { payload = await req.json(); } catch { return new Response("body", { status: 400 }); }

  // Database Webhook shape: { type, table, record, old_record, schema }
  const rec = payload?.record ?? payload;
  const id  = rec?.id;
  if (!id) return new Response("no id", { status: 400 });

  // The audience rules live in the database, with the announcement, rather than
  // being re-derived here where they could drift from what the portal shows.
  const aud = await rpc("push_audience", { p_announcement_id: id });
  if (aud?.error) {
    // not_active covers an announcement that was inserted already expired or
    // switched off. Not a failure -- there is simply nobody to tell.
    return new Response(JSON.stringify({ skipped: aud.error }), {
      status: 200, headers: { "Content-Type": "application/json" } });
  }

  const subs: Array<{ endpoint: string; p256dh: string; auth: string; badge?: number }> =
    aud.subscriptions ?? [];

  // Everything except the badge is the same for everybody; the badge is that
  // parent's own unread count, so the body is built per subscription.
  const bodyFor = (badge?: number) => JSON.stringify({
    title: trim(aud.school, 60) || "PayStamp",
    body: trim(aud.title, 120),
    url: "/app/",
    tag: "ann-" + id,
    badge: typeof badge === "number" ? badge : undefined,
  });

  let sent = 0, gone = 0, failed = 0;

  // Sequential on purpose. A school has tens of parents, not thousands, and a
  // burst of parallel requests to the same push service is how you get rate
  // limited for the whole project.
  for (const s of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        bodyFor(s.badge),
        { TTL: 86400 },
      );
      sent++;
    } catch (e: any) {
      const code = e?.statusCode;
      if (code === 404 || code === 410) {
        // That browser is gone for good -- uninstalled, or notifications
        // turned off at the OS. Sending again is a wasted request forever.
        gone++;
        try { await rpc("push_mark_gone", { p_endpoint: s.endpoint }); } catch { /* next time */ }
      } else {
        // One parent's push service being down must not stop the rest.
        failed++;
        console.error("push failed", code, e?.body ?? e?.message);
      }
    }
  }

  console.log(`announcement ${id}: sent=${sent} gone=${gone} failed=${failed}`);
  return new Response(JSON.stringify({ sent, gone, failed }), {
    status: 200, headers: { "Content-Type": "application/json" } });
});
