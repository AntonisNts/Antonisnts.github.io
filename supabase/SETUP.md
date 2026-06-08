# StampCard → Supabase setup guide

This gets the secure, multi-tenant backend running. It takes ~15 minutes and
uses Supabase's free tier. **Do these steps; then we wire the app to it.**

---

## 1. Create a Supabase project
1. Go to <https://supabase.com> and sign up (free).
2. **New project** → give it a name (e.g. `stampcard`), set a strong database
   password (save it somewhere), pick the region closest to your users
   (e.g. *Frankfurt* / *London* for Cyprus/Greece).
3. Wait ~2 minutes for it to provision.

## 2. Create the schema
1. In the project, open **SQL Editor** → **New query**.
2. Open `supabase/schema.sql` from this repo, copy the whole file, paste it in.
3. Click **Run**. You should see "Success. No rows returned."
   - It's safe to run again later if you change it.

## 3. Create the card-images storage bucket
1. Go to **Storage** → **New bucket**.
2. Name it exactly `card-images`, toggle **Public bucket** ON, create it.
   - (The storage policies at the bottom of `schema.sql` already ran in step 2,
     so uploads/reads will work once the bucket exists.)

## 4. Configure authentication (teacher logins)
1. Go to **Authentication** → **Providers** → make sure **Email** is enabled.
2. Go to **Authentication** → **Sign In / Up** settings:
   - For real business use, keep **"Confirm email"** ON (verifies real emails).
   - For quick testing, you can temporarily turn it OFF so you can log in
     immediately after signup.
3. (Optional, recommended) Under **Authentication → URL Configuration**, set the
   **Site URL** to your future Vercel URL so password-reset / confirm links work.

## 5. Grab your keys (you'll give me these two)
Go to **Project Settings → API**:
- **Project URL** — looks like `https://xxxxxxxx.supabase.co`
- **anon public** key — a long JWT starting with `eyJ...`

These two are **safe to share and ship in the frontend** — they only allow what
Row-Level Security permits. ⚠️ **Never** share the **`service_role`** key — that
one bypasses security. Don't paste it here or anywhere public.

---

## What this gives you (and how it's secure)

| Concern | How it's handled |
|---|---|
| **Shared storage** | Postgres database in the cloud — every device sees the same data. |
| **Teacher passwords** | Stored & hashed by Supabase Auth (bcrypt). We never see or store them. |
| **Student PINs** | Stored as plain text on purpose — teacher-assigned, shareable 4-digit codes (not passwords). Verified by direct comparison. |
| **Tenant isolation** | Row-Level Security: the DB physically refuses to return another business's rows. |
| **Student access** | A locked-down function returns only the one card matching code + PIN. |

## Honest limitations (worth knowing before launch)
- **4-digit PINs are low-entropy and stored in plain text.** They are
  teacher-assigned, shareable codes — a convenience lock, not a password. A
  planned hardening step is rate-limiting failed attempts (doable in pure SQL,
  no Edge Function needed) — tell me if you want it.
- **Personal data + GDPR.** You'll be storing real names and payment records,
  so in the EU/Cyprus you're a data controller. You'll want a short privacy
  policy and to only collect what you need.
- **Email-based recovery** is now handled by Supabase Auth's built-in password
  reset, which is far safer than the old "reveal the code" flow.

---

## Next step (after you finish the above)
Reply with your **Project URL** and **anon public key**, and tell me you've run
the SQL + created the bucket. I'll then refactor the app's data layer to use
Supabase (auth, database reads/writes, student lookup, image upload) and set it
up to deploy on Vercel.
