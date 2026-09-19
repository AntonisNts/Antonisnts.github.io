# The school shop

Optional. Uniforms, shoes and accessories a school sells to its own students,
collected at the school. No shipping, no public storefront, no browsing by
anyone who is not already a parent at that school.

It is **off for every school** until the owner switches it on, and it is built
to be taken back out.

---

## Turning it on

Settings → **Shop** → **Items** → *Switch Shop On*.

Until then the school's parents see nothing: no section, no heading, no empty
state. `shop_catalogue_mine` returns nothing at all for a school with the shop
off — not an empty catalogue, *nothing* — so the portal has no section to draw.
Switching it back off is the same in reverse, and deletes nothing that was
already sold.

## Selling something

Settings → **Shop** → **Items** → *+ Add Item*.

| field | notes |
|---|---|
| Name | required, up to 80 characters |
| Description | optional |
| Price | required |
| Sizes | optional, comma separated. An item that has sizes cannot be ordered without choosing one |
| Stock | optional. **Blank means not counted**, which is not the same as zero |
| Photo | optional. Taken or chosen on the phone — there is no link to paste |

Stock blank and stock zero read differently everywhere on purpose: "stock not
counted" versus "out of stock". A school that does not want to run an inventory
leaves it blank and nothing is ever checked or decremented.

### Photos

*Take Or Choose A Photo* opens the phone's camera roll (or camera). The picture
is re-encoded as a JPEG at 1280px before it leaves the device — a phone
photograph is several megabytes and nobody needs that to look at a jumper — and
stored in the `shop-images` bucket under a folder named after the school.

Shown **whole**, never cropped to fill: a uniform photographed head to toe
loses the head and the feet to a cropping fit, which are the two ends that say
what it is. Tapping any picture opens it full-screen. The only cropped one is
the 56px square on the owner's own list, which is an identifier rather than the
picture — and it opens full-screen too.

It used to be a box asking for an `https://` link, which meant getting the
picture onto the internet somewhere else first. Items saved that way still work:
the column is a URL either way, and only where the URL comes from has changed.

The bucket is public to read and writable only into your own school's folder,
which is what stops one school replacing the picture on another's jumper. It
needs `supabase/migration-shop-images.sql` and a bucket created in the
dashboard; without them, items simply have no photo and everything else works.

Items are archived, never deleted. An order placed last term still shows what
was bought and what it cost, because every line stores the name and price as
they were on the day.

## Orders

Settings → **Shop Orders**. The settings row carries a count of what is
waiting: new orders, plus any where a parent says they have paid.

The screen is sliced three ways, because a school asks three different
questions:

| | |
|---|---|
| **To do** | Something is waiting on you — an order to prepare or hand over, or a claim to check. A collected order with a claim on it is still here, because it still needs a decision. |
| **Unpaid** | Who owes you. Includes orders already collected. |
| **Done** | Nothing left to do about it. |

An order can be in two of them at once — new *and* unpaid — and that is the
point: they are answers to different questions, not a status each order has one
of. Every order is in at least one.

Rows are one line each and fold open. Nine orders used to be nine tall cards
with three full-width buttons apiece, so the list was mostly buttons and a
school could not see at a glance what it had to do. The list is for reading;
acting on one order is a deliberate second tap.

An order moves **new → ready → collected**, or is **cancelled** at any point
before it is collected. Cancelling puts counted stock back.

Payment is tracked separately from that: **unpaid → claimed → paid**. An order
can be collected and unpaid, or paid and not yet ready — they are two different
questions and the screen asks them separately.

## What a parent sees

A **Shop** tab on that child's page in the family portal — tap the child's
name, then Shop. They are told whether something is available, never how many
are left; the count is the school's business.

The tab appears only when that child's school actually sells something. A tab
that opens on nothing is a promise the page does not keep.

### The student portal

Students who open their card with a code and a PIN get the same **Shop** tab.
Some families have one child at one school and never make an account, and
until `migration-shop-student.sql` the shop did not exist for them at all —
every shop function was keyed on a signed-in email.

Their orders are recorded as `student:CODE`, the same shape payment claims use,
so the order queue says where an order came from. Nothing about what an order
*is* is duplicated: `shop_order_place` and `shop_order_place_student` both
prove who is calling and then hand off to one writer, `shop_order_open`, which
is granted to nobody.

It is deliberately not on the portal's front page. The catalogue comes back per
card, so two siblings at one school meant the same jumper listed twice, above
the children themselves. Showing one child at a time makes that impossible
rather than deduplicating it after the fact.

Ordering asks for a size and a quantity. Prices are never sent from the browser:
the order carries item ids, sizes and quantities, and the database prices every
line from its own table. A total the page computed would be a total the page
could choose.

## Paying for kit

Two routes today:

1. **The school marks it paid.** Recorded as `manual`.
2. **The school's payment link.** The parent opens the link from the order, then
   presses *I've paid* and says what they sent. That marks the order
   **claimed** — which is not paid. The school confirms it against their
   statement, and only then is it settled, recorded as `link`.

Both go through one function, `shop_order_mark_paid`, which is granted to
nobody. Each entry point proves for itself who is allowed to settle the order
and then calls it. Adding a card processor later means verifying its webhook,
finding the order, and calling that same function with `p_via = 'stripe'`.
Nothing else has to change.

If the school has no payment link, the parent simply pays them as they normally
would and the school ticks it off.

## Kit money is not fee money

Shop orders never touch the monthly fee breakdown.

"Who owes me for September" stays fees-only. What is owed for kit is its own
number on its own screen, labelled **Owed For Kit · separate from lesson fees**.
Nothing a parent does in the shop moves a month on their card, and a claim
against an order goes to `shop_order_claim_paid`, not to the `payment_claims`
table the fee side uses.

This is checked from both ends: `supabase/test/test-shop.sql` section B proves
the totals are independent in the database, and `app/test/shop.js` photographs
the months on the card before and after an order and requires them identical.

## Who can see what

The same rule as everywhere else in PayStamp. Every table is reached only
through functions, each of which works out for itself who is calling:

- a school sees only its own items and orders;
- a parent sees only their own children's catalogues and their own orders;
- a parent can claim against an order they placed, and no other.

## Removing it

The module is four tables and sixteen functions, all prefixed `shop_`, and one
block in `app/index.html`. It alters no existing table and no existing function.

- **Database:** the drop statements are at the foot of
  `supabase/migration-shop.sql`.
- **App:** delete the block between the `SHOP MODULE — BEGIN` and
  `SHOP MODULE — END` markers, then delete every line marked
  `SHOP MODULE mount`. There are five, each one whole line.

What survives is two handler props on `PgDashboard` — a name in its signature
that nothing reads, and an arrow at its call site that nothing calls. Neither
refers to anything the removal deletes.

`app/test/shop.js` does this removal on a copy and boots the result, so the
instructions above are checked rather than asserted.

---

## Files

| file | what it is |
|---|---|
| `supabase/migration-shop.sql` | the whole database half, including its own removal instructions |
| `supabase/migration-shop-images.sql` | storage policies for item photos — optional, no table touched |
| `supabase/migration-shop-student.sql` | the shop for the code-and-PIN portal |
| `supabase/test/test-shop.sql` | 95 assertions |
| `app/index.html` | the block between the `SHOP MODULE` markers |
| `app/test/shop.js` | 128 assertions, including the removal |
