# Where we are

Last updated 13 September 2026. Plain language on purpose — this is the list to
pick up from, not a spec.

---

## Waiting on one trigger: your first paying school

Nothing here needs doing while the only data in the system is your own test
data. All three become real the day someone else's records are in there.

- **Turn on Supabase backups.** The Free plan has *none*. Pro is ~$25/month and
  keeps a rolling 7 days. Until then, the manual export in the admin cheat
  sheet is the stopgap.
- **Split the database.** Staging and production share one Supabase project, so
  a migration is live for everyone the moment it is pasted. Fine while the data
  is disposable; the local replica in `supabase/test/` already rehearses
  migration SQL, which is most of what a second project would buy.
- **Review the student limits you set.** Every school that existed before the
  limit shipped is on `unlimited`. New signups start on `starter` (25).

---

## Waiting on someone else

- **Snowshoe** — physical stamp for recording payments. Waiting on their reply,
  including per-verification pricing. Needs a server either way.
- **A backend (one Edge Function).** With Snowshoe parked this only buys two
  things: an alert when a school signs up, and one when a student registers.
  That is a lot of new infrastructure for two notifications, so it is parked
  until Snowshoe answers or signups get frequent enough to hurt.

---

## Yours, whenever

- **Secure password change** — one toggle in Supabase (Authentication → Sign In
  / Providers → Email). With it off, anyone using a logged-in session can change
  the password, however old that session is. With it on, a session older than 24
  hours has to log in again first.
- **The security audit page** — it is now out of date and says things that are
  no longer true. Decide: refresh it, or delete it.
- **Instagram account** — handle, bio, profile picture. Parked.
- **The Greek ad** — waiting on your ElevenLabs audio. App screenshots are
  already captured.

---

## Mine, whenever you want them

- **Rewrite three campaign posts** — they are written for you on camera and you
  chose an AI presenter.
- Nothing else outstanding. The dashboard type-scale item was dropped: looked at
  it against the live app and could not find a real problem.

---

## Done

Registration spam limit · student limit per plan · family data export · school
rename · home-screen app icon · every screen on the shared skin · legal pages
without a CDN dependency · capacity-only pricing · the audited feature list ·
teachers/groups SQL recovered into the repo · browser test harness committed ·
SQL replica rig fixed (was loading 16 of 25 migrations).

Two audit findings were withdrawn after testing proved them wrong: the seven
"unprotected" functions were already protected, and the three "undiagnosed test
failures" were a dirty test database, not bugs.

---

## How to run things

- **Admin SQL** (approve a school, set a plan, back up) — see the admin cheat
  sheet PDF, or `supabase/migration-*.sql` for the record of what is live.
- **Database tests** — `supabase/test/run-tests.sh`. Rebuilds a full replica
  before every suite. Run this before pasting any migration into Supabase.
- **Browser tests** — `app/test/` — `npm install && node sweep.js`.

Merging a pull request never applies SQL. Migrations only take effect when
pasted into the Supabase SQL editor.
