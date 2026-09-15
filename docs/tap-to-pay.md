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
