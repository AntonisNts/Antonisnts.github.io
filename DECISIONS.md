# Decisions

Things already settled, and why. Not a to-do list — a to-do list goes out of
date within weeks, and a document you cannot trust is worse than none.

Each entry says what was decided, the reasoning, and what would change it.
If you are about to re-open one of these, read the reasoning first: it is
probably still true.

Last reviewed 16 September 2026.

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

## Accepting the Terms is the signature — there is no separate contract to post

A school does not sign anything. The Terms of Service incorporate the Data
Processing Agreement, and Article 28(9) accepts a contract "in writing,
including in electronic form" — so clicking through at signup forms the same
contract a printed one would. What was missing was not a signature but the
*showing*: the two screens where a business is actually created carried no
agreement line at all, and the DPA was never named at the point of acceptance.
Both now state it and link all three documents.

A signed PDF is still offered on request, because an accountant sometimes wants
one in a folder. That is a courtesy, not a legal requirement, and the Terms now
say so.

**What changes it:** a customer whose own compliance policy demands a
countersigned agreement before they will start — sign the PDF, don't rebuild the
mechanism.

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

---

## The stamp switches itself on when a school calibrates

It shipped behind a per-device flag: a phone only listened after being opened
once with `?stamptrigger=1`. That was the right thing to build it behind and
the wrong thing to run it on. A parent at the desk has their own phone, that
phone has never seen the flag, and nobody pastes a URL with a queue behind
them — the feature would have worked only for the person who built it.

So the default is now a question rather than a flag. The app asks once, when it
loads, whether any school this person deals with has a stamp registered, and
only then attaches a listener. Calibrating is the switch; removing the
calibration is the off switch. Cached for the life of the page, because the
listener runs on every touch and the question must not.

Two functions rather than one, because the portals prove identity differently —
an account in the family portal, a share code and PIN in Quick View. Both
return a single boolean and never the pattern.

The flag survives as a manual override (`?stamptrigger=0` to silence a device,
`?stamptrigger=1` to force it on before calibrating), which costs nothing and
is occasionally what you want.

**What changes it:** a school wanting the stamp off while keeping its
calibration, which would be a switch on the calibration screen rather than a
change to how the question is asked.

---

## A pending claim is not a payment, and that is enforced by where it lives

The whole online-payment flow turns on one property: a parent saying they have
paid must not move a balance. Not the card, not the school's totals, not any
overdue figure.

It holds because claims live in their own table and nothing in that path writes
to `cards.payments`. The only thing that moves money is the school confirming,
and that calls `stamp_apply_payment` — the same writer the tag, the QR and the
stamp use, not a copy. A link payment therefore lands on a card identically to
every other kind, with the same breakdown, history entry and undo snapshot.

That is a property of the system rather than of any one function, so the test
asserts it by photographing the card and the school's owed total before and
after raising a claim and comparing them, rather than by reading the code and
believing it. The browser suite does the same for what the parent is shown,
because "Awaiting confirmation" read as "done" would be the failure that
matters most and it is a wording failure, not a code one.

**What changes it:** a card processor confirming automatically, which would
skip the queue but still go through the same writer.

---

## The payment URL is a CHECK constraint, not validation in a function

Who may set it is RLS, which was already there. What may be set is a database
constraint: `https://` only, no `javascript:`, no `data:`, no plain http.

Put in a function, that rule would hold only for callers who went through the
function — and the app writes this column directly, because RLS plus a
column-level grant already says who may. A constraint holds on every path,
including a hand-written UPDATE in the SQL editor.

It matters more than it looks: this link is shown to parents and leads to a
page where they type card details.

**What changes it:** nothing. Validation that can be bypassed is decoration.

---

## The test rig counts a NULL verdict as a failure

Every SQL suite reports a `pass` column of `t` or `f`. A verdict that comes
back NULL — because the expression referenced something an earlier statement
failed to create — is neither, and the counter ignored it. Such an assertion
does not pass and does not fail; it is simply absent, and the totals look
merely smaller rather than wrong.

That hid a broken fixture through most of one suite, and it had been hiding a
real product bug for longer: `stamp_begin_geometry`'s "this is the school's own
device" branch sat inside a loop over the caller's linked children, and an
owner has none, so it never ran. An owner pressing their own stamp got silence.
The assertion covering it had been returning NULL, invisibly, since it was
written.

`run-tests.sh` now counts NULL verdicts as failures and prints any SQL errors
from the run.

**What changes it:** nothing. This is the third time in this project that a
test which could not fail was mistaken for one that passed.

---

## The shop's switch is a row in its own table, not a column on `businesses`

A `shop_enabled` column would have been simpler to write and impossible to take
back out: dropping it later means an `ALTER TABLE` on the table everything else
in the product depends on, and until then every school carries a column for a
feature most of them will never turn on.

The switch lives in `shop_settings`, one row per school, absent by default.
Absent means off, so a school that never touches the shop has no row, no
column, and nothing to clean up.

The same reasoning kept a parent's "I've paid" for kit off the `payment_claims`
table. Reusing it would have been less code and would have meant editing
`payment_claim_confirm` — a function on the fee path, which is the one path the
shop was asked not to disturb. The claim lives on the order instead.

**What changes it:** the shop ceasing to be optional. If every school has it on,
the argument for keeping it detachable is gone.

---

## Kit debt and fee debt are different numbers and are never added up

"Who owes me for September" is a question about lessons. A school that also
sells jumpers still wants that answer to mean what it always meant, and a
parent looking at a red month wants to know it is about lessons.

So shop orders touch no month, no fee total and no breakdown. What is owed for
kit is its own figure on its own screen and says so on its face: *Owed For Kit
— separate from lesson fees*.

The temptation was one "total owed" per family. It reads well and it is wrong:
it merges a recurring obligation with a one-off purchase, and the two are
chased differently, forgiven differently and argued about differently.

**What changes it:** a school asking for a combined figure. Even then it should
be a third number shown beside the two, not a replacement for either.

---

## One function settles an order, and it is granted to nobody

`shop_order_mark_paid` is the only thing in the module that can turn an order
paid. The owner ticking it off, a confirmed payment-link claim and — later — a
card processor all call it; none of them re-implements what being paid means.

It authorises nothing. It is handed an order whose caller has already
established the right to settle it, which is why no role can execute it. Each
entry point does its own proving, exactly as `stamp_apply_payment` does on the
fee side.

This is the same shape as the fee path for the same reason: when four triggers
each had their own idea of what a payment was, they disagreed. Adding Stripe
later is verifying a webhook, finding the order, and calling this with
`p_via = 'stripe'`.

**What changes it:** nothing. A second writer is how the two ledgers start
disagreeing about the same order.

---

## The shop's removability is tested by removing it

The module carries instructions for deleting itself. Instructions in a comment
rot quietly: a mount added six months later without its marker leaves the
instructions describing a removal that no longer works, and nobody finds out
until somebody tries it.

`app/test/shop.js` performs the documented removal on a copy of
`app/index.html` — cut the block, drop every line marked `SHOP MODULE mount` —
and boots the result in a browser. A dangling reference is a blank screen for
every school, not only the ones that switched the shop on.

Writing that test is what found the first version's real problem. The badge
count lived in `App` as state and was passed down to the dashboard, so removing
the module left `shopPending={shopPending}` pointing at a variable that was no
longer declared: a `ReferenceError` on load, for everybody. The count moved
into the module as a hook the settings row calls on the line it draws.

**What changes it:** nothing.

---

## The family portal is a list of names, not one long scroll

It used to concatenate. The amount due, then the pay-online panel, then the
shop, then every child with their card and their school's notes unfolding
underneath. Every feature I added put another band on the front page, and each
one was defensible on its own.

The shop is what made it undeniable. The catalogue comes back per card, so two
siblings at one school listed the same jumper twice — above the children
themselves. School announcements had the same flaw and nobody had noticed:
a note to the whole school appeared once per sibling.

Tapping a name now opens that child. Their card, where to pay, their notes,
their shop.

The part worth keeping in mind: this did not deduplicate anything. Showing one
child at a time makes the duplication **impossible**, because two children are
never on screen together. A deduplication pass would have been code that has to
keep being right; this is a shape in which the question does not arise. It is
also where the next feature goes — on a child's page, not on the front.

Two things fell out of it. The combined "Due now" block now appears only when
more than one card owes: with one owing card it was the row underneath it said
twice, and the reason it used to show — that it was the only way to see what
the €85 was made of — stopped being true once the card was one tap away. And
the pay-online small print moved next to the thing it explains.

**What changes it:** a parent with one child finding the extra tap annoying. If
so, open straight onto their page and keep the list for families with two or
more.

---

## A page is remembered by what it is, not by what was on it

The child's page holds `{kind, key, title}` — "the page for child k1" — and
rebuilds its rows from the current data on every render.

The obvious alternative is to store the rows when the page opens. It is also
wrong: unlinking a card, or moving one to a different child, changes what
belongs on that page, and a snapshot would keep showing what was true when it
was opened. The bug that follows is a parent unlinking a card and still seeing
it until they navigate away — and if they act on what they see, acting on
something that no longer exists.

**What changes it:** nothing. Derive, don't snapshot.

---

## The notifications service worker caches nothing, and must not start

A service worker exists in PayStamp for exactly one reason: a browser will not
deliver a push notification without one. It has no `fetch` handler.

The temptation is obvious — a service worker is *right there*, and making the
app work offline looks like a free win. It is not. PayStamp is a single HTML
file deployed by overwriting it. A worker that cached the app would keep
serving whichever version it had cached, so a school could be looking at last
week's app while the database had moved on: no error, no clue, and nothing they
could do about it. Every support call would start with "try clearing your
browser data", which is not a sentence to say to a customer.

`app/test/push.js` asserts that the set of handlers is exactly install,
activate, push and notificationclick, so adding a fetch handler fails a test
rather than shipping.

**What changes it:** a genuine need to work offline, which would then be
designed deliberately with a version check — not acquired by accident.

---

## Notifications are asked for, never asked about

No permission prompt appears on its own. There is a panel with a button, and
the browser is asked only after somebody presses it.

A prompt that appears unasked is the one people dismiss without reading, and a
dismissal is not neutral: once a browser records "denied", we cannot ask again.
Only the parent can undo it, in settings, which means the cost of asking at the
wrong moment is that parent never being reachable again.

Two consequences worth keeping. An iPhone in a Safari tab has no push machinery
at all — not a refused permission, no API — so the panel tells them to add
PayStamp to the Home Screen rather than offering a button that cannot work. And
a browser with genuinely no push says nothing at all, because explaining a
limitation somebody cannot act on is noise on a screen whose whole point is
being quiet.

**What changes it:** nothing. The one-shot nature of "denied" is not something
better copy can recover from.

---

## A subscription we failed to record is undone

Turning notifications on is two steps: the browser subscribes, then we store
what it gave us. If the second fails, the first is rolled back.

Otherwise the browser holds a live subscription, the panel reads it and says
"on", and nothing is ever sent to it — because the sender works from our table,
which never got the row. A parent who has been told they will be notified, and
will not be, is worse off than one who was told it did not work.

**What changes it:** nothing. Any state the app reports must be the state the
sender acts on.

---

## A tab that opens on nothing is worse than no tab

Both portals are tabbed now — Card, School, Shop, History — and a tab is drawn
only when there is something behind it. A school that posts no notes has no
School tab; a school that sells nothing has no Shop tab; a card with no
payments has no History tab. With one tab left the bar disappears and the card
is simply the page.

The alternative is a fixed strip with empty states behind the dead ones, which
looks tidier in a mockup and is worse to use: every tab is a promise, and the
only way to find out which ones are empty is to tap them all.

The cost is that the strip is not the same shape for every family, so nobody
can learn a fixed position. That is the right trade at this size — four tabs at
most, all labelled.

**What changes it:** enough tabs that their position matters more than their
emptiness.

---

## Photographs are shown whole

`object-fit: cover` fills its box by cropping. For a uniform photographed head
to toe that means cutting off the head and the feet — the two ends that say
what it is. The first version of shop photos did exactly that, and the first
real photograph uploaded showed the problem immediately.

Everything a parent looks at uses `contain`, and any picture opens full-screen
on a tap. The one exception is the 56px square on the owner's own item list,
which is an identifier rather than the picture; it crops, and it opens.

**What changes it:** nothing. A photograph exists to be looked at.

---

## The badge is counted in the database, not in the browser

An app icon's number is easy to get wrong in a way nobody notices for weeks.
The obvious implementation is to increment a counter in the service worker on
every push and clear it when the app opens. It is also wrong the moment a
parent reads something on another device, or opens a note without a push
having arrived, and the failure is silent: the icon says 3, the app says
nothing is unread, and the parent stops believing the badge.

So the number is that parent's unread count, computed from the same two tables
the portal reads, and carried per subscription in the push payload. The service
worker sets what it is told; the portal re-sets it on every render. Two writers,
one definition.

The cost is that the sender does a count per recipient. At the size of a school
that is nothing, and it buys a badge that cannot disagree with the app.

**What changes it:** enough recipients that the per-person count matters, which
would mean batching by unread count rather than guessing in the browser.

---

## The student portal gets the same features, through its own door

A student opens their card with a share code and a PIN. There is no session, so
`auth.email()` is null and every `_mine` function correctly returns nothing.

The temptation each time is to loosen the parent's function so it accepts a
code as well. That would put two different ideas of identity inside one
function, and the weaker one would decide. Instead the logic is split: an inner
writer that authorises nothing, and two doorways that each prove who is calling
in their own way — `payment_claim_open` first, and now `shop_order_open`.

The student doorways are granted to `anon`, which is correct and looks alarming
until you notice each one calls `stamp_student_card` first: rate limited, and
checking the PIN itself rather than trusting the page.

**What changes it:** nothing. One function, one notion of who is calling.

---

## Students get the notification but not the number

A student subscription carries no badge count, and the icon stays bare for them
even though the banner arrives.

The count has to be that person's unread total — that is the whole reason it is
computed in the database rather than guessed in the browser. But the student
portal records what has been read in `localStorage`, on the device: the server
has never been told. Any number it sent would be the count of announcements
that exist, not the count they have not seen, and it would never go down.

A badge that only ever goes up is worse than no badge. So the payload omits it,
and the service worker leaves the icon alone when it is missing — which was
already the behaviour for a payload from an older sender.

**What changes it:** recording "seen" server-side for students, which would also
make their read state follow them between devices. Worth doing, not worth
bundling into this.

---

## One subscription, one owner, enforced by the database

`push_subscriptions` can belong to a parent (by email) or to a student (by
card), and a check constraint says exactly one, never both and never neither.

The constraint is not decoration. Writing it immediately failed the test that
moves a phone from a student's card back to a parent's account: the parent's
`push_subscribe` set the email on conflict and left the card id behind. Without
the constraint that row would have matched both halves of the audience query
and that phone would have been sent every announcement twice — which is the
kind of bug nobody reports, they just turn notifications off.

**What changes it:** nothing. A row no query can find, or that two queries both
find, is worth refusing at write time.

---

## A school owner's subscription is an ordinary one

`push_subscriptions.parent_email` holds a school owner's email as readily as a
parent's. Adding a `business_id` column for owners would have been the tidier
-looking choice and it would have been wrong: an owner IS a signed-in account
with an email, so the row already exists in the right shape. What differs is
who asks for it, and that is a query, not a column.

The column's NAME is now slightly misleading — it means "the account this
browser belongs to", not "a parent". Renaming it in a live database is
cosmetics with downtime attached, so it is a comment instead.

This is the second time the shape held: students needed a card, which genuinely
was a new kind of owner and got a column. Owners did not.

**What changes it:** nothing. A column per role would mean an audience query
per role, and three ways for one endpoint to be found twice.

---

## Nothing notifies a school about work it did itself

A school hears about three things: a sign-up, a shop order, and a parent
claiming they paid. All three arrive from outside and wait for a decision.

Deliberately excluded: payments the school records itself, stamps, taps, QR
confirmations. Those are things they just did — a phone buzzing to tell you
about the button you pressed a second ago is the notification that makes
somebody switch all of them off, and that is not recoverable. We cannot ask
again once a browser records "denied".

The screen lists exactly what will arrive and exactly what will not, because
the promise is the thing being agreed to.

**What changes it:** a school asking to be told about something specific. Added
one at a time, never as a category.

---

## Leaving PayStamp to pay is written down before you go

Tapping a school's payment link leaves the app. On an iPhone, returning to a
Home Screen web app RELOADS it — every piece of React state is gone. The parent
who had opened their child's page, tapped Pay Online and paid came back to the
list of names, with nothing offering to record what they had just done. Which is
the entire point of the round trip.

So the intent — which card, and when — goes into `localStorage` before the link
opens, and is read on the way in. `localStorage` rather than `sessionStorage`
because a reload is the *good* case; iOS may discard the app altogether.

Two details that are not obvious until it is wrong:

**It expires.** After two hours "I am about to pay" stops being true, and a
stale flag would drag a parent into some child's page days later for no reason.

**Two readers, two lifetimes.** The portal uses it once, to reopen the page that
was left; the pay panel needs it to survive until the parent has actually said
something. The first version had the portal clear it, which meant the panel
found nothing and "I've paid" never appeared — the bug fixed, then reintroduced
three lines later. The portal marks it *landed* instead.

**What changes it:** a browser that reliably restores state on return. Not worth
detecting; the flag costs nothing when the app did not reload.
