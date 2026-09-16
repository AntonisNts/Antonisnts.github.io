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
| Picture link | optional, must be `https://` |

Stock blank and stock zero read differently everywhere on purpose: "stock not
counted" versus "out of stock". A school that does not want to run an inventory
leaves it blank and nothing is ever checked or decremented.

Items are archived, never deleted. An order placed last term still shows what
was bought and what it cost, because every line stores the name and price as
they were on the day.

## Orders

Settings → **Shop Orders**. The row carries a count of what is waiting: new
orders, plus any where a parent says they have paid.

An order moves **new → ready → collected**, or is **cancelled** at any point
before it is collected. Cancelling puts counted stock back.

Payment is tracked separately from that: **unpaid → claimed → paid**. An order
can be collected and unpaid, or paid and not yet ready — they are two different
questions and the screen asks them separately.

## What a parent sees

A **Shop** section in the family portal, under the months, with the items for
each of their children. They are told whether something is available, never how
many are left — the count is the school's business.

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
  `SHOP MODULE mount`. There are four, each one whole line.

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
| `supabase/test/test-shop.sql` | 74 assertions |
| `app/index.html` | the block between the `SHOP MODULE` markers |
| `app/test/shop.js` | 95 assertions, including the removal |
