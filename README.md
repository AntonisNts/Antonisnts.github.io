# StampCard

A mobile-first payment / "stamp card" tracker for small academies and tutors
(swimming, karate, languages, music, dance, and more). Teachers manage student
cards and monthly payments; students view their own card with a code + PIN.

Now backed by **Supabase** — a shared cloud database with secure, multi-tenant
authentication, so it works for real public/business use across devices.

## Features

- **Teacher portal** — register a business and log in with email + password
  (handled by Supabase Auth; passwords are hashed, never stored by us).
- **Student cards** — each student gets a shareable code and a 4-digit PIN to
  view their own card. PINs are bcrypt-hashed in the database.
- **Smart payments** — enter one amount and it's auto-distributed across unpaid
  months, with a live breakdown and confirm step.
- **Levels** — define tiers (e.g. Beginner / Intermediate) each with its own fee.
- **Inactive months** — skip summer/holiday months so they don't count as owed.
- **Custom card art** — upload a background image (stored in Supabase Storage).
- **Export** — summary / detailed / CSV reports, shareable by email or WhatsApp.
- **Reminders** — filter students with outstanding balances and send templated
  reminders via WhatsApp, SMS, or email.
- **Password recovery** — Supabase Auth email-based password reset.

## Architecture

- **Frontend:** a single static `index.html` (React + Babel + Supabase loaded
  from CDN — no build step). Deploys to Vercel, Netlify, Cloudflare Pages, or
  GitHub Pages.
- **Backend:** Supabase (Postgres + Auth + Storage). Schema and policies live in
  [`supabase/schema.sql`](supabase/schema.sql).
- **Security:** Row-Level Security isolates each business's data at the database
  level; students reach only their own card through a locked-down function.

The Supabase **Project URL** and **anon/publishable key** are embedded in
`index.html`. That's expected and safe — those are public client keys, protected
by Row-Level Security. The secret `service_role` key is never used here.

## Setup (first time)

Follow [`supabase/SETUP.md`](supabase/SETUP.md) to create the Supabase project,
run the schema, and create the `card-images` storage bucket.

## Running locally

```bash
python3 -m http.server 8000
# then visit http://localhost:8000
```

(An internet connection is required — React, Babel, and Supabase load from a CDN
and the JSX compiles in the browser.)

## Deploying to Vercel

1. Push this repo to GitHub (already done).
2. In Vercel, **Add New → Project**, import this repository.
3. Framework preset: **Other**. No build command, output is the repo root.
4. **Deploy.** Vercel serves `index.html` directly.
5. (Optional) add your custom domain in the Vercel dashboard, then set that URL
   as the **Site URL** in Supabase → Authentication → URL Configuration so
   confirmation / reset links point to it.

## Notes & limitations

- **4-digit student PINs** are a convenience lock, not strong security. A planned
  hardening step is rate-limiting failed attempts.
- **GDPR:** you'll be storing real names and payment records, so in the EU/Cyprus
  you're a data controller — add a short privacy policy and collect only what you
  need.
- One teacher account currently maps to one business.
