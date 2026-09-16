# Browser test harness

Boots the real `app/index.html` in a headless browser with a **mocked Supabase**
and fixture data, so screens can be driven and screenshotted without touching
the live database.

Only the client construction is swapped — the line

```js
const sb = window.supabase.createClient(SB_URL, SB_KEY);
```

is replaced with a stand-in. Everything above it runs for real, including
`bizFromRow` and the rest of the loaders, so what renders is the actual app
against realistic rows rather than a stub of it.

## Setup

```bash
cd app/test
npm install
npx playwright install chromium
```

If a browser is already on the machine but playwright wants a different build,
point at it instead of downloading a second copy:

```bash
export PLAYWRIGHT_CHROMIUM=/opt/pw-browsers/chromium-1194/chrome-linux/chrome
```

## Run

```bash
node sweep.js     # every settings screen opens, on the skin, with no errors
node stamp.js     # the Tap to Pay confirmation flow, both sides of it
node routes.js    # /stamp/TOKEN and the 404 fallback that makes it work
node qr.js        # the QR encoder, against a reference encoder and a decoder
node stamptrigger.js  # the stamp trigger and its calibration screen
node paylink.js   # the payment link, and that a claim never looks like a payment
node shop.js      # the shop module — and that it can be taken back out
```

`shop.js` keeps the shop out of `sweep.js`'s list on purpose. Removing the
module should never mean editing a test that is not the module's own, so the
shop's screens are checked for the skin and for `--accent` inside `shop.js`
instead. Its last section performs the documented removal on a copy of
`app/index.html` and boots what is left — a dangling reference there is a blank
screen for every school, not just the ones that switched the shop on.

`qr.js` needs no browser. It lifts `qrMatrix()` straight out of `app/index.html`
rather than importing a copy, so what it checks is what ships.

Opens every screen reachable from the settings sheet plus the dashboard and a
student card, and checks:

- each opens on the shared `.scr` skin
- any screen using an accent-consuming class also publishes `--accent`
  (without it the class silently falls back to the `:root` default)
- no page errors — Babel compiles the whole file, so this doubles as a syntax
  check on `app/index.html`

## Writing your own

```js
const { open } = require("./harness");

const { browser, page, errors } = await open();          // business owner
const { browser, page } = await open({ role: "parent" }); // family portal
const { browser, page } = await open({ signedOut: true });// login / landing
```

`open()` also takes `viewport`, `fixtures`, `query` and `appPath`. The default
fixtures are one approved music school with four students, two groups, two
teachers, two registration links and two pending requests — enough for most
screens.

`rpc` sets what each function answers. `rpcError` is its opposite: a list of
names that answer the way a database answers a function it has never heard of.

```js
await open({ rpc: { shop_catalogue_mine: CATALOGUE } });   // the happy path
await open({ rpcError: ["shop_catalogue_mine"] });         // migration not run
```

That second case is not hypothetical. Every school is running the deployed app
the moment a new migration lands and before anyone runs its SQL, so a screen
that cannot survive a missing function breaks for all of them at once.

To capture what the app *writes*, wrap the mock before acting:

```js
await page.evaluate(() => {
  window.__writes = [];
  const realFrom = window.__MOCK_SB.from;
  window.__MOCK_SB.from = (t) => {
    const b = realFrom(t), realUpdate = b.update;
    b.update = (row) => { window.__writes.push({ table: t, row }); return realUpdate(row); };
    return b;
  };
});
// ... drive the UI ...
const writes = await page.evaluate(() => window.__writes);
```

## Restricted networks

The app loads React, Babel, Supabase and xlsx from unpkg/jsdelivr at run time.
Normally those just load. If egress is blocked, put the same files in
`app/test/vendor/` and they are served instead:

| file | from |
|---|---|
| `react.js` | `react@18/umd/react.production.min.js` |
| `react-dom.js` | `react-dom@18/umd/react-dom.production.min.js` |
| `babel.js` | `@babel/standalone@7.23.5/babel.min.js` |
| `xlsx.js` | `xlsx@0.18.5/dist/xlsx.full.min.js` |
| `supabase.js` | a stub — `window.supabase = { createClient: () => window.__MOCK_SB }` |

`vendor/` is gitignored. Without it the real CDNs are used and nothing changes.

## Not the same as the SQL tests

This covers the **browser**. `supabase/test/` covers the **database** — RLS,
policies, functions and migrations. Run both before shipping anything that
touches either.
