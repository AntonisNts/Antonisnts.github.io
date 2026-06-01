# StampCard

A mobile-first payment / "stamp card" tracker for small academies and tutors
(swimming, karate, languages, music, dance, and more). Teachers manage student
cards and monthly payments; students view their own card with a code + PIN.

Everything runs client-side and is stored in the browser's `localStorage` — no
backend, no accounts server, no build step.

## Features

- **Teacher portal** — register a business, get a unique business code, and log
  in with a password.
- **Student cards** — each student gets a shareable code and a 4-digit PIN to
  view their own card.
- **Smart payments** — enter a single amount and it's automatically distributed
  across unpaid months, with a live breakdown and confirm step.
- **Levels** — define tiers (e.g. Beginner / Intermediate) each with its own fee.
- **Inactive months** — skip summer/holiday months so they don't count as owed.
- **Custom card art** — upload a background image for the student cards.
- **Export** — summary / detailed / CSV reports, copyable or shareable by email
  or WhatsApp.
- **Reminders** — filter students with outstanding balances and send templated
  reminders via WhatsApp, SMS, or email.
- **Account recovery** — look up a business code by registered email.

## Running it

It's a single static file. Open `index.html` directly in a browser, or serve
the folder:

```bash
python3 -m http.server 8000
# then visit http://localhost:8000
```

React, ReactDOM, and Babel are loaded from a CDN and the JSX is compiled in the
browser, so an internet connection is required on first load.

## Deploying

This repo is a GitHub Pages user site. To make it live at
`https://antonisnts.github.io`, merge `index.html` to the `main` branch and make
sure GitHub Pages is enabled (Settings → Pages → Branch: `main`).

## Demo data

On first run a sample business is seeded so you can explore immediately:

- **Business code:** `BIZ-860E20`  ·  **Password:** `Swim2026`
- **Student code:** `AQ3RG0`  ·  **PIN:** `3821`

## Notes

- Data lives only in the browser it was entered in; clearing site data wipes it.
- Passwords are stored in plain `localStorage` — this is a lightweight personal
  tool, not a secure multi-tenant system.
