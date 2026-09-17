# Notifications

Until this existed, a parent found out about an announcement by deciding to go
and look. Viber told them; PayStamp waited to be opened.

Now, when a school posts an announcement, every parent who has switched
notifications on gets one on their phone.

**Announcements only.** Nothing else in PayStamp sends a notification — not a
payment, not a shop order, not a reminder. That is deliberate: the first
notification a parent receives that they did not want is the one that makes
them turn all of them off.

---

## Setting it up

Five steps, once. Until they are all done nothing sends and nothing breaks —
the switch simply never appears to work.

### 1. Run the migration

`supabase/migration-push.sql` in the SQL editor. It adds one table and five
functions, all prefixed `push_`, and alters nothing.

### 2. Keep the VAPID keys

A VAPID keypair is how a push service knows a notification really came from
PayStamp. The **public** key is already in `app/index.html` — it is public by
design. The **private** key is not in this repository and must never be: it is
the thing that proves a push is yours.

If you ever need a new pair, any machine with Node can make one:

```bash
node -e '
const c=require("crypto");
const {publicKey,privateKey}=c.generateKeyPairSync("ec",{namedCurve:"prime256v1"});
const b=x=>x.toString("base64").replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
console.log("PUBLIC ",b(publicKey.export({type:"spki",format:"der"}).subarray(-65)));
console.log("PRIVATE",b(privateKey.export({type:"pkcs8",format:"der"}).subarray(36,68)));'
```

Changing the pair invalidates every existing subscription — every parent would
have to turn notifications on again — so do it only if the private key leaks.

### 3. Set the secrets

Supabase dashboard → **Project Settings → Edge Functions → Secrets**:

| name | value |
|---|---|
| `VAPID_PUBLIC_KEY` | the public key, same one as in `app/index.html` |
| `VAPID_PRIVATE_KEY` | the private key — only ever here |
| `VAPID_SUBJECT` | `mailto:` and your email; push services want a contact |
| `PUSH_HOOK_SECRET` | any long random string you invent |

### 4. Deploy the function

```bash
supabase functions deploy push-announcement --no-verify-jwt
```

`--no-verify-jwt` because the caller is a database webhook, not a signed-in
person. The function authenticates its caller itself, on `PUSH_HOOK_SECRET`.
**Without that check the URL would be a way for anyone to make every parent's
phone buzz**, which is why it refuses to run if the secret is unset.

### 5. Point the webhook at it

Dashboard → **Database → Webhooks → Create a new hook**:

- Table: `announcements`
- Events: **Insert** only
- Type: **HTTP Request**, method **POST**
- URL: your function's URL
- HTTP header: `x-push-secret` = the same `PUSH_HOOK_SECRET`

Insert only. A webhook on update would re-notify everyone every time a school
fixed a typo.

---

## What a parent does

A panel appears in the family portal: **🔔 Get told about announcements**. It
sits there until it has been dealt with, then removes itself. It is also
permanently in **Account → Notifications**.

Nothing is ever asked automatically. A permission prompt that appears unasked
is the one people dismiss forever, and a refusal cannot be undone by us — only
by the parent, in their own phone settings. So there is a button, and the
browser is asked only after it has been pressed on purpose.

### iPhone

**On an iPhone this only works once PayStamp is on the Home Screen.** In a
Safari tab there is no push machinery at all — not a refused permission, no
API — so the panel tells an iPhone user to install it rather than offering a
button that cannot work.

Share → Add to Home Screen → open it from there → then turn notifications on.

Android works in an ordinary tab.

---

## The number on the app icon

A banner and a badge are two different things: `showNotification()` puts the
banner on the lock screen, `navigator.setAppBadge()` puts the number on the
icon. The first version did only the first, which is why notifications arrived
and the icon stayed bare.

The number is **that parent's unread announcement count**, not how many pushes
were sent. A badge that disagrees with what is inside the app is worse than no
badge, so it is counted in the database from the same two tables the portal
reads, and carried per subscription in the push payload.

Two things keep it honest:

- the **service worker** sets it when a push lands, to the count the sender
  worked out;
- the **portal** sets it on every render, so opening a note clears the badge
  immediately, and reading something on another device corrects it here.

Both write the same number from the same definition of unread. Counting in the
browser instead would drift the moment a parent read something elsewhere.

It needs `supabase/migration-push-badge.sql`. Without it the payload carries no
count and the worker leaves the badge alone — notifications still arrive.

## What a notification says

The school's name as the title, the announcement's headline as the body. That
is all.

A notification is read on a lock screen, possibly by whoever picks the phone
up. The body of the announcement stays behind the app.

Tapping it opens PayStamp — focusing the window if it is already open rather
than opening a second copy.

---

## The service worker

`app/sw.js` exists for one reason: a browser will not deliver a push without
one. **It has no `fetch` handler and must never get one.**

PayStamp is a single HTML file deployed by overwriting it. A service worker
that cached the app would keep serving whichever version it had cached — so a
school could be looking at last week's app while the database had moved on,
with no way to tell and nothing they could do about it. That failure is silent,
hard to explain over the phone, and would be caused entirely by code added for
notifications.

`app/test/push.js` asserts the absence of a fetch handler, so nobody can add
one by accident.

---

## When a phone stops ringing

Push services answer 404 or 410 for a subscription that is gone for good — the
app deleted, notifications turned off at the OS level. The sender marks those
`gone_at` rather than deleting the row, so "why did this phone stop getting
them" has an answer. Turning notifications on again revives the same row.

Everything else — a service being briefly down — is logged and left alone.

---

## Who gets what

The audience rules are the announcement's own, read from the database rather
than re-derived:

| the announcement has | it reaches |
|---|---|
| a `card_id` | that one student's parents |
| a `group_id` | the parents of that class |
| neither | every parent at that school |

A parent with a phone and a laptop has two subscriptions and both ring. An
endpoint belongs to whoever subscribed it last, so a second-hand phone stops
ringing for its previous owner.

An endpoint is a capability to make somebody's phone buzz, so nothing is
readable by ordinary users: the table is reachable by nobody, and `push_audience`
is granted only to the service role.

---

## Removing it

Drop statements are at the foot of `supabase/migration-push.sql`. Then delete
the Edge Function and the webhook. Nothing outside those objects was changed.

---

## Files

| file | what it is |
|---|---|
| `supabase/migration-push.sql` | one table, five functions, its own removal instructions |
| `supabase/migration-push-badge.sql` | the unread count that becomes the icon's number |
| `supabase/functions/push-announcement/index.ts` | the sender |
| `app/sw.js` | the service worker — push only, no caching |
| `app/index.html` | `PushSwitch`, and the VAPID public key |
| `supabase/test/test-push.sql` | 51 assertions |
| `app/test/push.js` | 58 assertions |
