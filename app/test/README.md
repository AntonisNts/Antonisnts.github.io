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
```

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

`open()` also takes `viewport` and `fixtures`. The default fixtures are one
approved music school with four students, two groups, two teachers, two
registration links and two pending requests — enough for most screens.

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
