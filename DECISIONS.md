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

---

## Tap to Pay computes the payment in the database, not in the browser

The parent's phone is what calls the confirmation functions, and a parent has
no write access to `public.cards` — row-level security keeps that table to the
owning school, which is the wall between one business and another.

So `stamp_confirm` takes an amount and works out what it covers itself. It has
no parameter that could carry a payments object. Had it accepted one, a single
tap would have let a parent post a whole year as paid and the physical tag
would have been protecting nothing.

The cost is a second copy of `calcBreakdown`, in PL/pgSQL, which has to agree
with the JavaScript one. `supabase/test/test-stamp-confirm.sql` pins the
arithmetic so the two cannot drift apart unnoticed.

**What changes it:** nothing short of parents getting write access to cards,
which is not going to happen.

---

## The amount is the parent's to type, and no tag can fix that

A parent could enter more than they are handing over. It is the one thing the
design cannot prevent, because a sticker cannot see cash.

Three things were done instead of pretending otherwise. Every triggered payment
is labelled in the student's history, so it is visible rather than silent. Undo
is offered for ten minutes. And `require_pin_on_confirm` exists for any school
that wants confirmations to be impossible without the owner standing there —
off by default, because most will not want the friction.

**What changes it:** a school actually being defrauded this way, which would
argue for the PIN becoming the default rather than for new machinery.

---

## /stamp/TOKEN works by way of the 404 page

GitHub Pages serves files, not routes, and there is no file at `/stamp/TOKEN`.
The nicer address survives because `404.html` rewrites it to `/stamp/?t=TOKEN`,
and Netlify reaches the same place through `_redirects`.

This is exactly the sort of arrangement that breaks quietly during some
unrelated change, so `app/test/routes.js` drives both paths in a browser and
also checks that an ordinary wrong address still gets a plain 404 rather than a
blank React screen.

**What changes it:** moving off Pages to something with real routing.

---

## The QR encoder is carried, not fetched

The first version loaded `qrcode@1.5.3/build/qrcode.min.js` from a CDN. That
path does not exist -- the package ships no `build/` directory at all, only a
CommonJS `lib/browser.js` -- so it 404'd and the screen showed its fallback on
the first real phone that opened it. The URL had been written from memory
rather than checked.

Replacing it with a different CDN URL would have been the same bet again, so
the encoder (byte mode, EC level M, versions 1-10, about 250 lines) now lives
in `app/index.html`. Three things follow from that and all of them are wanted:
the screen needs no network beyond the app, the school's token is never sent
anywhere to be drawn, and the code can actually be tested here.

Testing it mattered more than expected. Two bugs turned up that were invisible
in the rendered picture -- the format-info second copy written one cell too far
so bit 7 landed on the dark module, and the format bits written LSB-first when
placement wants MSB-first. In both cases the payload was byte-perfect and the
code simply would not scan, because a decoder gives up before it reaches the
data if it cannot read the format. `app/test/qr.js` pins both by decoding every
version with a real decoder and diffing against a reference encoder.

**What changes it:** needing a bigger version than 10, or a different EC level.
Both are table additions, not a rewrite.

---

## The stamp is matched in the database, not in the browser

The page could have compared the pressed pattern against a geometry it had
downloaded, and told the server which school matched. That would have been
simpler and completely hollow: a parent could then open a confirmation from
their sofa by posting a business id, and the physical stamp would be protecting
nothing. It is the same trap as letting `stamp_confirm` accept a payments blob.

So the browser sends raw points and learns only whether something matched. The
comparison runs in `stamp_begin_geometry`, against geometries belonging to
schools that caller is already a customer of — comparing against all of them
would turn the endpoint into an oracle for reading other schools' patterns.

`stamp_open_session` was extracted from `stamp_begin` for this rather than
copied, so the tag, the QR and the stamp all open the same session the same
way. It is granted to nobody: it takes a business id and opens a session
against it with no checks of its own.

**What changes it:** nothing. Client-side matching is not a cheaper version of
this, it is a different and empty feature.

---

## The stamp is the weakest trigger, and that is inherent

A tag address is 24 random characters. A stamp is five dots on a physical
object, visible to anyone who looks at it and reproducible with five fingers.
No amount of care in the matching changes that.

It ships behind a per-device flag, off by default, for that reason as much as
for testing. `require_pin_on_confirm` is the answer for any school that wants
the guarantee.

Two limits were left in deliberately rather than papered over: rotation is not
handled, and the pattern is measured in screen pixels so a calibration learned
on the owner's phone may not match on a very differently sized one. Both are
recorded at the foot of `migration-stamp-geometry.sql` as the first things to
check when a press does not register, because the symptom of every failure is
the same silence.

**What changes it:** real-device testing showing which of the two actually
bites. Rotation invariance and scale invariance are both solvable, but solving
either before knowing it is the problem is guesswork.

---

## The stamp matches at any angle, and the price was measuring the false-match rate

Real-device testing found the stamp only matched when pressed at the angle it
was calibrated at. Nobody presses a stamp that carefully and a competitor's
does not ask them to, so that was not a limitation to document — it was the
feature missing.

The matcher now solves for a similarity transform (translation, rotation, and
bounded scale) from every pair of points that could correspond. Allowing scale
was the same fix, not scope creep: the pattern is in screen pixels, learned on
the owner's phone and matched on a parent's, so the second recorded limitation
went with the first.

Making a matcher more willing to say yes is exactly where false positives come
from, so the numbers were measured rather than argued about. Genuine presses of
a realistic 200px stamp: 100% up to ±6px of noise. Twenty thousand random
four-finger presses: none matched. A *different* five-pad stamp did match at
16.6 against an 18px tolerance — which is what forced tolerance to become
relative to the pattern's own size, since 18px on a small pattern is nearly a
third of it. A near-straight line of contacts is refused outright, because
under free rotation and scale one line fits any other and a hand resting on a
phone is a line.

**What changes it:** a school reporting misses. The per-school tolerance is the
dial, and the collinearity floor is the thing not to loosen.

---

## The student portal needed a second identity, not a fix

The trigger did nothing in the student portal, and that was never a bug: that
portal has no login. It opens on a share code and a PIN, checked anonymously,
so there is no `auth.email()` and no `card_links` row for the family path to
stand on. It could not have worked as written.

So there is a second way in, deliberately narrower. The session binds to the
one card already on screen rather than to a person, so it cannot reach another
student even at the same school. The code and PIN are re-checked in the
database under the same rate limit the portal's own login uses, rather than
trusted because the page says it checked them.

The stamp is still what authorises the payment, exactly as in the family
portal. The code and PIN identify the card and nothing more — the portal needed
them to display it in the first place. Verified rather than asserted: with the
right code and PIN and no stamp, or the wrong stamp, or random fingers, the
answer is `no_match` and the card is untouched.

An earlier draft of the documentation described this as the PIN gaining the
power to record a payment. That reading was wrong and alarming, and it was the
wording rather than the behaviour: a share code and PIN alone have exactly the
access they always had.

**What changes it:** a school wanting the student portal to stay read-only,
which would be a per-business switch rather than a redesign.
