# Tap to Pay — setting it up

A parent holds their phone against a sticker on your desk, or scans a code on
your screen, and the cash they just handed you is recorded. This is how to set
it up and what it does and does not protect against.

---

## Once, before you start

Paste `supabase/migration-stamp-confirm.sql` into the Supabase SQL editor and
run it. Nothing in the app changes until you do — the Tap to Pay screen will
say it cannot load your tag.

---

## Getting your tag address

**Settings → Payments → Tap to Pay.**

The address looks like:

```
https://paystamp.app/stamp/k3Qm7xR2-pLv9wZaB4Nc_t
```

The part after `/stamp/` is your school's secret. Treat it like a key to the
till, because that is roughly what it is.

## Writing the NFC sticker

1. Buy NTAG213 stickers. Any pack will do; they are a few cents each.
2. Install any NFC tag-writing app on an Android phone (iPhones can read tags
   but most cannot write them).
3. Choose **Write → URL / Link**, paste the address, write the tag.
4. Optionally lock the tag so nobody can rewrite it.

Stick it somewhere a parent can reach — the desk, the counter, a laminated
card. When a phone touches it the phone opens PayStamp by itself. There is
nothing to install and nothing to scan.

## Or use the QR code instead

The same screen shows a QR code. Leave it open and let parents scan it with
their camera. It redraws every 30 seconds — that is deliberate, and it is how
PayStamp can tell a scan apart from a tap in your records.

---

## What a parent sees

1. Their phone opens PayStamp.
2. If they are not logged in, they log in, and the tap picks up where it left
   off. Nothing is lost.
3. They see their child's name, the next unpaid month, and the amount owed,
   already filled in. They can change the amount.
4. They press **Confirm Payment**. Done, with an **Undo** button for ten
   minutes.

They have **60 seconds** from tapping to confirming. That is not a hurry, it
is a limit on how long a tap stays usable if the phone is put down.

---

## Asking for your PIN

**On the same screen.** Set a 4–8 digit PIN, then switch it on.

With it on, nothing is recorded until you type your PIN on the parent's phone.
Use it if you want to be standing there for every confirmation. With it off,
parents confirm on their own, which is faster and fine if you trust the room.

Three wrong tries and the parent has to tap again.

---

## If a tag goes missing

**Issue a New Code.** The old sticker stops working the instant you press it.
Rewrite your stickers with the new address.

**Switch Tap to Pay Off** turns the whole thing off. Payments already recorded
are untouched.

---

## What this actually protects

Worth being straight about, because the tag is a physical object and physical
objects get borrowed.

**Someone who copies your tag address can open a confirmation** — but only for
their own children, and only at your school. They cannot see other students and
cannot record anything against anybody else's child. The database works out
what the amount covers; nothing the phone sends can change that.

**But the amount is theirs to type.** That is the real limit of this, and it is
worth saying plainly: a parent could enter more than they are handing you, and
months would be marked paid that were not. Nothing about a tag can prevent
that, because the tag cannot see the money. What you have instead is that every
such payment is labelled **Tap** or **QR scan** in the student's history, with
the amount and the date, so it is visible rather than silent.

**What stops that entirely is the PIN.** If you want a confirmation to be
impossible without you present, switch it on.

**Every confirmation is labelled.** The payment history on each student shows
**Tap**, **QR scan** or nothing at all — nothing meaning you typed it in
yourself. If a payment appears that you do not recognise, the label tells you
how it got there.

---

## Where the records go

Exactly where they always went. A tap writes the same payment, in the same
shape, as typing the amount into the dashboard yourself — same months, same
history, same receipts, same export. There is no separate ledger to reconcile.

---

## The stamp

A third way in. A rubber stamp with conductive pads is pressed against the
parent's phone; the pattern its pads make identifies your school and opens the
same confirmation a tag or a QR would.

**Saving a calibration is what switches it on.** There is nothing for a parent
to install, enable or know about. Until you save a pattern, no phone is
listening; once you do, your parents' phones pick it up the next time they open
PayStamp. Remove the pattern and it switches off again everywhere.

If you ever want a particular device to ignore the stamp completely, open the
app there with `?stamptrigger=0` on the end of the address. `?stamptrigger=1`
forces the opposite, which is only useful for testing before you have
calibrated anything.

### Teaching it your stamp

**Settings → Payments → Stamp.** Press the stamp flat
and firm on the target area. The pads it registers are drawn back so you can
see the press was clean — if one pad missed, press again rather than saving it,
because a bad pattern fails silently later on a parent's phone where nobody is
watching.

Between four and eight pads. Four is the floor because iOS reports at most five
touches no matter how many pads you have, so the match is made on whatever
subset arrives.

### What to expect when you test it

Press it on a parent's phone while they have the family portal open. A match
opens their confirmation. **A non-match does nothing at all** — no message, no
flicker. That is deliberate: it means an ordinary fumble with five fingers on a
phone is harmless, but it also means "nothing happened" is the only symptom you
get when something is wrong. Check the calibration first.

**Press it at any angle you like.** The pattern is recognised however the
stamp is turned, and it copes with a parent's phone measuring the screen
differently from yours. Both of those were limitations in the first version and
both are gone.

What it still will not do:

- **Recognise fewer than four pads.** If a pad does not make contact, nothing
  happens.
- **Tell two very similar stamps apart.** Only your own school's pattern is
  ever compared against, so this can only matter to a parent with children at
  two schools that both use PayStamp and both have near-identical stamps. If
  that ever happens, neither is confirmed rather than the wrong one.

### It works in both portals

The **family portal** (a parent logged in) and the **Quick View** student
portal (a code and PIN, no account) both accept a stamp press.

**You still have to stamp the phone.** Exactly as in the family portal. The
code and PIN are not a way in — they are only how the app knows which card is
on the screen, which it already needed in order to show the card at all. On
their own they record nothing:

| What is tried | What happens |
|---|---|
| Right code and PIN, no stamp | nothing |
| Right code and PIN, four random fingers | nothing |
| Right code and PIN, a different school's stamp | nothing |
| Right code and PIN, **your stamp** | the confirmation opens |

In Quick View the confirmation is also locked to the one card already on the
screen. It cannot reach another student, even at your own school.

### How much it protects

Less than the tag, and it is worth being blunt about that. A tag address is 24
random characters. A stamp is five dots on a physical object that anyone can
look at and, with enough patience, reproduce with their fingers. The matching
happens on the server and only against schools that person is already a
customer of, so nobody can use it to reach another school — but as a secret, a
stamp is weak. If that matters to you, turn on **Ask For My PIN**.


---

# Paying online

Separate from everything above, and the only route where the money does not
pass through your hands.

## Setting it up

**Settings → Payments → Payment Link.** Paste wherever you already take money —
Revolut, Viva, your bank's payment page. PayStamp never touches the money; it
only sends parents there and keeps the record.

It has to start with `https://`. A plain `http://` link is refused, and so is
anything that is not a web address.

Give it a name parents will recognise — "Revolut — Maria" reads better on their
phone than a bare URL.

## What a parent does

1. Opens their child's card and taps **Pay Online**.
2. Pays, on your page, in their own banking app.
3. Comes back and taps **I've paid**, giving the amount, the date, and
   optionally a reference or the last four digits.

That option only appears *after* they have opened the link.

## Nothing is paid until you say so

This is the part worth being clear about, because it is the whole design.

**A claim is not a payment.** When a parent says they have paid:

- the student's card does not change
- the months stay exactly as they were
- your **Owed** total does not move
- nothing appears in the payment history

The parent sees **"Awaiting confirmation"** and, in as many words, that it is
**not recorded as paid yet**. Nobody is told the money has arrived until you
have said it has.

## Your queue

**Settings → Payments → Pending Payments.** The row carries a count, so a queue
nobody thinks to open still says it has something in it.

Each claim shows the student, the amount, the date they say they paid, and any
reference — which is what you match against your statement.

**Confirm** records it exactly the way every other route does: same months,
same breakdown, same history, same undo. It shows as **Paid online** in the
student's history.

**Reject** asks for a reason, changes nothing, and shows the parent what you
said. Nothing was recorded, so nothing has to be undone.

A claim left more than ten days is flagged **Waiting a while** — the queue says
when it is being ignored rather than quietly filling up.

## Both portals

Parents with an account, and students using Quick View with just a code and
PIN, both get the same thing.

## What is not built

Automatic confirmation through a card processor. The groundwork is there — a
claim already records whether a person or a processor verified it — but it
needs somewhere to run server code, which PayStamp does not have yet. Until
then, confirming is a person reading a statement, which is what you would be
doing anyway.
