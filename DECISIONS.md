# Decisions

Things already settled, and why. Not a to-do list — a to-do list goes out of
date within weeks, and a document you cannot trust is worse than none.

Each entry says what was decided, the reasoning, and what would change it.
If you are about to re-open one of these, read the reasoning first: it is
probably still true.

Last reviewed 13 September 2026.

---

## Backups wait for the first paying school

Supabase's Free plan includes **no automated backups**. Daily snapshots start on
Pro, roughly $25/month.

Deferred deliberately. Every record in the system today is the owner's own test
data — losing it would cost an afternoon of retyping, not a customer. A manual
export query is documented in the admin cheat sheet as the stopgap; it rebuilds
records rather than restoring a database, which is a real difference worth
knowing before relying on it.

**What changes it:** the first school whose students are not yours. From that
day, "we lost your payment records" is a sentence you would have to say to
somebody else.

---

## Staging and production share one database, on purpose

The *code* split already exists and works — Netlify serves `staging`, Pages
serves `main`, and nothing reaches production without passing through staging
first.

The *database* is not split, and that was raised as a problem. It was overstated.
All the data is the owner's own, in his own account, and row-level security means
a staging session cannot reach anything else. Deleting or editing test students
harms nobody.

What genuinely remains is narrower: a change that lives in the database is live
for everyone the moment the SQL is pasted, before the staging site has even been
opened. That is mitigated by the replica in `supabase/test/`, which rebuilds the
whole schema and runs the full suite before any migration reaches Supabase.

**What changes it:** the same trigger as backups. Once someone else's records are
in there, finding out in production starts costing something.

---

## Plans are set by hand, and the limit is enforced in the database

There is no billing system, so `businesses.plan` is set with one line of SQL at
the same moment a school is approved. Starter 25, Growth 80, Pro 200, Unlimited
uncapped.

Two things were deliberate. Schools that existed before the limit shipped are all
on `unlimited`, so nobody was capped retroactively; only signups after that point
start on `starter`. And owners cannot raise their own plan — the table's update
permission was reissued over named columns, and `plan` is not one of them.
Without that, an owner could have set their own plan with the public key and the
limit would have been decorative.

**What changes it:** a real billing system, which would set the plan instead.

---

## The backend is parked

An Edge Function would buy exactly two things right now: an alert when a school
signs up, and one when a student registers. Both are real gaps — a school can
sit in `pending` indefinitely without anyone being told — but that is a lot of
new infrastructure to run for two notifications.

**What changes it:** Snowshoe replying (their stamp needs a server to verify
against), or signups becoming frequent enough that missing one costs a customer.

---

## SMS login over Cyta was dropped

Proposed to remove an email confirmation step from registration. Registration
never had one — a parent fills in a name and the request is submitted. The only
email confirmation in the product is on the optional family-portal signup, which
most parents never touch.

Also rejected along the way: making the phone number double as the password. A
phone number is a public identifier, not a secret, and Cyprus mobiles are an
eight-digit space.

**What changes it:** a genuine reason for phone login that is not the
email-friction one, since that premise was false.

---

## Two audit findings were withdrawn after testing disproved them

Both were raised as problems, and both were wrong. Recorded here so they do not
come back.

**"Seven database functions are unprotected."** They were always protected.
`migration-security-hardening.sql` runs `alter default privileges … revoke
execute on functions from public` plus a blanket revoke — written once, covering
everything, one file away from where it was looked for. Confirmed on a replica:
`anon` holds no EXECUTE on any of the seven.

**"Three undiagnosed test failures."** Not bugs. The SQL suites share fixture ids
and none clean up after the others, so running them back to back in one database
made later ones fail on rows an earlier one left behind. A fresh replica per
suite: all green. `run-tests.sh` now rebuilds before every suite so it cannot
recur.

The lesson both share: reading code tells you what it looks like, running it
tells you what it does. Migrations go through `supabase/test/run-tests.sh` before
Supabase.

---

## The security audit page is a reference, not a sales document

It lives on a `claude.ai` URL, nobody independent signed it, and it carries more
detail than any school owner wants. What goes to a customer is
**paystamp.app/privacy** and **/dpa** — own domain, written for the reader, and
the DPA is the document a business actually signs.

The audit's use is narrower: looking up a specific answer with evidence behind it
when someone asks something precise, and having a dated record that the
assessment happened.

**What changes it:** wanting something customer-facing, which would be a short
security page on paystamp.app rather than a rewrite of the audit.
